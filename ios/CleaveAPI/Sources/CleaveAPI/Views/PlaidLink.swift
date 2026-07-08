import SwiftUI
import SwiftData

/// A pending Plaid Link session (its link token), driving the `fullScreenCover`. Shared by every screen that
/// links a bank.
struct LinkSession: Identifiable { let id = UUID(); let token: String }

/// The Plaid Link presentation as a reusable modifier: the `fullScreenCover` + `PlaidLinkView` wrapper +
/// `PlaidLinkSession.shared.finish()` + token prewarm lifecycle. Each host keeps its own `linkBank()` (local
/// token cache/user checks) and passes its post-link refresh via `onExchange`.
struct PlaidLinkModifier: ViewModifier {
    @Binding var session: LinkSession?
    let onExchange: (String) async -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $session) { session in
            PlaidLinkView(
                linkToken: session.token,
                onSuccess: { publicToken in
                    self.session = nil
                    PlaidLinkSession.shared.finish()
                    Task { await onExchange(publicToken) }
                },
                onExit: {
                    self.session = nil
                    PlaidLinkSession.shared.finish()
                    env.prewarmPlaidLinkToken(context)  // ready a fresh token for a quick retry
                }
            )
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// Present the Plaid Link flow when `session` is set. `onExchange` receives the public token for the host's
    /// exchange + reload.
    func plaidLink(session: Binding<LinkSession?>, onExchange: @escaping (String) async -> Void) -> some View {
        modifier(PlaidLinkModifier(session: session, onExchange: onExchange))
    }
}
