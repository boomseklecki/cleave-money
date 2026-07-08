import SwiftUI
import SwiftData

/// The Inbox tab: on-device AI/heuristic **Suggestions** (recategorize, link, subscription, recurring-split,
/// and the nudges: shared-budget candidate, settle-up, overspend) plus a source-agnostic **Activity** feed
/// (Splitwise now, app-native later). Actionable cards accept/dismiss in place; nudge cards navigate or open
/// a prefilled editor.
struct InboxView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query private var goals: [Goal]
    @Query private var friends: [Friend]
    @Query private var allGroups: [ExpenseGroup]
    @Query private var users: [User]

    @State private var suggestions: [Suggestion] = []
    @State private var activity: [Components.Schemas.NotificationResponse] = []
    @State private var loaded = false
    @State private var refreshing = false
    @State private var lastPartners: Set<String> = []
    @State private var errorText: String?
    @State private var budgetPrefill: BudgetPrefill?
    @State private var linkConfirm: Suggestion?
    @State private var categorizeConfirm: Suggestion?
    @State private var subscriptionConfirm: Suggestion?
    @State private var recurringSplitConfirm: Suggestion?

    struct BudgetPrefill: Identifiable { let id = UUID(); let category: String; let amount: Decimal }

    var body: some View {
        NavigationStack {
            List {
                if !suggestions.isEmpty {
                    Section("Suggestions") { ForEach(suggestions) { row($0) } }
                }
                if !activity.isEmpty {
                    Section("Activity") {
                        ForEach(activity.prefix(6), id: \.id) { n in
                            ActivityRow(n: n, onMarkRead: { markRead(n) }, onHide: { hideActivity(n) })
                        }
                        if activity.count > 6 {
                            NavigationLink {
                                ActivityView()
                            } label: {
                                Label("See All Activity", systemImage: "list.bullet.rectangle")
                            }
                        }
                    }
                }
                if suggestions.isEmpty && activity.isEmpty {
                    ContentUnavailableView("Nothing new", systemImage: "tray",
                                           description: Text("Suggestions and activity will show up here."))
                }
            }
            .navigationTitle("Inbox")
            .toolbar {
                if refreshing {
                    ToolbarItem(placement: .topBarTrailing) { ProgressView() }
                }
            }
            .navigationDestination(for: FriendRow.self) { FriendDetailView(friend: $0) }
            .navigationDestination(for: Goal.self) { GoalDetailView(goal: $0) }
            .sheet(item: $budgetPrefill) { p in
                GoalEditView(prefillCategory: p.category, prefillAmount: p.amount, prefillShared: true)
            }
            .sheet(item: $linkConfirm) { s in
                LinkConfirmSheet(suggestion: s, onConfirm: { accept(s) },
                                 onExternalChange: { Task { await reload() } })
            }
            .sheet(item: $categorizeConfirm) { s in
                CategorizeConfirmSheet(suggestion: s) { chosen in accept(s, category: chosen) }
            }
            .sheet(item: $subscriptionConfirm) { s in
                SubscriptionConfirmSheet(suggestion: s) { accept(s) }
            }
            .sheet(item: $recurringSplitConfirm) { s in
                RecurringSplitConfirmSheet(suggestion: s) { accept(s) }
            }
            .task { if !loaded { await reload(); loaded = true } }
            .refreshable { await reload() }
            .errorAlert($errorText)
        }
    }

    @ViewBuilder
    private func row(_ s: Suggestion) -> some View {
        switch s.kind {
        case .settleUp:
            // Navigate with the cached friend (real per-group balances) so the detail isn't empty; fall back
            // to a minimal row only if the friend hasn't been cached yet.
            NavigationLink(value: friendRow(for: s)) { cardLabel(s) }
                .swipeActions { dismissButton(s) }
        case .overspend, .nearingBudget:
            if let goal = goals.first(where: { $0.id == s.goalId }) {
                NavigationLink(value: goal) { cardLabel(s) }.swipeActions { dismissButton(s) }
            }
        case .sharedBudgetCandidate:
            Button {
                if let c = s.category { budgetPrefill = .init(category: c, amount: s.amount ?? 0) }
            } label: { cardLabel(s) }
                .swipeActions { dismissButton(s) }
        case .link:
            // Heuristic match - confirm before linking instead of committing on one tap.
            SuggestionCard(suggestion: s, accept: { linkConfirm = s }, dismiss: { fm in dismiss(s, fm) })
        case .categorize:
            SuggestionCard(suggestion: s, accept: { categorizeConfirm = s }, dismiss: { fm in dismiss(s, fm) })
        case .subscription:
            SuggestionCard(suggestion: s, accept: { subscriptionConfirm = s }, dismiss: { fm in dismiss(s, fm) })
        case .recurringSplit:
            // Creates a shared expense - confirm (preview the split) before committing.
            SuggestionCard(suggestion: s, accept: { recurringSplitConfirm = s }, dismiss: { fm in dismiss(s, fm) })
        }
    }

    /// The cached `Friend` (real per-group balances) for a settle-up card, or a minimal stub if not yet synced.
    private func friendRow(for s: Suggestion) -> FriendRow {
        if let friend = friends.first(where: { $0.identifier == s.friendIdentifier }) {
            return FriendRow(friend: friend, allGroups: allGroups, users: users)
        }
        return FriendRow(id: s.friendIdentifier ?? "", name: s.title, net: s.amount ?? 0, groups: [])
    }

    private func cardLabel(_ s: Suggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).lineLimit(1)
                Text(s.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func dismissButton(_ s: Suggestion) -> some View {
        Button("Dismiss", role: .destructive) { dismiss(s, false) }
    }

    /// Progressive load: paint cached cards instantly, then stream in the activity feed, AI-derived cards, and
    /// partner/friend nudges as their background work completes - instead of blocking the whole UI behind the
    /// slow on-device AI pass. Each recompute reads the store fresh, so the stages converge regardless of order
    /// and the current list stays visible during a refresh.
    private func reload() async {
        let service = env.suggestions(context)

        // 1) Instant first paint from the warm cache (no network, no AI).
        if let cached = try? service.current(partners: lastPartners) {
            withAnimation { suggestions = cached }
        }

        refreshing = true
        defer { refreshing = false }

        // 2) Activity streams in independently - assigned the moment it's fetched, not gated behind the AI
        //    pass or the suggestion pipeline.
        let activityTask = Task {
            let rows = await loadActivity()
            withAnimation { activity = rows }
            updateBadge()
        }

        // 3) AI opinions → categorize / recurring-split cards appear.
        try? service.learnTemplates()
        await service.refreshAI()
        if let refined = try? service.current(partners: lastPartners) {
            withAnimation { suggestions = refined }
        }

        // 4) Friend balances + partner connections → settle-up / shared-budget nudges refresh.
        try? await env.balances(context).refreshFriends()
        lastPartners = await service.fetchPartners()
        if let withNudges = try? service.current(partners: lastPartners) {
            withAnimation { suggestions = withNudges }
        }

        _ = await activityTask.value  // keep the refreshing indicator until activity finishes too
        updateBadge()
    }

    /// Pull the latest activity feed (Splitwise sync + the generic notifications list); keeps the prior feed
    /// on failure.
    private func loadActivity() async -> [Components.Schemas.NotificationResponse] {
        if let tokens = try? await env.notificationPrefs.fetch() { NotificationPrefs.shared.apply(tokens) }
        _ = try? await env.splitwise.syncNotifications()
        guard let all = try? await env.notifications.list() else { return activity }
        // Hide kinds the user has feed-muted (the rows still exist server-side - the audit log is complete).
        return all.filter { !NotificationPrefs.shared.isHidden(type: $0._type, source: $0.source) }
    }

    /// Accept a card with a light, synchronous cache recompute - never the full `reload()` (which re-runs the
    /// slow on-device AI pass + network syncs and made accepting hang). The accept mutation already updates the
    /// store; we optimistically drop the card, then recompute siblings from the cache.
    private func accept(_ s: Suggestion, category: String? = nil) {
        var s = s
        if let category { s.category = category }   // user-corrected category flows into setCategoryOverride
        let service = env.suggestions(context)
        withAnimation { suggestions.removeAll { $0.id == s.id } }
        updateBadge()
        Task {
            do {
                try await service.accept(s)
                // Mirror dismiss: trust the optimistic removal - no full re-analysis per accept. The next
                // reload (pull-to-refresh / reappear) re-ranks; the badge is already correct from above.
            } catch {
                errorText = errorMessage(error)
                if let restored = try? service.current(partners: lastPartners) {
                    withAnimation { suggestions = restored }  // the mutation failed - bring the card back
                }
                updateBadge()
            }
        }
    }

    private func dismiss(_ s: Suggestion, _ forMerchant: Bool) {
        do {
            try env.suggestions(context).dismiss(s, forMerchant: forMerchant)
            suggestions.removeAll { $0.id == s.id }
            updateBadge()
        } catch { errorText = errorMessage(error) }
    }

    private func markRead(_ n: Components.Schemas.NotificationResponse) {
        guard !n.read, let id = try? Mapping.uuid(n.id, field: "Notification.id") else { return }
        if let i = activity.firstIndex(where: { $0.id == n.id }) { activity[i].read = true }  // optimistic
        updateBadge()
        Task { try? await env.notifications.markRead(id: id) }
    }

    private func hideActivity(_ n: Components.Schemas.NotificationResponse) {
        guard let id = try? Mapping.uuid(n.id, field: "Notification.id") else { return }
        activity.removeAll { $0.id == n.id }                       // optimistic - gone from the feed + preview
        updateBadge()
        Task { try? await env.notifications.hide(id: id) }
    }

    private func updateBadge() {
        env.setInboxBadge(suggestions.count + activity.filter { !$0.read }.count)
    }
}

/// One actionable suggestion row: icon, title/subtitle, a primary Accept, and swipe-to-dismiss (+ "Never for
/// this merchant" when merchant-scoped).
struct SuggestionCard: View {
    let suggestion: Suggestion
    let accept: () -> Void
    let dismiss: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).lineLimit(1)
                Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(suggestion.acceptLabel, action: accept)
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .swipeActions(edge: .trailing) {
            Button("Dismiss", role: .destructive) { dismiss(false) }
            if suggestion.merchantKey != nil {
                Button("Never") { dismiss(true) }.tint(.gray)
            }
        }
    }
}
