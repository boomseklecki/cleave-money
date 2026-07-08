import Foundation

/// One category's spend (donut + budgets).
struct CategorySpend: Identifiable, Equatable {
    let category: String
    let total: Decimal
    var id: String { category }
}

/// A month bucket's value (spending or net income). `month` is the first of the month.
struct MonthlyValue: Identifiable, Equatable {
    let month: Date
    let value: Decimal
    var id: Date { month }
}

/// A normalized spend/cash-flow item from either a Plaid transaction or an expense. Unifying the two
/// lets the Goals/Trends analytics count expenses that never showed up in the bank sync (cash splits,
/// Splitwise) without double-counting the ones already represented by a linked transaction.
/// Sign convention: `amount > 0` is an outflow (spend), `amount < 0` is an inflow.
struct SpendEvent: Identifiable {
    let id: UUID
    let date: Date
    let label: String
    let category: String?
    let amount: Decimal
    let countsInSpending: Bool
    let countsInCashFlow: Bool
}

/// The concrete source behind a `ResolvedSpendEvent`, for drill-through navigation.
enum EventSource {
    case transaction(Transaction)
    case expense(Expense)
}

/// A `SpendEvent` that keeps its source identity: the originating `Transaction`/`Expense` and, for an
/// itemized expense's per-item contribution, the `itemId`. Used by the Goals/Trends drill-throughs to list
/// and navigate to the rows behind each total. `spendEvents` is the identity-erased projection of this.
struct ResolvedSpendEvent: Identifiable {
    let event: SpendEvent
    let source: EventSource
    let itemId: UUID?
    var id: UUID { event.id }
}

/// Pure spend/cash-flow aggregations over a unified `SpendEvent` stream, scoped by accounts' effective
/// inclusion flags (`countsInSpending` / `countsInCashFlow`) and the canonical category map.
enum SpendingAnalytics {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// The gregorian/device-tz calendar used for all month bucketing - shared with `SpendPeriod`.
    static var spendCalendar: Calendar { calendar }

