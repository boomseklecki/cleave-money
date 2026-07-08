import Foundation
import SwiftData

/// An expense in a group, with its splits, line items, and receipts.
/// Mirrors the server `expenses` table. Dedupe key for Splitwise-sourced rows is
/// `splitwiseExpenseId`.
@Model
final class Expense {
    @Attribute(.unique) var id: UUID
    var groupId: UUID
    var transactionId: UUID?
    var splitwiseExpenseId: String?
    var details: String
    var amount: Decimal
    var currency: String
    var date: Date
    var category: String?
    /// Splitwise provenance: who added/edited it and the real added/edited timestamps (distinct from
    /// createdAt/updatedAt, which track when we imported the row). Plus notes, comments, recurrence.
    var createdByIdentifier: String?
    var updatedByIdentifier: String?
    var splitwiseCreatedAt: Date?
    var splitwiseUpdatedAt: Date?
    var notes: String?
    var commentsCount: Int?
    var repeats: Bool?
    var repeatInterval: String?
    var expenseBundleId: String?
    /// Splitwise receipt image URL (remote) + the simplified repayments as a raw JSON string, from import.
    var splitwiseReceiptURL: String?
    var splitwiseRepayments: String?
    /// The caller's per-user budget overrides (from `expense_overrides`); null = the default (included).
    /// Excludes this expense's owed-share from spending / cash-flow analytics without changing balances.
    var includeInSpending: Bool?
    var includeInCashFlow: Bool?
    /// The caller's per-user free-text note (from `expense_overrides`) - a personal annotation, distinct from
    /// the shared/Splitwise `notes`. nil = none. Never synced to Splitwise; survives resync.
    var note: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Split.expense)
    var splits: [Split]
    @Relationship(deleteRule: .cascade, inverse: \ExpenseItem.expense)
    var items: [ExpenseItem]
    @Relationship(deleteRule: .cascade, inverse: \Receipt.expense)
    var receipts: [Receipt]

    init(
        id: UUID,
        groupId: UUID,
        transactionId: UUID? = nil,
        splitwiseExpenseId: String? = nil,
        details: String,
        amount: Decimal,
        currency: String,
        date: Date,
        category: String? = nil,
        createdByIdentifier: String? = nil,
        updatedByIdentifier: String? = nil,
        splitwiseCreatedAt: Date? = nil,
        splitwiseUpdatedAt: Date? = nil,
        notes: String? = nil,
        commentsCount: Int? = nil,
        repeats: Bool? = nil,
        repeatInterval: String? = nil,
        expenseBundleId: String? = nil,
        splitwiseReceiptURL: String? = nil,
        splitwiseRepayments: String? = nil,
        includeInSpending: Bool? = nil,
        includeInCashFlow: Bool? = nil,
        note: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        splits: [Split] = [],
        items: [ExpenseItem] = [],
        receipts: [Receipt] = []
    ) {
        self.id = id
        self.groupId = groupId
        self.transactionId = transactionId
        self.splitwiseExpenseId = splitwiseExpenseId
        self.details = details
        self.amount = amount
        self.currency = currency
        self.date = date
        self.category = category
        self.createdByIdentifier = createdByIdentifier
        self.updatedByIdentifier = updatedByIdentifier
        self.splitwiseCreatedAt = splitwiseCreatedAt
        self.splitwiseUpdatedAt = splitwiseUpdatedAt
        self.notes = notes
        self.commentsCount = commentsCount
        self.repeats = repeats
        self.repeatInterval = repeatInterval
        self.expenseBundleId = expenseBundleId
        self.splitwiseReceiptURL = splitwiseReceiptURL
        self.splitwiseRepayments = splitwiseRepayments
        self.includeInSpending = includeInSpending
        self.includeInCashFlow = includeInCashFlow
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.splits = splits
        self.items = items
        self.receipts = receipts
    }
}
