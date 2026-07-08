import Foundation

/// Per-owner notification preference tokens (`"<channel>:<selector>"`: push/feed mutes), server-stored so
/// they sync across devices. The backend enforces `push:` tokens (suppress device push); the client uses
/// `feed:` tokens to hide rows from the Inbox view.
@MainActor
struct NotificationPrefsRepository {
    let client: Client

    func fetch() async throws -> [String] {
        try await client.get_notification_prefs_notification_prefs_get().ok.body.json.tokens
    }

    @discardableResult
    func update(_ tokens: [String]) async throws -> [String] {
        let output = try await client.put_notification_prefs_notification_prefs_put(
            body: .json(.init(tokens: tokens)))
        let ok = try output.ok
        return try ok.body.json.tokens
    }
}
