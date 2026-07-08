import Foundation
import SwiftData

/// A line item on a bank/manual transaction (e.g. a single product on a receipt). Mirrors
/// `transaction_items`. Unlike `ExpenseItem` there is no owner - a transaction is wholly the viewer's,
/// so each item counts at full price under its category (see `ItemizedSpend.transactionDetailed`).
@Model
final class TransactionItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var quantity: Decimal
    var price: Decimal
    var category: String?
    /// Provenance: who added/edited this item and when.
    var addedBy: String?
    var editedBy: String?
    var addedOn: Date?
    var editedOn: Date?
    var transaction: Transaction?

    init(
        id: UUID,
        name: String,
        quantity: Decimal,
        price: Decimal,
        category: String? = nil,
        addedBy: String? = nil,
        editedBy: String? = nil,
        addedOn: Date? = nil,
        editedOn: Date? = nil,
        transaction: Transaction? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.price = price
        self.category = category
        self.addedBy = addedBy
        self.editedBy = editedBy
        self.addedOn = addedOn
        self.editedOn = editedOn
        self.transaction = transaction
    }
}
