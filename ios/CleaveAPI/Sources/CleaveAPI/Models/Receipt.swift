import Foundation
import SwiftData

/// A receipt image stored in MinIO, owned by exactly one of an expense or a transaction. Mirrors `receipts`.
/// The app references objects by `bucket`/`objectKey` and fetches bytes via the API.
@Model
final class Receipt {
    @Attribute(.unique) var id: UUID
    var bucket: String
    var objectKey: String
    var contentType: String?
    var createdAt: Date
    var expense: Expense?
    var transaction: Transaction?

    init(
        id: UUID,
        bucket: String,
        objectKey: String,
        contentType: String? = nil,
        createdAt: Date,
        expense: Expense? = nil,
        transaction: Transaction? = nil
    ) {
        self.id = id
        self.bucket = bucket
        self.objectKey = objectKey
        self.contentType = contentType
        self.createdAt = createdAt
        self.expense = expense
        self.transaction = transaction
    }
}
