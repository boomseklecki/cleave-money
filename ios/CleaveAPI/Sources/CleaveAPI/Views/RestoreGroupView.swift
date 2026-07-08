import SwiftUI
import SwiftData

/// Restore a Splitwise group deleted through the app (and its expenses). The list comes from the server, so
/// any member of the group sees it - no need to know the Splitwise id. One tap restores it for everyone.
struct RestoreGroupView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var deleted: [Components.Schemas.GroupResponse] = []
    @State private var loaded = false
    @State private var restoringId: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(deleted, id: \.id) { group in
                    Button {
                        restore(group)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                            if let when = group.deleted_at {
                                Text("Deleted \(when.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(restoringId != nil)
                }
            }
            .overlay {
                if loaded && deleted.isEmpty {
                    ContentUnavailableView("Nothing to Restore", systemImage: "arrow.uturn.backward",
                                           description: Text("Groups you delete here can be restored from this screen."))
                }
            }
            .navigationTitle("Restore Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .errorAlert($errorText)
        }
    }

    private func load() async {
        do { deleted = try await env.groups(context).deletedGroups() }
        catch { errorText = errorMessage(error) }
        loaded = true
    }

    private func restore(_ group: Components.Schemas.GroupResponse) {
        guard let id = UUID(uuidString: group.id) else { return }
        restoringId = group.id
        Task {
            defer { restoringId = nil }
            do {
                try await env.groups(context).restore(groupId: id)
                deleted.removeAll { $0.id == group.id }
            } catch { errorText = errorMessage(error) }
        }
    }
}
