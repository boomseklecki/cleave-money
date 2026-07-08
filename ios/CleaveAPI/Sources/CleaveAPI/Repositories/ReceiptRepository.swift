import Foundation
import SwiftData
import OpenAPIRuntime

/// Receipts are proxied through the API: upload posts the raw image bytes in one call; viewing fetches
/// the bytes back from `/receipts/{id}/content`. The app reaches only the API host - never MinIO - and
/// auth is applied automatically by the generated client's middleware.
@MainActor
struct ReceiptRepository {
    let client: Client
    let context: ModelContext

    /// Uploads one image's bytes and attaches it to `expenseId`, then refreshes the expense so the
    /// new receipt lands in the cache.
    func upload(expenseId: UUID, imageData: Data) async throws {
        let output = try await client.upload_receipt_expenses__expense_id__receipts_post(
            path: .init(expense_id: expenseId.uuidString),
            body: .binary(HTTPBody(imageData))
        )
        _ = try output.created
        try await ExpenseRepository(client: client, context: context).refreshDetail(id: expenseId)
    }

    /// Uploads several images concurrently and refreshes the expense ONCE (vs N upload + N refetch via
    /// `upload`). Returns how many failed plus the last error, so the caller can surface partial failures.
    func uploadMany(expenseId: UUID, images: [Data]) async -> (failed: Int, lastError: Error?) {
        guard !images.isEmpty else { return (0, nil) }
        let client = self.client
        let errors = await withTaskGroup(of: Error?.self) { group in
            for imageData in images {
                group.addTask {
                    do {
                        let output = try await client.upload_receipt_expenses__expense_id__receipts_post(
                            path: .init(expense_id: expenseId.uuidString),
                            body: .binary(HTTPBody(imageData)))
                        _ = try output.created
                        return nil
                    } catch { return error }
                }
            }
            var out: [Error] = []
            for await e in group { if let e { out.append(e) } }
            return out
        }
        try? await ExpenseRepository(client: client, context: context).refreshDetail(id: expenseId)
        return (errors.count, errors.last)
    }

    /// Uploads one image's bytes and attaches it to `transactionId`, then re-fetches the transaction so the
    /// new receipt lands in the cache (the upload response carries only the receipt).
    func upload(transactionId: UUID, imageData: Data) async throws {
        let output = try await client.upload_transaction_receipt_transactions__transaction_id__receipts_post(
            path: .init(transaction_id: transactionId.uuidString),
            body: .binary(HTTPBody(imageData))
        )
        _ = try output.created
        try await AccountRepository(client: client, context: context).refreshTransaction(id: transactionId)
    }

    /// Uploads several images concurrently to a transaction and re-fetches it ONCE. Returns the failure count
    /// + last error for partial-failure surfacing.
    func uploadMany(transactionId: UUID, images: [Data]) async -> (failed: Int, lastError: Error?) {
        guard !images.isEmpty else { return (0, nil) }
        let client = self.client
        let errors = await withTaskGroup(of: Error?.self) { group in
            for imageData in images {
                group.addTask {
                    do {
                        let output = try await client
                            .upload_transaction_receipt_transactions__transaction_id__receipts_post(
                                path: .init(transaction_id: transactionId.uuidString),
                                body: .binary(HTTPBody(imageData)))
                        _ = try output.created
                        return nil
                    } catch { return error }
                }
            }
            var out: [Error] = []
            for await e in group { if let e { out.append(e) } }
            return out
        }
        try? await AccountRepository(client: client, context: context).refreshTransaction(id: transactionId)
        return (errors.count, errors.last)
    }

    /// Fetches a receipt's raw image bytes (with the stored content type) for rendering.
    func imageData(receiptId: UUID) async throws -> Data {
        let output = try await client.download_receipt_receipts__receipt_id__content_get(
            path: .init(receipt_id: receiptId.uuidString)
        )
        let ok = try output.ok
        return try await Data(collecting: ok.body.binary, upTo: 20 * 1024 * 1024)
    }

    func delete(receiptId: UUID, expenseId: UUID) async throws {
        try await delete(receiptId: receiptId) {
            try await ExpenseRepository(client: client, context: context).refreshDetail(id: expenseId)
        }
    }

    func delete(receiptId: UUID, transactionId: UUID) async throws {
        try await delete(receiptId: receiptId) {
            try await AccountRepository(client: client, context: context).refreshTransaction(id: transactionId)
        }
    }

    /// Deletes a receipt (its owner is resolved server-side by `receipt_id`), then runs the owner-specific
    /// refresh so the deletion lands in the cache.
    private func delete(receiptId: UUID, refresh: () async throws -> Void) async throws {
        let output = try await client.delete_receipt_receipts__receipt_id__delete(
            path: .init(receipt_id: receiptId.uuidString)
        )
        _ = try output.noContent
        try await refresh()
    }
}
