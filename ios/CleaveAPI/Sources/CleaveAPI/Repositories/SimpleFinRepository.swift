import Foundation
import SwiftData

/// SimpleFIN connect/sync + connection management. Like Plaid, accounts/transactions reconcile through the
/// existing `AccountRepository`; linking is just a pasted setup token (no SDK, no OAuth redirect).
@MainActor
struct SimpleFinRepository {
    let client: Client
    let context: ModelContext

    /// Claims a pasted SimpleFIN setup token, backfills its accounts, and reconciles them. The initial
    /// backfill can pull ~24 months, so call this on the slow client (`AppEnvironment.simplefinSlow`).
    /// Returns the response so the caller can surface any `warnings` (SimpleFIN quota notices + dup advisories).
    @discardableResult
    func connect(setupToken: String) async throws -> Components.Schemas.SimpleFinConnectResponse {
        let output = try await client.connect_simplefin_connect_post(
            body: .json(.init(setup_token: setupToken))
        )
        let response = try output.ok.body.json
        let accounts = AccountRepository(client: client, context: context)
        try accounts.upsertAccounts(response.accounts)
        try await accounts.refreshTransactions()
        return response
    }

    /// Runs a SimpleFIN sync (the server gates it on staleness to protect the ~24/day quota), then refreshes
    /// cached accounts + transactions.
    @discardableResult
    func sync(connectionId: UUID? = nil) async throws -> Components.Schemas.SimpleFinSyncResponse {
        let output = try await client.run_sync_simplefin_sync_post(
            body: .json(.init(connection_id: connectionId?.uuidString))
        )
        let stats = try output.ok.body.json
        let accounts = AccountRepository(client: client, context: context)
        try await accounts.refreshAccounts()
        try await accounts.refreshTransactions()
        try await accounts.reapStalePending()  // drop pending rows gone from the latest window
        return stats
    }

    /// Fold a just-connected SimpleFIN account into an existing one, choosing which source feeds it going
    /// forward (`primarySource`). The backend preserves existing history + suppresses the non-primary sources.
    func merge(incoming: UUID, target: UUID,
               primarySource: Components.Schemas.TransactionSource) async throws {
        let output = try await client.merge_simplefin_merge_post(body: .json(.init(
            incoming_account_id: incoming.uuidString, target_account_id: target.uuidString,
            primary_source: primarySource)))
        _ = try output.noContent
    }

    /// Set (or clear, with nil) the last-4 mask on an account - SimpleFIN has no mask field, so the user can
    /// type it; it shows on the row and tightens future cross-source matching.
    func setMask(accountId: UUID, mask: String?) async throws {
        let output = try await client.set_mask_simplefin_accounts__account_id__mask_post(
            path: .init(account_id: accountId.uuidString), body: .json(.init(mask: mask)))
        _ = try output.noContent
    }

    func connections() async throws -> [Components.Schemas.SimpleFinConnectionResponse] {
        try await client.list_connections_simplefin_connections_get().ok.body.json
    }

    func deleteConnection(id: UUID) async throws {
        let output = try await client.delete_connection_simplefin_connections__connection_id__delete(
            path: .init(connection_id: id.uuidString)
        )
        _ = try output.noContent
    }
}
