import Foundation

/// Breaks an expense into the current user's per-category spend, honoring item assignment: items
/// owned by `me` count at full price under their category; the rest of your owed share
/// (`owedShare − your assigned items`) is spread across the shared items + the non-item remainder
/// (tax/tip) by price. An expense with no items yields a single contribution at your owed share.
enum ItemizedSpend {
    /// Your per-category spend on an expense, summed by category. The drill-through equivalent that keeps
    /// each contributing item's identity is `detailed(for:me:lookup:)`.
    static func categoryContributions(for expense: Expense, me: String,
                                      lookup: [String: String]) -> [(category: String, amount: Decimal)] {
        var totals: [String: Decimal] = [:]
        for entry in detailed(for: expense, me: me, lookup: lookup) {
            totals[entry.category, default: 0] += entry.amount
        }
        return totals.map { (category: $0.key, amount: $0.value) }
    }

    /// Like `categoryContributions`, but one entry per *contributing source*: each item assigned to or
    /// shared with you keeps its `itemId` (for drill-through and per-item rows); the non-item remainder
    /// (tax/tip) and a non-itemized expense have `itemId == nil`. Summing these by category reproduces
    /// `categoryContributions` exactly.
    static func detailed(for expense: Expense, me: String,
                         lookup: [String: String]) -> [(category: String, amount: Decimal, itemId: UUID?)] {
        let owed = expense.splits.first { $0.userIdentifier == me }?.owedShare ?? 0
        let items = expense.items

        guard !items.isEmpty else {
            guard owed > 0, let c = canonical(expense.category, lookup) else { return [] }
            return [(c, owed, nil)]
        }

        var entries: [(category: String, amount: Decimal, itemId: UUID?)] = []
        func add(_ rawCategory: String?, _ amount: Decimal, _ itemId: UUID?) {
            guard amount > 0, let c = canonical(rawCategory ?? expense.category, lookup) else { return }
            entries.append((c, amount, itemId))
        }

        // Item ownership is local-only: for a Splitwise expense the split syncs (and can change there)
        // while items don't, so honoring owners would drift from the owed share. Treat all items as
        // shared → fully proportional, matching the synced owed share.
        let honorOwners = expense.splitwiseExpenseId == nil
        func owner(_ item: ExpenseItem) -> String? { honorOwners ? item.ownerIdentifier : nil }

        // Items assigned to me → full price under their category.
        let mine = items.filter { owner($0) == me }
        for item in mine { add(item.category, item.price, item.id) }
        let assignedToMe = mine.reduce(Decimal(0)) { $0 + $1.price }

        // My share of the shared pool (unassigned items + non-item remainder), spread by price.
        let poolShare = max(owed - assignedToMe, 0)
        if poolShare > 0 {
            let shared = items.filter { owner($0) == nil }
            let itemsTotal = items.reduce(Decimal(0)) { $0 + $1.price }
            let nonItemRemainder = max(expense.amount - itemsTotal, 0)
            let poolTotal = shared.reduce(Decimal(0)) { $0 + $1.price } + nonItemRemainder
            if poolTotal > 0 {
                for item in shared { add(item.category, poolShare * item.price / poolTotal, item.id) }
                add(nil, poolShare * nonItemRemainder / poolTotal, nil)  // remainder → expense category
            } else {
                add(nil, poolShare, nil)
            }
        }
        return entries
    }

    /// A transaction's per-item breakdown, keeping each item's identity. Unlike the expense version there
    /// are no owners/splits - the transaction is wholly the viewer's, so each item counts at full price
    /// under its own category, and the leftover (`amount − Σ item prices`) falls under the transaction's
    /// effective category. The amounts sum to `transaction.amount`. Category may be `nil` (uncategorized),
    /// mirroring a flat transaction; the caller (`resolvedEvents`) only itemizes outflows (`amount > 0`).
    static func transactionDetailed(for transaction: Transaction, lookup: [String: String])
        -> [(category: String?, amount: Decimal, itemId: UUID?)] {
        let items = transaction.items
        guard !items.isEmpty else { return [] }
        let effective = CategoryMapping.effectiveCategory(for: transaction, lookup: lookup)
        var entries: [(category: String?, amount: Decimal, itemId: UUID?)] = []
        var itemsTotal: Decimal = 0
        for item in items {
            itemsTotal += item.price
            guard item.price != 0 else { continue }
            let category = item.category.flatMap { CategoryMapping.canonical($0, lookup: lookup) } ?? effective
            entries.append((category, item.price, item.id))
        }
        let remainder = transaction.amount - itemsTotal
        if remainder != 0 { entries.append((effective, remainder, nil)) }
        return entries
    }

    private static func canonical(_ raw: String?, _ lookup: [String: String]) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return CategoryMapping.canonical(raw, lookup: lookup)
    }
}
