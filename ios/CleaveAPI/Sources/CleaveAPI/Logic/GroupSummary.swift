import Foundation
import SwiftData

/// Shared helpers for summarizing groups by *your* balance and latest expense. Used by the Expenses
/// list and the transaction→expense group picker so both hide settled groups and sort by recent
/// activity identically.
@MainActor
enum GroupSummary {
    typealias Last = (date: Date, isSettleUp: Bool)

    /// Your net per group (group id → net) from the cached `GroupBalance` rows. Empty when not signed in;
    /// groups whose balance hasn't been cached yet are simply absent (treated as unknown, not settled).
    static func myNets(from rows: [GroupBalance], me: String?) -> [UUID: Decimal] {
        guard let me else { return [:] }
        var result: [UUID: Decimal] = [:]
        for row in rows where row.userIdentifier == me { result[row.groupId] = row.net }
        return result
    }

    /// Latest expense per group (date + settle-up flag) via a single-row fetch per group. Skips groups
    /// already hidden by a zero balance unless `includeSettled`, so unseen rows cost nothing.
    static func lastExpenses(_ groups: [ExpenseGroup], myNets: [UUID: Decimal],
                             includeSettled: Bool, context: ModelContext) -> [UUID: Last] {
        var result: [UUID: Last] = [:]
        for group in groups {
            if !includeSettled, let net = myNets[group.id], net == 0 { continue }
            let gid = group.id
            var descriptor = FetchDescriptor<Expense>(
                predicate: #Predicate { $0.groupId == gid },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            if let latest = try? context.fetch(descriptor).first {
                result[group.id] = (latest.date, latest.category == SettleUp.category)
            }
        }
        return result
    }

    /// A group is "settled" when your net is zero or its latest expense is a settle-up. Groups with an
    /// unknown balance (not signed in) are never auto-hidden.
    static func isSettled(_ group: ExpenseGroup, myNets: [UUID: Decimal], lastExpense: [UUID: Last]) -> Bool {
        if let net = myNets[group.id], net == 0 { return true }
        if lastExpense[group.id]?.isSettleUp == true { return true }
        return false
    }

    /// Groups sorted by most-recent activity (latest expense date, descending).
    static func byActivity(_ groups: [ExpenseGroup], lastExpense: [UUID: Last]) -> [ExpenseGroup] {
        groups.sorted { (lastExpense[$0.id]?.date ?? .distantPast) > (lastExpense[$1.id]?.date ?? .distantPast) }
    }

    /// The groups to show in a picker: hide settled (unless `includeSettled`), then sort by recent
    /// activity. Shared by the transaction→expense picker and the expense editor's group switcher.
    static func visible(_ groups: [ExpenseGroup], myNets: [UUID: Decimal],
                        lastExpense: [UUID: Last], includeSettled: Bool) -> [ExpenseGroup] {
        let shown = includeSettled ? groups
            : groups.filter { !isSettled($0, myNets: myNets, lastExpense: lastExpense) }
        return byActivity(shown, lastExpense: lastExpense)
    }
}
