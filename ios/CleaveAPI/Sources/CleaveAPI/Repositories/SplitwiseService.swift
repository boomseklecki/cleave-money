import Foundation

/// Splitwise connection status, cold-backfill import, and the scoped incremental sync endpoints
/// (`/splitwise/status`, `/splitwise/import`, `/splitwise/sync/{groups,users,expenses}`).
@MainActor
struct SplitwiseService {
    let client: Client

    func status() async throws -> (connected: Bool, users: [String]) {
        let response = try await client.status_splitwise_status_get().ok.body.json
        return (response.connected, response.users)
    }

    /// Begins connecting Splitwise to the *signed-in* user. The backend binds the OAuth state to the verified
    /// caller (the bearer this request carries), so the resulting token can only attach to that user; returns
    /// the Splitwise authorize URL to open in the browser.
    func startConnect() async throws -> URL {
        let output = try await client.start_auth_splitwise_start_post()
        let ok = try output.ok
        guard let url = URL(string: try ok.body.json.authorize_url) else {
            throw BackendError.fromUndocumented(502)
        }
        return url
    }

    /// Kicks off a one-time, background download of every not-yet-downloaded Splitwise receipt (newest-first,
    /// rate-limited, server-side - the caller can navigate away). Returns whether it was enabled (the backfill
    /// setting must be on) and how many receipts were queued.
    @discardableResult
    func downloadAllReceipts() async throws -> (enabled: Bool, pending: Int) {
        let output = try await client.download_all_receipts_splitwise_receipts_download_all_post()
        let ok = try output.ok
        let json = try ok.body.json
        return (json.enabled, json.pending)
    }

    /// Runs the cold-backfill import with the stored token; returns the number of expenses imported.
    @discardableResult
    func runImport() async throws -> Int {
        let output = try await client.run_import_splitwise_import_post(body: .json(.init()))
        let ok = try output.ok
        return try ok.body.json.imported
    }

    /// Incremental expense sync (since the server-side cursor): new/edited/settled expenses, and
    /// archives expenses Splitwise deleted. Returns (imported, archived) counts.
    @discardableResult
    func syncExpenses() async throws -> (imported: Int, deleted: Int) {
        let output = try await client.sync_expenses_splitwise_sync_expenses_post(body: .json(.init()))
        let ok = try output.ok
        let json = try ok.body.json
        return (json.imported ?? 0, json.deleted ?? 0)
    }

    /// Refreshes Splitwise group metadata + members.
    func syncGroups() async throws {
        let output = try await client.sync_groups_splitwise_sync_groups_post(body: .json(.init()))
        _ = try output.ok
    }

    /// Refreshes the Splitwise users directory (members + current user).
    func syncUsers() async throws {
        let output = try await client.sync_users_splitwise_sync_users_post(body: .json(.init()))
        _ = try output.ok
    }

    // MARK: - Scoped (drill-in) syncs
    // Narrow the live pull to one group / friend / expense (the backend leaves the token cursor untouched).

    /// Refreshes one Splitwise group's metadata + members and its expenses only.
    func syncGroup(_ splitwiseGroupId: String) async throws {
        let output = try await client.sync_group_splitwise_sync_group__splitwise_group_id__post(
            path: .init(splitwise_group_id: splitwiseGroupId), body: .json(.init()))
        _ = try output.ok
    }

    /// Refreshes the expenses shared with one friend (resolved by local identifier).
    func syncFriend(_ identifier: String) async throws {
        let output = try await client.sync_friend_splitwise_sync_friend__identifier__post(
            path: .init(identifier: identifier), body: .json(.init()))
        _ = try output.ok
    }

    /// Refreshes a single expense (upsert, or archive when Splitwise has deleted it).
    func syncExpense(_ splitwiseExpenseId: String) async throws {
        let output = try await client.sync_expense_splitwise_sync_expense__splitwise_expense_id__post(
            path: .init(splitwise_expense_id: splitwiseExpenseId), body: .json(.init()))
        _ = try output.ok
    }

    /// Caches the token owner's Splitwise friends (identity), so a friend with no shared group still
    /// resolves to a name/avatar.
    func syncFriends() async throws {
        let output = try await client.sync_friends_splitwise_sync_friends_post(body: .json(.init()))
        _ = try output.ok
    }

    /// Pulls recent Splitwise notifications into the generic notifications store (pruned server-side).
    func syncNotifications() async throws {
        let output = try await client.sync_notifications_splitwise_sync_notifications_post(body: .json(.init()))
        _ = try output.ok
    }

    /// The caller's cached notifications (any source), newest first.
    func notifications() async throws -> [Components.Schemas.NotificationResponse] {
        let output = try await client.list_notifications_splitwise_notifications_get()
        let ok = try output.ok
        return try ok.body.json
    }
}
