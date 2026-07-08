import SwiftUI

/// Manage Zeta-style partner connections: invite someone by email, accept/decline incoming requests,
/// cancel outgoing ones, and disconnect accepted partners. Once connected, each side independently
/// controls what they share (per-account level on the Accounts screen, the "Share with partner" goal
/// toggle) - connecting alone exposes nothing.
struct PartnersView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var connections: [Components.Schemas.ConnectionResponse] = []
    @State private var inviteEmail = ""
    @State private var working = false
    @State private var errorText: String?

    private var incoming: [Components.Schemas.ConnectionResponse] {
        connections.filter { $0.status == "pending" && $0.direction == "incoming" }
    }
    private var outgoing: [Components.Schemas.ConnectionResponse] {
        connections.filter { $0.status == "pending" && $0.direction == "outgoing" }
    }
    private var partners: [Components.Schemas.ConnectionResponse] {
        connections.filter { $0.status == "accepted" }
    }

    var body: some View {
        Form {
            Section {
                TextField("Partner's email", text: $inviteEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Send Invite", action: invite)
                    .disabled(working || inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Invite a Partner")
            } footer: {
                Text("They must already have an account on this server. After they accept, you each choose "
                     + "what to share — nothing is shared automatically.")
            }

            if !incoming.isEmpty {
                Section("Requests") {
                    ForEach(incoming, id: \.id) { c in
                        partnerRow(c) {
                            Button("Accept") { accept(c) }.buttonStyle(.borderless).disabled(working)
                            Button("Decline", role: .destructive) { remove(c) }
                                .buttonStyle(.borderless).disabled(working)
                        }
                    }
                }
            }

            if !outgoing.isEmpty {
                Section("Pending") {
                    ForEach(outgoing, id: \.id) { c in
                        partnerRow(c) {
                            Button("Cancel", role: .destructive) { remove(c) }
                                .buttonStyle(.borderless).disabled(working)
                        }
                    }
                }
            }

            Section("Partners") {
                if partners.isEmpty {
                    Text("No partners yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(partners, id: \.id) { c in
                        partnerRow(c) { EmptyView() }
                            .swipeActions {
                                Button("Disconnect", role: .destructive) { remove(c) }
                            }
                    }
                }
            }
        }
        .navigationTitle("Partners")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }   // reload on each appear so accepted/redeemed changes aren't stale
        .errorAlert($errorText)
    }

    @ViewBuilder
    private func partnerRow<Trailing: View>(
        _ c: Components.Schemas.ConnectionResponse, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: c.other_avatar_url, name: c.other_display_name, size: 32)
            Text(c.other_display_name)
            Spacer()
            trailing()
        }
    }

    private func reload() async {
        do { connections = try await env.connections.list() }
        catch { errorText = errorMessage(error) }
    }

    private func invite() {
        let email = inviteEmail
        working = true
        Task {
            defer { working = false }
            do {
                try await env.connections.invite(email: email)
                inviteEmail = ""
                await reload()
            } catch { errorText = errorMessage(error) }
        }
    }

    private func accept(_ c: Components.Schemas.ConnectionResponse) {
        mutate { try await env.connections.accept(id: Mapping.uuid(c.id, field: "Connection.id")) }
    }

    private func remove(_ c: Components.Schemas.ConnectionResponse) {
        mutate { try await env.connections.remove(id: Mapping.uuid(c.id, field: "Connection.id")) }
    }

    private func mutate(_ action: @escaping () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do { try await action(); await reload() }
            catch { errorText = errorMessage(error) }
        }
    }
}
