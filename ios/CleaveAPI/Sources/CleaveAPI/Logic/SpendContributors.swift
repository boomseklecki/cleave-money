import Foundation

/// One navigable row behind a Goals/Trends total: a transaction, an unlinked expense, or a single item on
/// an itemized expense. Built from `SpendingAnalytics.resolvedEvents`, so the rows for a scope always sum
/// to the matching analytics total (category spend, monthly spend, or monthly net income).
struct SpendContributor: Identifiable {
    let id: String
    let source: EventSource
    let category: String?
    let label: String
    let date: Date
    /// Signed: an outflow (spend) is positive, an inflow (income/reimbursement) is negative.
    let amount: Decimal
    var isInflow: Bool { amount < 0 }
}

enum SpendContributors {
    /// What a contributor list is totaling: one category's spend, all spend, or cash flow (incl. inflows).
    enum Scope: Equatable {
        case category(String)
        case spending
        case cashFlow
    }

    /// The contributing rows for `scope` in `month`, outflows first (largest spend), then inflows.
    static func of(scope: Scope, month: Date, transactions: [Transaction], accounts: [Account],
                   expenses: [Expense] = [], groups: [ExpenseGroup] = [], lookup: [String: String],
                   me: String?) -> [SpendContributor] {
        let m = SpendingAnalytics.monthStart(month)
        return of(scope: scope, from: m, to: m, transactions: transactions, accounts: accounts,
                  expenses: expenses, groups: groups, lookup: lookup, me: me)
    }

    /// The contributing rows for `scope` across an inclusive month range `start...end` (both first-of-month),
    /// outflows first (largest spend), then inflows.
    static func of(scope: Scope, from start: Date, to end: Date, transactions: [Transaction],
                   accounts: [Account], expenses: [Expense] = [], groups: [ExpenseGroup] = [],
                   lookup: [String: String], me: String?) -> [SpendContributor] {
        let lo = SpendingAnalytics.monthStart(start)
        let hi = SpendingAnalytics.monthStart(end)
        let resolved = SpendingAnalytics.resolvedEvents(transactions: transactions, accounts: accounts,
                                                        lookup: lookup, expenses: expenses, groups: groups,
                                                        me: me)
        let rows = resolved
            .filter {
                let m = SpendingAnalytics.monthStart($0.event.date)
                return m >= lo && m <= hi && matches(scope, $0.event)
            }
            .map { contributor(from: $0) }
        // Outflows by amount desc, then inflows by magnitude desc.
        return rows.sorted { a, b in
            if a.isInflow != b.isInflow { return !a.isInflow }
            return abs(a.amount) > abs(b.amount)
        }
    }

    private static func matches(_ scope: Scope, _ e: SpendEvent) -> Bool {
        switch scope {
        case .category(let c): return SpendingAnalytics.isSpend(e) && e.category == c
        case .spending: return SpendingAnalytics.isSpend(e)
        case .cashFlow:
            guard e.countsInCashFlow else { return false }
            if let c = e.category, CanonicalCategory.neutral.contains(c) { return false }  // transfer/settle-up
            return true
        }
    }

    private static func contributor(from r: ResolvedSpendEvent) -> SpendContributor {
        let e = r.event
        var label = e.label
        if let itemId = r.itemId {
            switch r.source {
            case .expense(let expense):
                if let item = expense.items.first(where: { $0.id == itemId }) {
                    label = "\(expense.details) · \(item.name)"
                }
            case .transaction(let transaction):
                if let item = transaction.items.first(where: { $0.id == itemId }) {
                    label = "\(transaction.details) · \(item.name)"
                }
            }
        }
        return SpendContributor(
            id: "\(e.id.uuidString)-\(r.itemId?.uuidString ?? "base")",
            source: r.source, category: e.category, label: label, date: e.date, amount: e.amount)
    }
}
