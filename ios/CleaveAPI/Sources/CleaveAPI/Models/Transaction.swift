import Foundation
import SwiftData

/// A bank/manual transaction. Mirrors the server `transactions` table.
/// Dedupe key for Plaid-sourced rows is `plaidTransactionId`.
///
/// Note: the type name shadows SwiftUI's `Transaction`; qualify as `SwiftUI.Transaction` where the
/// animation type is needed in views.
@Model
final class Transaction {
    @Attribute(.unique) var id: UUID
    var accountId: UUID?
    var plaidTransactionId: String?
    /// On a posted row, the `plaidTransactionId` of the pending charge it replaced (Plaid's value). Lets the
    /// app point a user from a since-posted pending transaction to its posted twin. Null otherwise.
    var pendingTransactionId: String?
    var source: TransactionSource
    var details: String
    var amount: Decimal
    var currency: String
    var date: Date
    var category: String?
    /// Explicit per-transaction canonical category (manual pick or on-device AI on this one row).
    /// Backend-synced and independent of the label-wide category map - wins over it in `effectiveCategory`.
    var categoryOverride: String?
    /// The caller's per-user budget overrides (from `transaction_overrides`); nil = the default (derive from
    /// the account). Excludes this transaction from spending / cash-flow analytics.
    var includeInSpending: Bool?
    var includeInCashFlow: Bool?
    /// The caller's per-user free-text note (from `transaction_overrides`) - a personal annotation to recall
    /// what a vague charge was. nil = none. Never synced to Splitwise; survives Plaid resync.
    var note: String?
    var pending: Bool
    /// The id of the expense linked to this transaction (reverse of `expense.transactionId`), from the server - 
    /// lets the detail resolve the linked expense directly instead of scanning the (possibly-evicted) expense
    /// cache. nil = not linked.
    var linkedExpenseId: UUID?
    /// On-device (Apple Intelligence) category refinement from the merchant description, for rows whose
    /// Plaid category is vague ("Other"/uncategorized). Client-only and derived - not synced, and the
    /// transaction upsert never clears it.
    var refinedCategory: String?
    /// The on-device AI's *opinion* of this transaction's category, kept even when a higher-precedence
    /// layer wins - distinct from `refinedCategory` (a fallback used in resolution). Powers the review
    /// queue's "recategorize" suggestions. Client-only, derived, never synced; survives the upsert.
    var aiSuggestedCategory: String?
    /// Line items breaking this transaction's spend across categories (receipt itemization). Empty for a
    /// flat transaction; when present, analytics attribute each item to its own category.
    @Relationship(deleteRule: .cascade, inverse: \TransactionItem.transaction)
    var items: [TransactionItem]
    /// Receipt images attached to this transaction (polymorphic `receipts` - a receipt is owned by exactly one
    /// of an expense or a transaction). Fetched via the API like expense receipts.
    @Relationship(deleteRule: .cascade, inverse: \Receipt.transaction)
    var receipts: [Receipt]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        accountId: UUID? = nil,
        plaidTransactionId: String? = nil,
        pendingTransactionId: String? = nil,
        source: TransactionSource,
        details: String,
        amount: Decimal,
        currency: String,
        date: Date,
        category: String? = nil,
        categoryOverride: String? = nil,
        includeInSpending: Bool? = nil,
        includeInCashFlow: Bool? = nil,
        note: String? = nil,
        pending: Bool = false,
        linkedExpenseId: UUID? = nil,
        refinedCategory: String? = nil,
        items: [TransactionItem] = [],
        receipts: [Receipt] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.plaidTransactionId = plaidTransactionId
        self.pendingTransactionId = pendingTransactionId
        self.source = source
        self.details = details
        self.amount = amount
        self.currency = currency
        self.date = date
        self.category = category
        self.categoryOverride = categoryOverride
        self.includeInSpending = includeInSpending
        self.includeInCashFlow = includeInCashFlow
        self.note = note
        self.pending = pending
        self.linkedExpenseId = linkedExpenseId
        self.refinedCategory = refinedCategory
        self.items = items
        self.receipts = receipts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
