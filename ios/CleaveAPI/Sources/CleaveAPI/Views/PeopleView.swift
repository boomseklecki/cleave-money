import SwiftUI
import SwiftData

/// The household directory: everyone known to this instance, with their source and contact info.
/// Reached from Settings → People.
struct PeopleView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \User.displayName) private var users: [User]

    @State private var showingNewUser = false
    @State private var newUserName = ""
    @State private var errorText: String?
    @State private var partnerIds: Set<String> = []

    var body: some View {
        List {
            Section {
                ForEach(users) { user in
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(url: user.avatarURL, name: user.displayName.titleCased)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(user.displayName.titleCased)
                                if let badge = registrationBadge(user.registrationStatus) {
                                    Text(badge.label)
                                        .font(.caption2).foregroundStyle(badge.color)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(badge.color.opacity(0.15), in: Capsule())
                                }
                                if partnerIds.contains(user.identifier) {
                                    Text("Partner")
                                        .font(.caption2).foregroundStyle(.blue)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15), in: Capsule())
                                }
                                Spacer()
                                Text(sourceLabel(user.source))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            if let email = user.email, !email.isEmpty {
                                Label(email, systemImage: "envelope")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if user.splitwiseUserId != nil {
                                Label("Linked to Splitwise", systemImage: "link")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(user.identifier)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("\(users.count) \(users.count == 1 ? "person" : "people")")
            }
        }
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPartners() }
        .refreshable {
            await loadPartners()
            await env.smartRefresh(source: .splitwise,
                                   freshness: users.map(\.updatedAt).max(), context: context) {
                try await env.users(context).refresh()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewUser = true } label: { Image(systemName: "person.badge.plus") }
            }
        }
        .alert("Add Person", isPresented: $showingNewUser) {
            TextField("Display name", text: $newUserName)
            Button("Add", action: addUser)
            Button("Cancel", role: .cancel) { newUserName = "" }
        }
        .overlay {
            if users.isEmpty {
                ContentUnavailableView("No People", systemImage: "person.2",
                                       description: Text("Add someone, or import from Splitwise."))
            }
        }
        .errorAlert($errorText)
    }

    /// Your accepted partner connections, to badge those rows (this directory unifies friends + partners +
    /// local users - the badge marks which of them you've connected with for sharing).
    private func loadPartners() async {
        if let conns = try? await env.connections.list() {
            partnerIds = Set(conns.filter { $0.status == "accepted" }.map(\.other_identifier))
        }
    }

    /// A tag for Splitwise users who aren't fully registered. Confirmed (and non-Splitwise) users
    /// get no badge.
    private func registrationBadge(_ status: String?) -> (label: String, color: Color)? {
        switch status?.lowercased() {
        case "invited": return ("Invited", .orange)
        case "dummy": return ("Placeholder", .gray)
        default: return nil
        }
    }

    private func sourceLabel(_ source: UserSource) -> String {
        switch source {
        case .splitwise: return "Splitwise"
        case .app: return "App"
        case .manual: return "Manual"
        }
    }

    private func addUser() {
        let name = newUserName.trimmingCharacters(in: .whitespaces)
        newUserName = ""
        guard !name.isEmpty else { return }
        Task {
            do { try await env.users(context).create(UserDraft(displayName: name)) }
            catch { errorText = errorMessage(error) }
        }
    }
}
