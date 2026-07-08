import Foundation
import OpenAPIRuntime
import SwiftData

/// In-app OFX statement import (the `fileImporter` path in Settings). Posts the raw OFX bytes to
/// `/statements/import`, then pulls the new account + its transactions into the cache. (The Share Extension
/// uses `StatementUploader` instead, since it can't link the generated client.)
@MainActor
struct StatementRepository {
    let client: Client
    let context: ModelContext

    /// Imports an OFX statement. `force: false` (default) lets the server guard against a card already linked
    /// via Plaid - it returns `plaid_conflict` without importing; `force: true` imports anyway.
    @discardableResult
    func importOFX(_ data: Data, force: Bool = false) async throws -> Components.Schemas.StatementImportResult {
        let output = try await client.import_statement_statements_import_post(
            query: .init(force: force),
            body: .application_x_hyphen_ofx(HTTPBody(data)))
        let created = try output.created
        let result = try created.body.json
        if result.plaid_conflict == true { return result }  // nothing imported - caller confirms, then retries forced
        let accounts = AccountRepository(client: client, context: context)
        try await accounts.refreshAccounts()
        if let id = try? Mapping.uuid(result.account_id, field: "StatementImportResult.account_id") {
            try await accounts.refreshTransactions(accountId: id, limit: 500)
        }
        return result
    }
}
