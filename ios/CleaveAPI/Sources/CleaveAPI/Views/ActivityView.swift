import SwiftUI

/// One activity-feed row, shared by the Inbox preview and the full Activity screen (so the gestures stay
/// consistent). A deep-link target → tap drills into the entity (closure-based nav, works nested too) and the
/// detail's `onAppear` marks it read. Two-stage swipe: full-swipe = Read; partial swipe reveals [Read][Hide],
/// tap Hide to remove it from the feed for good.
struct ActivityRow: View {
    let n: Components.Schemas.NotificationResponse
    let onMarkRead: () -> Void
    let onHide: () -> Void

    var body: some View {
        row.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { onMarkRead() } label: { Label("Read", systemImage: "checkmark.circle") }.tint(.blue)
            Button(role: .destructive) { onHide() } label: { Label("Hide", systemImage: "eye.slash") }
        }
    }

    @ViewBuilder
    private var row: some View {
        if let target = NotificationTarget(type: n.entity_type, id: n.entity_id) {
            NavigationLink {
                LazyView(NotificationTargetView(target: target).onAppear { onMarkRead() })
            } label: { content }
        } else {
            content   // no resolvable target → not tappable; use the swipe to read/hide
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: n.source == "splitwise" ? "dollarsign.circle" : "bell")
                .font(.title3).foregroundStyle(n.read ? Color.secondary : Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.content).font(.subheadline)
                    .foregroundStyle(n.read ? .secondary : .primary).lineLimit(3)
                Text(n.created_at.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if !n.read { Circle().fill(.tint).frame(width: 8, height: 8) }
        }
    }
}

/// The full activity / trust log - every shared-group notification (newest first, up to the retention window),
/// deep-linkable and mark-read. Reached from the Inbox's "See All Activity".
struct ActivityView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @State private var activity: [Components.Schemas.NotificationResponse] = []
    @State private var loaded = false

    var body: some View {
        List {
            if activity.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "tray",
                                       description: Text("Shared-group activity will show up here."))
            } else {
                ForEach(activity, id: \.id) { n in
                    ActivityRow(n: n, onMarkRead: { markRead(n) }, onHide: { hide(n) })
                }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if activity.contains(where: { !$0.read }) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mark All Read") { markAllRead() }
                }
            }
        }
        .task { if !loaded { await reload(); loaded = true } }
        .refreshable { await reload() }
    }

    private func reload() async {
        _ = try? await env.splitwise.syncNotifications()
        if let all = try? await env.notifications.list() {
            activity = all.filter { !NotificationPrefs.shared.isHidden(type: $0._type, source: $0.source) }
        }
    }

    private func markRead(_ n: Components.Schemas.NotificationResponse) {
        guard !n.read, let id = try? Mapping.uuid(n.id, field: "Notification.id") else { return }
        if let i = activity.firstIndex(where: { $0.id == n.id }) { activity[i].read = true }  // optimistic
        Task {
            try? await env.notifications.markRead(id: id)
            await env.refreshInboxBadge(context)
        }
    }

    private func hide(_ n: Components.Schemas.NotificationResponse) {
        guard let id = try? Mapping.uuid(n.id, field: "Notification.id") else { return }
        activity.removeAll { $0.id == n.id }                       // optimistic - gone from the feed
        Task {
            try? await env.notifications.hide(id: id)
            await env.refreshInboxBadge(context)
        }
    }

    private func markAllRead() {
        for i in activity.indices { activity[i].read = true }      // optimistic
        Task {
            try? await env.notifications.markAllRead()
            await env.refreshInboxBadge(context)
        }
    }
}
