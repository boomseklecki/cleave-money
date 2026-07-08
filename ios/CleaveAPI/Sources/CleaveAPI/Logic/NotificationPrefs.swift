import Foundation

/// User-facing notification categories. Each maps to the raw selectors (notification `type` codes or
/// `source:<src>`) that the per-channel mute tokens are built from.
enum NotificationBucket: String, CaseIterable, Identifiable {
    case splitwise, expenses, shares, connections

    var id: String { rawValue }

    var label: String {
        switch self {
        case .splitwise: return "Splitwise activity"
        case .expenses: return "Expenses & settle-ups"
        case .shares: return "Shared accounts & goals"
        case .connections: return "Connection requests"
        }
    }

    /// Selectors covered - a notification `type` code, or `source:<src>`.
    var selectors: [String] {
        switch self {
        case .splitwise: return ["source:splitwise"]
        case .expenses: return ["expense_added", "expense_edited", "expense_deleted", "settle_up"]
        case .shares: return ["account_shared", "goal_shared"]
        case .connections: return ["connection_request", "connection_accepted"]
        }
    }
}

/// Shared, observable cache of the per-owner notification preference tokens (`"<channel>:<selector>"`).
/// `feed:` tokens hide a kind from this device's Inbox view; `push:` tokens suppress its device push
/// (enforced server-side). Server is the source of truth (cross-device sync); mirrored to `UserDefaults`
/// so the Inbox filter + badge work at launch before the fetch lands. `@Observable` so the Inbox
/// re-filters the moment a toggle flips.
@MainActor
@Observable
final class NotificationPrefs {
    static let shared = NotificationPrefs()

    private(set) var tokens: Set<String>
    private let defaults: UserDefaults
    private static let storeKey = "notificationPrefs.tokens"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.tokens = Set(defaults.stringArray(forKey: Self.storeKey) ?? [])
    }

    /// Replace the cache from the server's token set.
    func apply(_ serverTokens: [String]) {
        tokens = Set(serverTokens)
        persist()
    }

    /// Clears the in-memory + mirrored mute tokens so the prior owner's notification prefs don't carry into the
    /// next account before its own tokens are fetched (sign-out / wipe).
    func reset() {
        tokens = []
        defaults.removeObject(forKey: Self.storeKey)
    }

    /// Inbox view filter: hide a notification whose type or source is `feed:`-muted.
    func isHidden(type: String?, source: String?) -> Bool {
        if let source, tokens.contains("feed:source:\(source)") { return true }
        if let type, tokens.contains("feed:\(type)") { return true }
        return false
    }

    /// Settings toggle state: "Show in Inbox" on = no `feed:` token covers the bucket.
    func isShown(_ bucket: NotificationBucket) -> Bool {
        !bucket.selectors.contains { tokens.contains("feed:\($0)") }
    }

    /// Settings toggle state: "Push" on = no `push:` token covers the bucket.
    func isPushed(_ bucket: NotificationBucket) -> Bool {
        !bucket.selectors.contains { tokens.contains("push:\($0)") }
    }

    /// Flip a channel (`feed`/`push`) for a bucket; `on` = unmuted. Returns the new token list to persist.
    func set(_ bucket: NotificationBucket, channel: String, on: Bool) -> [String] {
        for selector in bucket.selectors {
            let token = "\(channel):\(selector)"
            if on { tokens.remove(token) } else { tokens.insert(token) }
        }
        persist()
        return Array(tokens)
    }

    private func persist() { defaults.set(Array(tokens), forKey: Self.storeKey) }
}
