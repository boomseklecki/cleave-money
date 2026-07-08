import Foundation
import SwiftData

/// Plaid link/exchange/sync + linked-item management. Accounts/transactions are reconciled through
/// the existing `AccountRepository`. Linked items are fetched live (not cached).
@MainActor
struct PlaidRepository {
    let client: Client
    let context: ModelContext

    func linkToken(userIdentifier: String) async throws -> String {
        let output = try await client.create_link_token_plaid_link_token_post(
            body: .json(.init(user_identifier: userIdentifier))
        )
        let ok = try output.ok
        return try ok.body.json.link_token
    }

    /// Exchanges a Plaid public token for an item + accounts, caches them, then auto-syncs that new bank.
    /// The initial sync can backfill ~24 months, so call this on the slow client (`AppEnvironment.plaidSlow`).
    func exchange(publicToken: String, userIdentifier: String, institutionName: String? = nil) async throws {
        let output = try await client.exchange_plaid_exchange_post(
            body: .json(.init(public_token: publicToken, user_identifier: userIdentifier, institution_name: institutionName))
        )
        let ok = try output.ok
        let response = try ok.body.json
        try AccountRepository(client: client, context: context).upsertAccounts(response.accounts)
        if let itemId = UUID(uuidString: response.item_id) {
            try await sync(itemId: itemId)  // sync this bank only; refreshes its accounts + transactions
        }
    }

    /// Runs a Plaid sync, then refreshes cached accounts + transactions.
    @discardableResult
    func sync(itemId: UUID? = nil) async throws -> Components.Schemas.SyncResponse {
        let output = try await client.run_sync_plaid_sync_post(
            body: .json(.init(item_id: itemId?.uuidString))
        )
        let ok = try output.ok
        let stats = try ok.body.json
        let accounts = AccountRepository(client: client, context: context)
        try await accounts.refreshAccounts()
        try await accounts.refreshTransactions()
        try await accounts.reapStalePending()  // drop pending rows Plaid removed after they posted
        return stats
    }

    func items() async throws -> [Components.Schemas.PlaidItemResponse] {
        try await client.list_items_plaid_items_get().ok.body.json
    }

    func deleteItem(id: UUID) async throws {
        let output = try await client.delete_item_plaid_items__item_id__delete(
            path: .init(item_id: id.uuidString)
        )
        _ = try output.noContent
    }
}
