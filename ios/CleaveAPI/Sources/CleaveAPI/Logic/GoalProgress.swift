import Foundation

/// A budget's standing for the period, driving the progress-bar color.
enum BudgetStatus: Equatable {
    case under    // comfortably within budget
    case nearing  // ≥ 85% of the budget spent
    case over     // exceeded the budget
}

/// Pure progress math for goals. Spend goals sum the month's spend in a category; save goals measure
/// growth from the creation-time snapshot (no balance history to look back on).
enum GoalProgress {
    /// Spend in `category` (canonical) during `month`, across spending-included Plaid accounts plus
    /// unlinked expenses (your owed share).
    static func spent(for category: String, in month: Date, transactions: [Transaction],
                      accounts: [Account], lookup: [String: String],
                      expenses: [Expense] = [], me: String? = nil) -> Decimal {
        SpendingAnalytics.byCategory(in: month, transactions: transactions, accounts: accounts,
                                     lookup: lookup, expenses: expenses, me: me)
            .first { $0.category == category }?.total ?? 0
    }

    static func budgetStatus(spent: Decimal, target: Decimal) -> BudgetStatus {
        guard target > 0 else { return spent > 0 ? .over : .under }
        if spent > target { return .over }
        return fraction(spent, target) >= 0.85 ? .nearing : .under
    }

    /// 0...1 fill fraction for a budget bar (clamped).
    static func budgetFraction(spent: Decimal, target: Decimal) -> Double {
        guard target > 0 else { return spent > 0 ? 1 : 0 }
        return min(max(fraction(spent, target), 0), 1)
    }

    /// 0...1 progress of a savings goal from its starting snapshot toward the target.
    /// `.balance`: progress from starting balance toward the absolute target. `.amount`: progress of
    /// the accrued delta toward the amount to save.
    static func saveFraction(current: Decimal, starting: Decimal, target: Decimal,
                             type: SaveTargetType) -> Double {
        let gained = current - starting
        switch type {
        case .balance:
            let needed = target - starting
            guard needed > 0 else { return current >= target ? 1 : 0 }
            return min(max(fraction(gained, needed), 0), 1)
        case .amount:
            guard target > 0 else { return 0 }
            return min(max(fraction(gained, target), 0), 1)
        }
    }

    private static func fraction(_ a: Decimal, _ b: Decimal) -> Double {
        guard b != 0 else { return 0 }
        return NSDecimalNumber(decimal: a).doubleValue / NSDecimalNumber(decimal: b).doubleValue
    }
}
