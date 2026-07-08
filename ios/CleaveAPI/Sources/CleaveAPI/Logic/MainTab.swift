import Foundation

/// The three reorderable main pages (Settings is pinned separately, always last). The order is stored as a
/// comma-joined `rawValue` string in `@AppStorage("tabOrder")` and synced via the preferences blob.
enum MainTab: String, ReorderableSection {
    case accounts, splits, goals, inbox

    var title: String {
        switch self {
        case .accounts: return "Accounts"
        case .splits: return "Splits"
        case .goals: return "Goals"
        case .inbox: return "Inbox"
        }
    }

    var icon: String {
        switch self {
        case .accounts: return "building.columns.fill"
        case .splits: return "person.2.fill"
        case .goals: return "target"
        case .inbox: return "tray.full.fill"
        }
    }
}
