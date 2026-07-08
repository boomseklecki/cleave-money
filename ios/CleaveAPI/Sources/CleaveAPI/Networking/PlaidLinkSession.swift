import Foundation
import Observation
import LinkKit

/// Routes the Plaid OAuth Universal Link (`https://cleave.money/plaid/oauth`) back into Plaid Link.
///
/// Plaid OAuth opens the bank in a web session and returns via the redirect URI. When the app stayed
/// alive, the live `Handler` resumes directly; when the app was terminated mid-flow, the redirect
/// re-launches the app, and we re-present Link from the persisted link token to resume. This LinkKit
/// build exposes a single resume entry point: `Handler.resumeAfterTermination(from:)`.
@MainActor
@Observable
final class PlaidLinkSession {
    static let shared = PlaidLinkSession()
    private init() {}

    @ObservationIgnored private var handler: Handler?
    private static let tokenKey = "plaid.pendingLinkToken"

    /// A pending resume after app termination - drives an app-level re-presentation of Plaid Link.
    struct Resume: Identifiable { let id = UUID(); let token: String; let redirect: URL }
    var resume: Resume?

    /// True for the Plaid OAuth redirect URL.
    static func isOAuthRedirect(_ url: URL) -> Bool {
        url.host == "cleave.money" && url.path.hasPrefix("/plaid/oauth")
    }

    /// Persist the link token while a Link flow is open, so a terminated OAuth round-trip can resume.
    func begin(token: String) { UserDefaults.standard.set(token, forKey: Self.tokenKey) }

    /// Clear all flow state once Link finishes (success or exit).
    func finish() {
        handler = nil
        resume = nil
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
    }

    /// The active Plaid Link `Handler` registers itself here so an in-process redirect can resume it.
    func register(_ handler: Handler) { self.handler = handler }

    /// Routes a Plaid OAuth Universal Link. Resumes the live handler if Link is still open, else stashes
    /// the redirect (+ persisted token) so the app re-presents Link to finish. Returns whether handled.
    @discardableResult
    func handleOAuthRedirect(_ url: URL) -> Bool {
        guard Self.isOAuthRedirect(url) else { return false }
        if let handler {
            handler.resumeAfterTermination(from: url)
        } else if let token = UserDefaults.standard.string(forKey: Self.tokenKey) {
            resume = Resume(token: token, redirect: url)
        }
        return true
    }
}
