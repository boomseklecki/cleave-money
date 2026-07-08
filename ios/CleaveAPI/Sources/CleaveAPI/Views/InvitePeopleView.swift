import SwiftUI
import UIKit

/// Mint a single-use invite link to enroll a new person, and manage outstanding invites.
/// Shown to admins, or to any member when the `invites_open_to_members` server setting is on.
struct InvitePeopleView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var invites: [Components.Schemas.InviteResponse] = []
    @State private var newInviteURL: URL?
    @State private var creating = false
    @State private var errorText: String?

    private var reachable: Bool { JoinLink.isPubliclyReachable(env.baseURLString) }

    /// Only outstanding (unredeemed, unrevoked, unexpired) invites - a redeemed one leaves the list and
    /// instead surfaces as a one-time "accepted your invite" notification to whoever created it.
    private var outstanding: [Components.Schemas.InviteResponse] { invites.filter { $0.status == "active" } }

    var body: some View {
        Form {
            Section {
                Button {
                    create()
                } label: {
                    Label(creating ? "Creating…" : "Create Invite Link", systemImage: "ticket")
                }
                .disabled(creating)
            } footer: {
                Text("A single-use link. Share it with one person — they tap it, sign in, and join this "
                     + "server. Reusing or revoking it stops it working.")
            }

            if let url = newInviteURL {
                Section("Share This Invite") {
                    InviteShareView(url: url, serverName: env.serverName, reachable: reachable)
                }
            }

            if !outstanding.isEmpty {
                Section("Outstanding Invites") {
                    ForEach(outstanding, id: \.id) { invite in
                        if let url = link(for: invite) {
                            NavigationLink {
                                InviteDetailView(invite: invite, url: url, serverName: env.serverName,
                                                 reachable: reachable, onRevoke: { revoke(invite) })
                            } label: {
                                InviteRow(invite: invite)
                            }
                        } else {
                            InviteRow(invite: invite)
                        }
                    }
                }
            }
        }
        .navigationTitle("Invite People")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($errorText)
        .refreshable { await load() }
        .task { await load() }   // reload on each appear so a redeemed invite's status isn't stale
    }

    private func link(for invite: Components.Schemas.InviteResponse) -> URL? {
        JoinLink.url(apiBaseURL: env.baseURLString, name: env.serverName, invite: invite.code)
    }

    private func load() async {
        do { invites = try await env.invites.list() } catch { errorText = errorMessage(error) }
    }

    private func create() {
        creating = true
        Task {
            defer { creating = false }
            do {
                let invite = try await env.invites.create(label: nil)
                newInviteURL = link(for: invite)
                await load()
            } catch { errorText = errorMessage(error) }
        }
    }

    private func revoke(_ invite: Components.Schemas.InviteResponse) {
        guard let id = UUID(uuidString: invite.id) else { return }
        Task {
            do {
                try await env.invites.revoke(id: id)
                if newInviteURL == link(for: invite) { newInviteURL = nil }
                await load()
            } catch { errorText = errorMessage(error) }
        }
    }
}

/// The QR + Share + Copy block for an invite (or server) link. Reused by the just-created invite, the invite
/// detail, and anywhere a link is shared.
struct InviteShareView: View {
    let url: URL
    let serverName: String?
    let reachable: Bool

    var body: some View {
        SwiftUI.Group {
            QRCodeView(string: url.absoluteString)
                .frame(maxWidth: .infinity).frame(height: 200).padding(.vertical, 8)
            ShareLink(item: url,
                      preview: SharePreview(serverName ?? "Cleave", image: Image("AppLogo"))) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            Button { UIPasteboard.general.url = url } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            Text(url.absoluteString)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !reachable {
                Label("This backend address only works on your local network. Set a public (tunnel/HTTPS) "
                      + "Base URL before sharing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// Re-viewable detail for an outstanding active invite: its QR/Share/Copy again, plus Revoke.
private struct InviteDetailView: View {
    let invite: Components.Schemas.InviteResponse
    let url: URL
    let serverName: String?
    let reachable: Bool
    let onRevoke: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section { InviteShareView(url: url, serverName: serverName, reachable: reachable) }
            Section {
                if let exp = invite.expires_at {
                    LabeledContent("Expires", value: exp.formatted(.relative(presentation: .named)))
                }
                Button("Revoke Invite", role: .destructive) {
                    onRevoke()
                    dismiss()
                }
            }
        }
        .navigationTitle(invite.label ?? "Invite")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InviteRow: View {
    let invite: Components.Schemas.InviteResponse

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.label ?? "Invite").font(.body)
                if let by = invite.redeemed_by {
                    Text("Joined by \(by)").font(.caption).foregroundStyle(.secondary)
                } else if let exp = invite.expires_at, invite.status == "active" {
                    Text("Expires \(exp.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(invite.status.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(color(invite.status))
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "active": return .green
        case "redeemed": return .secondary
        default: return .orange  // revoked / expired
        }
    }
}
