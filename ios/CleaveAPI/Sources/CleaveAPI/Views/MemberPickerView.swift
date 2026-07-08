import SwiftUI
import SwiftData

/// Adds a roster person to a group. Lists directory users not already members.
struct MemberPickerView: View {
    let group: ExpenseGroup
    let existing: Set<String>

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \User.displayName) private var users: [User]
    @State private var inviteEmail = ""
    @State private var working = false
    @State private var errorText: String?

    private var candidates: [User] { users.filter { !existing.contains($0.identifier) } }

    var body: some View {
        NavigationStack {
            List {
                if group.backendType == .splitwise {
                    Section {
                        TextField("name@example.com", text: $inviteEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Invite to Splitwise") { invite() }
                            .disabled(working || inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                    } header: {
                        Text("Invite by email")
                    } footer: {
                        Text("Adds a new person to this group on Splitwise.")
                    }
                }
                Section("From your directory") {
                    ForEach(candidates) { user in
                        Button { add(user.identifier) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName.titleCased)
                                Text(user.identifier).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(working)
                    }
                    if candidates.isEmpty {
                        Text("Everyone in the directory is already a member.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .errorAlert($errorText)
        }
    }

    private func add(_ identifier: String) {
        run { try await env.groups(context).addMember(groupId: group.id, userIdentifier: identifier) }
    }

    private func invite() {
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        run { try await env.groups(context).addMember(groupId: group.id, email: email) }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do { try await op(); dismiss() }
            catch { errorText = errorMessage(error) }
        }
    }
}
