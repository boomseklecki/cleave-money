import SwiftUI

/// Admin-only: the local accounts on this server - people who actually signed in (`source == app`), for
/// oversight, with a remove flow. Distinct from the Friends directory, which also folds in your Splitwise
/// friends + partners. Fetched live (enrolled/admin status isn't cached). Reached from Settings (admins only).
struct LocalUsersView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @State private var users: [Components.Schemas.UserResponse] = []
    @State private var pendingRemoval: Components.Schemas.UserResponse?
    @State private var errorText: String?

    private var me: String? { env.currentUser?.identifier }

    var body: some View {
        List {
            Section {
                ForEach(users, id: \.id) { user in
                    row(user)
                }
            } footer: {
                Text("People with a login on this server. Swipe a row to revoke access or delete an account. "
                     + "Your Splitwise friends and partners appear under Friends, not here.")
            }
        }
        .navigationTitle("Local Users")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .overlay {
            if users.isEmpty {
                ContentUnavailableView("No Local Users", systemImage: "person.crop.rectangle.stack")
            }
        }
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.display_name.titleCased)?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval
        ) { user in
            Button("Revoke Access") { remove(user, delete: false) }
            Button("Delete Account & Data", role: .destructive) { remove(user, delete: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Revoke: they can't sign in anymore, but their shared history stays and a new invite "
                 + "re-enrolls them (reversible). Delete: unlink their banks and erase their accounts, "
                 + "transactions, and history (permanent).")
        }
        .errorAlert($errorText)
    }

    @ViewBuilder
    private func row(_ user: Components.Schemas.UserResponse) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: user.avatar_url, name: user.display_name.titleCased)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(user.display_name.titleCased)
                    if user.is_admin { badge("Admin", .purple) }
                    if !user.enrolled { badge("Revoked", .orange) }
                    if user.identifier == me { badge("You", .gray) }
                }
                if let email = user.email, !email.isEmpty {
                    Label(email, systemImage: "envelope").font(.caption).foregroundStyle(.secondary)
                }
                Text(user.identifier).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            if user.identifier != me {  // can't remove yourself here (avoids self-lockout)
                Button("Remove", role: .destructive) { pendingRemoval = user }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func load() async {
        do { users = try await env.users(context).localUsers() }
        catch { errorText = errorMessage(error) }
    }

    private func remove(_ user: Components.Schemas.UserResponse, delete: Bool) {
        pendingRemoval = nil
        Task {
            do {
                let id = try Mapping.uuid(user.id, field: "User.id")
                if delete {
                    try await env.users(context).delete(id: id)
                } else {
                    try await env.users(context).revoke(id: id)
                }
                await load()
            } catch { errorText = errorMessage(error) }
        }
    }
}
