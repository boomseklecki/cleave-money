import SwiftUI
import SwiftData

/// Member management for one group (add from the roster, swipe to remove). Presented as a sheet from
/// the group detail "..." menu so it stays off the main screen.
struct GroupMembersView: View {
    let group: ExpenseGroup

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var members: [GroupMember]
    @Query private var users: [User]

    @State private var showingAddMember = false
    @State private var errorText: String?

    init(group: ExpenseGroup) {
        self.group = group
        let gid = group.id
        _members = Query(
            filter: #Predicate<GroupMember> { $0.groupId == gid },
            sort: \GroupMember.userIdentifier
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(members) { member in
                    Text(users.displayName(for: member.userIdentifier))
                }
                .onDelete(perform: remove)
                Button { showingAddMember = true } label: {
                    Label("Add Member", systemImage: "person.badge.plus")
                }
            }
            .overlay {
                if members.isEmpty {
                    ContentUnavailableView("No Members", systemImage: "person.2",
                                           description: Text("Add someone from the roster."))
                }
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingAddMember) {
                MemberPickerView(group: group, existing: Set(members.map(\.userIdentifier)))
            }
            .errorAlert($errorText)
        }
    }

    private func remove(_ offsets: IndexSet) {
        let identifiers = offsets.map { members[$0].userIdentifier }
        Task {
            // Concurrent deletes + one member-list refresh (a 404 is treated as already-removed).
            do { try await env.groups(context).removeMembers(groupId: group.id, identifiers: identifiers) }
            catch { errorText = errorMessage(error) }
        }
    }
}
