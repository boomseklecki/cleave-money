import SwiftData
import SwiftUI

/// What a notification deep-links to. Built from a notification's `(entity_type, entity_id)` (the Inbox row)
/// or a push's `userInfo["target"]` (a tapped push). `id` selectors are backend UUIDs except `friend`, which
/// is a person identifier.
enum NotificationTarget: Hashable, Identifiable {
    case expense(UUID), transaction(UUID), account(UUID), goal(UUID), group(UUID), friend(String)

    var id: String {
        switch self {
        case .expense(let u): return "expense:\(u)"
        case .transaction(let u): return "transaction:\(u)"
        case .account(let u): return "account:\(u)"
        case .goal(let u): return "goal:\(u)"
        case .group(let u): return "group:\(u)"
        case .friend(let s): return "friend:\(s)"
        }
    }

    /// Parse a `(type, id)` pair (from `NotificationResponse` or a push payload). Nil when absent/unsupported.
    init?(type: String?, id: String?) {
        guard let type, let id, !id.isEmpty else { return nil }
        switch type {
        case "expense":     guard let u = UUID(uuidString: id) else { return nil }; self = .expense(u)
        case "transaction": guard let u = UUID(uuidString: id) else { return nil }; self = .transaction(u)
        case "account":     guard let u = UUID(uuidString: id) else { return nil }; self = .account(u)
        case "goal":        guard let u = UUID(uuidString: id) else { return nil }; self = .goal(u)
        case "group":       guard let u = UUID(uuidString: id) else { return nil }; self = .group(u)
        case "friend":      self = .friend(id)
        default: return nil
        }
    }
}

/// Resolves a `NotificationTarget` to its detail view by looking up the local cache, with a graceful
/// fallback when the entity hasn't synced to this device yet. Used by both the Inbox row (pushed on the
/// Inbox stack) and the push-tap modal (presented from the root).
struct NotificationTargetView: View {
    let target: NotificationTarget

    @Environment(\.modelContext) private var context
    @Query private var users: [User]
    @Query private var allGroups: [ExpenseGroup]
    @Query private var friends: [Friend]

    var body: some View {
        switch target {
        case .expense(let id):
            if let e = fetchExpense(id) { ExpenseDetailView(expense: e) } else { unavailable }
        case .transaction(let id):
            if let t = fetchTransaction(id) { TransactionDetailView(transaction: t) } else { unavailable }
        case .account(let id):
            if let a = fetchAccount(id) { TransactionsView(account: a) } else { unavailable }
        case .goal(let id):
            if let g = fetchGoal(id) { GoalDetailView(goal: g) } else { unavailable }
        case .group(let id):
            if let g = fetchGroup(id) { GroupDetailView(group: g) } else { unavailable }
        case .friend(let identifier):
            if let f = friends.first(where: { $0.identifier == identifier }) {
                FriendDetailView(friend: FriendRow(friend: f, allGroups: allGroups, users: users))
            } else { unavailable }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("No longer available", systemImage: "questionmark.circle",
            description: Text("This may not have synced to this device yet — pull to refresh."))
    }

    private func fetchExpense(_ id: UUID) -> Expense? {
        (try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.id == id })))?.first
    }
    private func fetchTransaction(_ id: UUID) -> Transaction? {
        (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })))?.first
    }
    private func fetchAccount(_ id: UUID) -> Account? {
        (try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })))?.first
    }
    private func fetchGoal(_ id: UUID) -> Goal? {
        (try? context.fetch(FetchDescriptor<Goal>(predicate: #Predicate { $0.id == id })))?.first
    }
    private func fetchGroup(_ id: UUID) -> ExpenseGroup? {
        (try? context.fetch(FetchDescriptor<ExpenseGroup>(predicate: #Predicate { $0.id == id })))?.first
    }
}
