import Foundation
import SwiftData

/// One participant's share of an expense. Mirrors the server `splits` table.
/// Server rule (self-hosted): sum(paidShare) == sum(owedShare) == expense amount (±0.01).
@Model
final class Split {
    @Attribute(.unique) var id: UUID
    var userIdentifier: String
    var paidShare: Decimal
    var owedShare: Decimal
    var expense: Expense?

    init(
        id: UUID,
        userIdentifier: String,
        paidShare: Decimal,
        owedShare: Decimal,
        expense: Expense? = nil
    ) {
        self.id = id
        self.userIdentifier = userIdentifier
        self.paidShare = paidShare
        self.owedShare = owedShare
        self.expense = expense
    }
}
