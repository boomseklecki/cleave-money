import Foundation
import SwiftData

/// A line item on an expense (e.g. a single product on a receipt). Mirrors `expense_items`.
@Model
final class ExpenseItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var quantity: Decimal
    var price: Decimal
    var category: String?
    /// The participant this item is assigned to for budget attribution (nil = shared/split).
    var ownerIdentifier: String?
    /// Provenance: who added/edited this item and when.
    var addedBy: String?
    var editedBy: String?
    var addedOn: Date?
    var editedOn: Date?
    var expense: Expense?

    init(
        id: UUID,
        name: String,
        quantity: Decimal,
        price: Decimal,
        category: String? = nil,
        ownerIdentifier: String? = nil,
        addedBy: String? = nil,
        editedBy: String? = nil,
        addedOn: Date? = nil,
        editedOn: Date? = nil,
        expense: Expense? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.price = price
        self.category = category
        self.ownerIdentifier = ownerIdentifier
        self.addedBy = addedBy
        self.editedBy = editedBy
        self.addedOn = addedOn
        self.editedOn = editedOn
        self.expense = expense
    }
}
