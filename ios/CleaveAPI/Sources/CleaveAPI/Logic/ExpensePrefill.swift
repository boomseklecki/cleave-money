import Foundation

/// Seed values for a new expense, produced from a receipt scan (model extraction or heuristics) or
/// from a bank transaction. The user confirms/adjusts (and enters splits) in `ExpenseEditView`.
struct ExpensePrefill {
    var details: String
    var amount: Decimal
    var date: Date
    var category: String?
    var items: [ItemDraft]
    /// Links the created expense back to the originating transaction, if any.
    var transactionId: UUID? = nil

    /// From a bank/manual transaction (carries `transactionId` so the expense links to it).
    static func from(_ transaction: Transaction) -> ExpensePrefill {
        ExpensePrefill(
            details: transaction.details,
            amount: transaction.amount,
            date: transaction.date,
            category: transaction.category,
            items: [],
            transactionId: transaction.id
        )
    }

    /// From the on-device model extraction. The category is resolved through the **constrained** classifier
    /// over the user's `categories` (the model's free-text guess can't leak an off-list category like
    /// "Beverages"); per-item categories are snapped to the same list.
    static func from(_ extraction: ReceiptExtraction, categories: [String]) async -> ExpensePrefill {
        ExpensePrefill(
            details: extraction.merchant,
            amount: decimal(extraction.total),
            date: recentReceiptDate(Mapping.dateOnlyFormatter.date(from: extraction.date)),
            category: await receiptCategory(merchant: extraction.merchant,
                                            hint: extraction.items.first?.category, categories: categories),
            items: extraction.items.map {
                ItemDraft(name: $0.name, quantity: decimal($0.quantity), price: decimal($0.price),
                          category: matchCategory($0.category, in: categories))
            }
        )
    }

    /// The expense category for a scanned receipt, via the on-device classifier constrained to the user's
    /// `categories` (validates the model's reply against the list, so an invented category can't leak). The
    /// model's per-item guess is passed as a hint. nil when it can't confidently place it.
    static func receiptCategory(merchant: String, hint: String?, categories: [String]) async -> String? {
        let m = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !categories.isEmpty else { return nil }
        let mapped = await CategoryMapper.refine(
            [.init(id: UUID(), description: m, rawCategory: hint, current: nil)], allowed: categories)
        return mapped.values.first
    }

    /// Snaps a free-text category to a valid one: case-insensitive exact match in `categories`, else nil
    /// (never sets a bogus/off-list category).
    static func matchCategory(_ raw: String?, in categories: [String]) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return categories.first { $0.caseInsensitiveCompare(raw) == .orderedSame }
    }

    /// From the model-free heuristic parse.
    static func from(_ result: ReceiptHeuristics.Result) -> ExpensePrefill {
        ExpensePrefill(
            details: result.merchant ?? "",
            amount: result.total ?? 0,
            date: recentReceiptDate(result.date),
            category: nil,
            items: []
        )
    }

    /// Bounds a scanned receipt date to a realistic window. A receipt can't be in the future, and a date
    /// older than `window` days is almost certainly a wrong-year extraction → fall back to today (receipts are
    /// scanned fresh). nil → today. Date-only (start of day). Only the receipt-scan funnels clamp; a bank
    /// transaction's date is authoritative.
    static func recentReceiptDate(_ date: Date?, now: Date = Date(), window: Int = 60) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let earliest = cal.date(byAdding: .day, value: -window, to: today) ?? today
        guard let date, case let d = cal.startOfDay(for: date), d >= earliest, d <= today else { return today }
        return d
    }

    /// Double → Decimal rounded to 2 places (avoids binary-float noise in money).
    private static func decimal(_ value: Double) -> Decimal {
        Decimal(string: String(format: "%.2f", value)) ?? 0
    }
}