    static func monthStart(_ date: Date, _ cal: Calendar = calendar) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Builds the unified event stream: every Plaid transaction (gross, scoped by its account's flags)
    /// **plus** each non-archived expense, counted at the current user's owed share. Expenses have no
    /// account, so they always count; internal/transfer/income categories are dropped so settle-ups and
    /// reimbursements don't distort spend or cash flow. `me` nil ⇒ no expenses (we can't know your share).
    ///
    /// De-dupe of shared bills: when an expense is **linked** to a transaction (`transactionId`), that
    /// transaction is the same real-world payment, so we drop the gross transaction and keep the expense's
    /// owed share - your true cost on a split bill (e.g. a $2000 mortgage paid from your bank, linked to a
    /// $1000 Splitwise half, counts as $1000, not $2000 + $1000). Unshared expenses net to the same amount.
    static func spendEvents(transactions: [Transaction], accounts: [Account], lookup: [String: String],
                            expenses: [Expense] = [], groups: [ExpenseGroup] = [],
                            me: String? = nil) -> [SpendEvent] {
        resolvedEvents(transactions: transactions, accounts: accounts, lookup: lookup,
                       expenses: expenses, groups: groups, me: me).map(\.event)
    }

    /// The unified stream with source identity retained (see `ResolvedSpendEvent`). `spendEvents` is this
    /// projected to `\.event`, so every analytics total is provably consistent with the drill-through rows.
    ///
    /// Per-user budget overrides (`includeInSpending`/`includeInCashFlow`) layer most-specific-first: a
    /// transaction's own flag, else its account's; an expense's own flag, else its group's, else included.
    /// Excluded events still emit (so drill-throughs are complete) but with their `countsIn*` set false.
    static func resolvedEvents(transactions: [Transaction], accounts: [Account], lookup: [String: String],
                               expenses: [Expense] = [], groups: [ExpenseGroup] = [],
                               me: String? = nil) -> [ResolvedSpendEvent] {
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groupById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Transactions an expense links to: their gross side is dropped in favor of the expense's owed
        // share, so a shared bill paid from your bank isn't double-counted.
        let linkedTxnIds = Set(expenses.lazy.compactMap(\.transactionId))
        var events: [ResolvedSpendEvent] = []

        for t in transactions where t.source == .plaid || t.source == .manual || t.source == .simplefin {
            if linkedTxnIds.contains(t.id) { continue }  // represented by its linked expense's share
            let account = t.accountId.flatMap { byId[$0] }
            // Aggregator transactions (Plaid/SimpleFIN) always belong to an account; skip if it's missing.
            // Manual transactions may be cash with no account - those always count; on an account, honor flags.
            if (t.source == .plaid || t.source == .simplefin) && account == nil { continue }
            // Per-transaction override wins over the account's classification flag.
            let inSpending = t.includeInSpending ?? account?.countsInSpending ?? true
            let inCashFlow = t.includeInCashFlow ?? account?.countsInCashFlow ?? true
            // Itemized outflow: attribute each line item to its own category (keeping its id for the
            // drill-through), with the remainder under the transaction's category. Income/refund rows
            // (amount <= 0) and flat transactions emit a single event.
            if t.amount > 0 && !t.items.isEmpty {
                for d in ItemizedSpend.transactionDetailed(for: t, lookup: lookup) {
                    events.append(ResolvedSpendEvent(
                        event: SpendEvent(
                            id: t.id, date: t.date, label: t.details, category: d.category,
                            amount: d.amount, countsInSpending: inSpending, countsInCashFlow: inCashFlow),
                        source: .transaction(t), itemId: d.itemId))
                }
                continue
            }
            events.append(ResolvedSpendEvent(
                event: SpendEvent(
                    id: t.id, date: t.date, label: t.details,
                    category: CategoryMapping.effectiveCategory(for: t, lookup: lookup),
                    amount: t.amount,
                    countsInSpending: inSpending, countsInCashFlow: inCashFlow),
                source: .transaction(t), itemId: nil))
        }

        if let me {
            // Every expense counts at your owed share, including ones linked to a transaction (whose gross
            // side was dropped above). The per-user include flags (expense, else its group) gate spend/cash.
            for e in expenses {
                guard let category = e.category.flatMap({ CategoryMapping.canonical($0, lookup: lookup) }),
                      !CanonicalCategory.neutral.contains(category) else { continue }  // settle-up/transfer
                let group = groupById[e.groupId]
                let incSpend = e.includeInSpending ?? group?.includeInSpending ?? true
                let incCash = e.includeInCashFlow ?? group?.includeInCashFlow ?? true
                let mySplit = e.splits.first { $0.userIdentifier == me }
                let amount: Decimal
                if CanonicalCategory.incomeLike.contains(category) {
                    // Inflow (negative): your share of received money. Reimbursement encodes the
                    // "gets back" as paidShare; income items use your owed share.
                    let inflow = category == Reimbursement.category ? (mySplit?.paidShare ?? 0)
                                                                    : (mySplit?.owedShare ?? 0)
                    guard inflow > 0 else { continue }
                    amount = -inflow
                } else if !e.items.isEmpty {
                    // Itemized outflow: attribute your share of each item to its own category, keeping
                    // each contributing item's id for the drill-through.
                    for c in ItemizedSpend.detailed(for: e, me: me, lookup: lookup) {
                        events.append(ResolvedSpendEvent(
                            event: SpendEvent(
                                id: e.id, date: e.date, label: e.details, category: c.category,
                                amount: c.amount, countsInSpending: incSpend, countsInCashFlow: incCash),
                            source: .expense(e), itemId: c.itemId))
                    }
                    continue
                } else {
                    let share = mySplit?.owedShare ?? 0
                    guard share > 0 else { continue }  // you consumed nothing (or aren't in this expense)
                    amount = share
                }
                events.append(ResolvedSpendEvent(
                    event: SpendEvent(
                        id: e.id, date: e.date, label: e.details, category: category,
                        amount: amount, countsInSpending: incSpend, countsInCashFlow: incCash),
                    source: .expense(e), itemId: nil))
            }
        }
        return events
    }

    /// Whether an event is spend that counts toward budgets/donut: an outflow on a spending-included
    /// source whose category isn't an internal/transfer/income one.
    static func isSpend(_ e: SpendEvent) -> Bool {
        guard e.countsInSpending, e.amount > 0, let category = e.category else { return false }
        return !CanonicalCategory.excludedFromSpend.contains(category)
    }

    /// Spend by canonical category in the given month, descending.
    static func byCategory(in month: Date, transactions: [Transaction], accounts: [Account],
                           lookup: [String: String], expenses: [Expense] = [],
                           groups: [ExpenseGroup] = [], me: String? = nil) -> [CategorySpend] {
        let cal = calendar
        let target = monthStart(month, cal)
        let events = spendEvents(transactions: transactions, accounts: accounts, lookup: lookup,
                                 expenses: expenses, groups: groups, me: me)
        var totals: [String: Decimal] = [:]
        for e in events where monthStart(e.date, cal) == target && isSpend(e) {
            if let category = e.category { totals[category, default: 0] += e.amount }
        }
        return totals.map { CategorySpend(category: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    /// Spend by canonical category across an inclusive month range `start...end` (both first-of-month),
    /// descending. `start == end` matches a single month (same result as `byCategory(in:)`).
    static func byCategory(from start: Date, to end: Date, transactions: [Transaction],
                           accounts: [Account], lookup: [String: String], expenses: [Expense] = [],
                           groups: [ExpenseGroup] = [], me: String? = nil) -> [CategorySpend] {
        let cal = calendar
        let lo = monthStart(start, cal)
        let hi = monthStart(end, cal)
        let events = spendEvents(transactions: transactions, accounts: accounts, lookup: lookup,
                                 expenses: expenses, groups: groups, me: me)
        var totals: [String: Decimal] = [:]
        for e in events where isSpend(e) {
            let m = monthStart(e.date, cal)
            guard m >= lo, m <= hi, let category = e.category else { continue }
            totals[category, default: 0] += e.amount
        }
        return totals.map { CategorySpend(category: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    /// Total monthly spend for the last `months` months (oldest → newest), zero-filled.
    static func monthlySpending(transactions: [Transaction], accounts: [Account],
                                lookup: [String: String], months: Int, ending: Date = .now,
                                expenses: [Expense] = [], groups: [ExpenseGroup] = [],
                                me: String? = nil) -> [MonthlyValue] {
        let cal = calendar
        let events = spendEvents(transactions: transactions, accounts: accounts, lookup: lookup,
                                 expenses: expenses, groups: groups, me: me)
        var totals: [Date: Decimal] = [:]
        for e in events where isSpend(e) {
            totals[monthStart(e.date, cal), default: 0] += e.amount
        }
        return monthRange(months: months, ending: ending, cal: cal)
            .map { MonthlyValue(month: $0, value: totals[$0] ?? 0) }
    }

    /// Net income (inflow − outflow) per month over cash-flow sources, excluding transfers/settle-ups
    /// (income & reimbursements count as inflow). Negative in deficit months. Last `months` months,
    /// oldest → newest, zero-filled.
    static func monthlyNetIncome(transactions: [Transaction], accounts: [Account],
                                 lookup: [String: String], months: Int, ending: Date = .now,
                                 expenses: [Expense] = [], groups: [ExpenseGroup] = [],
                                 me: String? = nil) -> [MonthlyValue] {
        let cal = calendar
        let events = spendEvents(transactions: transactions, accounts: accounts, lookup: lookup,
                                 expenses: expenses, groups: groups, me: me)
        var totals: [Date: Decimal] = [:]
        for e in events where e.countsInCashFlow {
            if let c = e.category, CanonicalCategory.neutral.contains(c) { continue }  // settle-up/transfer
            // inflow (amount<0) adds to income, outflow (amount>0) subtracts.
            totals[monthStart(e.date, cal), default: 0] -= e.amount
        }
        return monthRange(months: months, ending: ending, cal: cal)
            .map { MonthlyValue(month: $0, value: totals[$0] ?? 0) }
    }

    /// The first-of-month dates for the last `months` months ending in `ending`'s month (oldest first).
    static func monthRange(months: Int, ending: Date, cal: Calendar) -> [Date] {
        let end = monthStart(ending, cal)
        return (0..<max(months, 0)).reversed().compactMap {
            cal.date(byAdding: .month, value: -$0, to: end)
        }
    }
}
