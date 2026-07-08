import SwiftUI
import SwiftData

/// A friend (person) for the Friends list + detail drill-in. Carries the overall balance and the per-group
/// breakdown (Splitwise-sourced), each group resolved to a local group when cached. Hashable so it can be a
/// value-based navigation target.
struct FriendRow: Identifiable, Hashable {
    let id: String        // the person's identifier (e.g. "bob")
    let name: String
    let net: Decimal      // overall: net > 0 => they owe you
    let groups: [FriendGroupRef]

    /// Project a cached `Friend` into a nav row, resolving each cached Splitwise group to a local
    /// `ExpenseGroup` (when synced) and the name from the user directory.
    init(friend: Friend, allGroups: [ExpenseGroup], users: [User]) {
        let bySwId = Dictionary(allGroups.compactMap { g in g.splitwiseGroupId.map { ($0, g) } },
                                uniquingKeysWith: { first, _ in first })
        self.id = friend.identifier
        self.name = users.displayName(for: friend.identifier)
        self.net = friend.net
        self.groups = friend.groups.map { g in
            let local = bySwId[g.splitwiseGroupId]
            return FriendGroupRef(groupId: local?.id, name: local?.name ?? g.name, net: g.net)
        }
    }

    init(id: String, name: String, net: Decimal, groups: [FriendGroupRef]) {
        self.id = id; self.name = name; self.net = net; self.groups = groups
    }

    /// All cached friends as nav rows (the Friends list source).
    static func rows(from friends: [Friend], allGroups: [ExpenseGroup], users: [User]) -> [FriendRow] {
        friends.map { FriendRow(friend: $0, allGroups: allGroups, users: users) }
    }
}

/// The friend's balance with you in one shared group. `groupId` is the local group (nil when not cached).
struct FriendGroupRef: Hashable {
    let groupId: UUID?
    let name: String
    let net: Decimal      // net > 0 => they owe you in this group
}

/// One friend: a banner with their avatar + your overall balance, the groups you share (each with your
/// balance with them in that group), and your shared expenses. Mirrors `GroupDetailView`. Reached from the
/// Friends view in `GroupsListView`.
struct FriendDetailView: View {
    let friend: FriendRow

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query private var expenses: [Expense]
    @Query private var users: [User]
    @Query private var allGroups: [ExpenseGroup]

    @State private var errorText: String?
    @State private var brandModel = BrandModel()

    init(friend: FriendRow) {
        self.friend = friend
        let ids = friend.groups.compactMap(\.groupId)
        _expenses = Query(
            filter: #Predicate<Expense> { ids.contains($0.groupId) },
            sort: \Expense.date, order: .reverse
        )
    }

    /// Expenses in the shared groups that this friend is actually on (mirrors "expenses with this person").
    private var sharedExpenses: [Expense] {
        expenses.filter { e in e.splits.contains { $0.userIdentifier == friend.id } }
    }

    var body: some View {
        let users = self.users
        let me = env.currentUser?.identifier
        let groupsById = Dictionary(allGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return List {
            Section {
                HStack(spacing: 12) {
                    AvatarView(url: users.avatarURL(for: friend.id), name: friend.name, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(friend.name).font(.headline)
                        let phrase = BalancePhrase.mine(friend.net)
                        HStack(spacing: 4) {
                            Text(phrase.label).font(.caption).foregroundStyle(.secondary)
                            if let amount = phrase.amount {
                                Text(amount).font(.caption).fontWeight(.medium)
                                    .foregroundStyle(phrase.color).monospacedDigit()
                            }
                        }
                        UpdatedAgo(date: friend.groups.compactMap(\.groupId)
                            .compactMap { groupsById[$0]?.updatedAt }.max())
                    }
                }
            }

            if !friend.groups.isEmpty {
                Section("Groups") {
                    ForEach(friend.groups.sorted { abs($0.net) > abs($1.net) }, id: \.self) { g in
                        if let group = g.groupId.flatMap({ groupsById[$0] }) {
                            // One level below the Splits stack root → closure-based link (value-based drops
                            // the first tap here).
                            NavigationLink {
                                LazyView(GroupDetailView(group: group))
                            } label: {
                                groupRow(g, group: group)
                            }
                        } else {
                            groupRow(g, group: nil)
                        }
                    }
                }
            }

            ForEach(expenseMonthGroups(sharedExpenses), id: \.id) { month in
                Section {
                    ForEach(month.expenses) { expense in
                        NavigationLink {
                            LazyView(ExpenseDetailView(expense: expense))
                        } label: {
                            ExpenseRow(expense: expense, users: users, meIdentifier: me,
                                       brandModel: brandModel)
                        }
                    }
                } header: {
                    Text(month.label).textCase(nil)
                }
            }
            if sharedExpenses.isEmpty {
                Section { Text("No shared expenses cached yet. Pull to refresh.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(friend.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            let gids = Set(friend.groups.compactMap(\.groupId))
            let freshness = allGroups.filter { gids.contains($0.id) }.map(\.updatedAt).max()
            await env.smartRefresh(source: .splitwise, freshness: freshness,
                                   splitwiseScope: .friend(friend.id),
                                   context: context, reconcile: reconcileFriend)
        }
        .task { await reload() }
        .task(id: sharedExpenses.map(\.id)) {
            await brandModel.resolve(merchantTexts: sharedExpenses.flatMap { e in
                [(text: e.note, category: e.category), (text: e.details, category: e.category)]
            })
        }
        .errorAlert($errorText)
    }

    @ViewBuilder
    private func groupRow(_ g: FriendGroupRef, group: ExpenseGroup?) -> some View {
        let phrase = BalancePhrase.mine(g.net)
        HStack(spacing: 12) {
            AvatarView(url: group?.avatarURL, name: g.name, size: 28, systemImage: group?.typeSymbol)
            Text(g.name)
            Spacer()
            Text(phrase.label).font(.caption).foregroundStyle(.secondary)
            if let amount = phrase.amount {
                Text(amount).foregroundStyle(phrase.color).monospacedDigit()
            }
        }
    }

    /// Best-effort refresh of the shared groups' expenses so this friend's expense list fills in (the local
    /// cache can be partial for large groups).
    private func reload() async {  // on appear: reconcile only
        do { try await reconcileFriend() } catch { errorText = errorMessage(error) }
    }

    private func reconcileFriend() async throws {
        var firstError: Error?
        for gid in friend.groups.compactMap(\.groupId) {
            do { try await env.expenses(context).reconcileAll(groupId: gid) }
            catch { firstError = firstError ?? error }  // keep reconciling the friend's other groups
        }
        try? await env.balances(context).refreshFriends()  // refresh the cached net/groups snapshot
        if let firstError { throw firstError }  // surface after attempting all groups (caller shows errorText)
    }
}
