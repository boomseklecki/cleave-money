import Foundation

/// The reorderable sections of the Goals page (the month selector stays pinned at the top and the Trends link
/// pinned at the bottom). The order is stored in `@AppStorage("goalsOrder")` and synced via the preferences
/// blob.
enum GoalSection: String, ReorderableSection {
    case spending, budgets, savings

    var title: String {
        switch self {
        case .spending: return "Spending"
        case .budgets: return "Budgets"
        case .savings: return "Savings Goals"
        }
    }

    var icon: String {
        switch self {
        case .spending: return "chart.pie.fill"
        case .budgets: return "chart.bar.fill"
        case .savings: return "banknote.fill"
        }
    }
}
