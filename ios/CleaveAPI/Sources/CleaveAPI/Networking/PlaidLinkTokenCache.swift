import Foundation

/// Pre-warms a Plaid link token in the background so tapping "Link Bank" opens Plaid Link without waiting on
/// the token round-trip. The fetch is fire-and-forget (it never blocks a screen's load). Link tokens are
/// short-lived, so a cached one is considered usable for ~25 minutes and is consumed (cleared) once handed
/// to a Link session - a token drives a single session.
@MainActor
@Observable
final class PlaidLinkTokenCache {
    static let shared = PlaidLinkTokenCache()
    private init() {}

    private var token: String?
    private var owner: String?        // the user identifier the token was minted for
    private var fetchedAt: Date?
    private var fetching = false

    private static let freshness: TimeInterval = 25 * 60

    private func freshToken(for user: String) -> String? {
        guard let token, owner == user, let fetchedAt,
              Date().timeIntervalSince(fetchedAt) < Self.freshness else { return nil }
        return token
    }

    /// Fetch + cache a token for `user` if there isn't already a fresh one (or a fetch in flight). Silent on
    /// failure - it's only an optimization; "Link Bank" still fetches on demand.
    func prewarm(for user: String, fetch: () async throws -> String) async {
        guard freshToken(for: user) == nil, !fetching else { return }
        fetching = true
        defer { fetching = false }
        if let token = try? await fetch() {
            self.token = token
            self.owner = user
            self.fetchedAt = Date()
        }
    }

    /// Returns a fresh cached token for `user` and clears it (so it isn't reused), or nil if none is ready.
    func take(for user: String) -> String? {
        guard let token = freshToken(for: user) else { return nil }
        clear()
        return token
    }

    func clear() {
        token = nil
        owner = nil
        fetchedAt = nil
    }
}
