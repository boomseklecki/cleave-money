import SwiftUI

/// Per-user notification preferences: independently choose, per category, whether it shows in the Inbox
/// feed and whether it pushes to your device. Backed by `/notification-prefs` (syncs across devices). The
/// feed row is always recorded server-side - these toggles only affect *your* view + alerts.
struct NotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var prefs = NotificationPrefs.shared
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                ForEach(NotificationBucket.allCases) { bucket in
                    Toggle(bucket.label, isOn: shownBinding(bucket))
                }
            } header: {
                Text("Show in Inbox")
            } footer: {
                Text("Hidden kinds stay out of your activity feed and badge. They're still recorded, so "
                     + "your shared-group history stays complete.")
            }

            Section {
                ForEach(NotificationBucket.allCases) { bucket in
                    Toggle(bucket.label, isOn: pushedBinding(bucket))
                }
            } header: {
                Text("Push to device")
            } footer: {
                Text("Turning push off still keeps the activity in your Inbox — e.g. silence Splitwise "
                     + "pushes while keeping Splitwise activity visible.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .errorAlert($errorText)
    }

    private func shownBinding(_ bucket: NotificationBucket) -> Binding<Bool> {
        Binding(get: { prefs.isShown(bucket) },
                set: { on in save(prefs.set(bucket, channel: "feed", on: on)) })
    }

    private func pushedBinding(_ bucket: NotificationBucket) -> Binding<Bool> {
        Binding(get: { prefs.isPushed(bucket) },
                set: { on in save(prefs.set(bucket, channel: "push", on: on)) })
    }

    private func load() async {
        if let tokens = try? await env.notificationPrefs.fetch() { prefs.apply(tokens) }
    }

    private func save(_ tokens: [String]) {
        Task {
            do { try await env.notificationPrefs.update(tokens) }
            catch { errorText = errorMessage(error) }
        }
    }
}
