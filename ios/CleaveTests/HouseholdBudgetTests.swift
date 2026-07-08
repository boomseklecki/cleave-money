import XCTest
import SwiftData
@testable import CleaveAPI

/// Combined household budgets over shared-group expenses: split owed shares, item-level categories + owners,
/// Splitwise canonicalization, exclusion of non-shared groups, and the contributor drill-through.
final class HouseholdBudgetTests: XCTestCase {
    private let me = "me", alex = "alex"

    private func member(_ id: String, _ label: String, viewer: Bool) -> HouseholdBudget.Member {
        HouseholdBudget.Member(identifier: id, label: label, isViewer: viewer)
    }

    private func members(_ group: UUID, _ ids: [String]) -> [GroupMember] {
        ids.map { GroupMember(id: UUID(), groupId: group, userIdentifier: $0, createdAt: Date()) }
    }

    private func item(_ name: String, _ price: Decimal, category: String?, owner: String?) -> ExpenseItem {
        ExpenseItem(id: UUID(), name: name, quantity: 1, price: price, category: category,
                    ownerIdentifier: owner)
    }

    private func expense(group: UUID, amount: Decimal, category: String?, splits: [(String, Decimal)],
                         items: [ExpenseItem] = [], date: Date = Date(), splitwiseId: String? = nil,
                         transactionId: UUID? = nil, details: String = "e") -> Expense {
        let s = splits.map { Split(id: UUID(), userIdentifier: $0.0, paidShare: 0, owedShare: $0.1) }
        return Expense(id: UUID(), groupId: group, transactionId: transactionId, splitwiseExpenseId: splitwiseId,
                       details: details, amount: amount, currency: "USD", date: date, category: category,
                       createdAt: Date(), updatedAt: Date(), splits: s, items: items)
    }

    private func shared(_ group: UUID, members ms: [GroupMember]) -> Set<UUID> {
        HouseholdBudget.sharedGroupIds(viewer: me, partners: [alex],
                                       membersByGroup: HouseholdBudget.membership(ms))
    }

    // A 50/50 split dinner in a shared group: both owed shares count, split You/Partner.
    func testSplitExpenseCombines() {
        let g = UUID()
        let ms = members(g, [me, alex])
        let e = expense(group: g, amount: 100, category: "Dining", splits: [(me, 50), (alex, 50)])
        let byCat = HouseholdBudget.combinedByCategory(
            month: Date(), expenses: [e], sharedGroupIds: shared(g, members: ms), viewer: me, partners: [alex])
        let dining = byCat["Dining"]
        XCTAssertEqual(dining?.mine, 50)
        XCTAssertEqual(dining?.partnerTotal, 50)
        XCTAssertEqual(dining?.combined, 100)
    }

    // Itemized: an item owned by each partner lands under its own canonical category for that owner.
    func testItemizedPerOwnerCategories() {
        let g = UUID()
        let ms = members(g, [me, alex])
        let items = [item("Wine", 20, category: "Dining", owner: me),
                     item("Veg", 30, category: "Groceries", owner: alex)]
        let e = expense(group: g, amount: 50, category: "Groceries",
                        splits: [(me, 20), (alex, 30)], items: items)
        let byCat = HouseholdBudget.combinedByCategory(
            month: Date(), expenses: [e], sharedGroupIds: shared(g, members: ms), viewer: me, partners: [alex])
        XCTAssertEqual(byCat["Dining"]?.mine, 20)            // my item
        XCTAssertEqual(byCat["Dining"]?.partnerTotal, 0)
        XCTAssertEqual(byCat["Groceries"]?.partnerTotal, 30) // alex's item
        XCTAssertEqual(byCat["Groceries"]?.mine, 0)
    }

    // A Splitwise expense's raw label maps deterministically to canonical "Dining" (not the raw string).
    func testSplitwiseCanonicalization() {
        let g = UUID()
        let ms = members(g, [me, alex])
        let e = expense(group: g, amount: 100, category: "Dining out",
                        splits: [(me, 50), (alex, 50)], splitwiseId: "sw-1")
        let byCat = HouseholdBudget.combinedByCategory(
            month: Date(), expenses: [e], sharedGroupIds: shared(g, members: ms), viewer: me, partners: [alex])
        XCTAssertEqual(byCat["Dining"]?.combined, 100)
        XCTAssertNil(byCat["Dining out"])  // the ugly raw label is never the bucket
    }

    // An expense in a group the partner doesn't belong to is not "shared" → excluded entirely.
    func testNonSharedGroupExcluded() {
        let g = UUID()
        let ms = members(g, [me])  // alex not a member
        let e = expense(group: g, amount: 100, category: "Dining", splits: [(me, 100)])
        let ids = shared(g, members: ms)
        XCTAssertTrue(ids.isEmpty)
        let byCat = HouseholdBudget.combinedByCategory(
            month: Date(), expenses: [e], sharedGroupIds: ids, viewer: me, partners: [alex])
        XCTAssertNil(byCat["Dining"])
    }

    // A shared expense linked to a transaction still counts once (via the expense); transactions never enter.
    func testLinkedTransactionCountsOnceViaExpense() {
        let g = UUID()
        let ms = members(g, [me, alex])
        let e = expense(group: g, amount: 80, category: "Groceries",
                        splits: [(me, 40), (alex, 40)], transactionId: UUID())
        let byCat = HouseholdBudget.combinedByCategory(
            month: Date(), expenses: [e], sharedGroupIds: shared(g, members: ms), viewer: me, partners: [alex])
        XCTAssertEqual(byCat["Groceries"]?.combined, 80)
    }

    // Only the selected month's expenses count.
    func testMonthScoping() {
        let g = UUID()
        let ms = members(g, [me, alex])
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        let e = expense(group: g, amount: 100, category: "Dining",
                        splits: [(me, 50), (alex, 50)], date: lastMonth)
        let byCat = HouseholdBudget.combinedByCategory(
            month: Date(), expenses: [e], sharedGroupIds: shared(g, members: ms), viewer: me, partners: [alex])
        XCTAssertNil(byCat["Dining"])  // last month's expense isn't in this month
    }

    // The drill-through yields one row per (member with a share), tagged who, summing to the combined total.
    func testContributorsTaggedByMember() {
        let g = UUID()
        let ms = members(g, [me, alex])
        let e = expense(group: g, amount: 100, category: "Dining", splits: [(me, 50), (alex, 50)])
        let rows = HouseholdBudget.contributors(
            category: "Dining", from: Date(), to: Date(), expenses: [e],
            sharedGroupIds: shared(g, members: ms),
            household: [member(me, "You", viewer: true), member(alex, "Alex", viewer: false)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.amount).reduce(0, +), 100)
        XCTAssertTrue(rows.contains { $0.who == "You" && $0.amount == 50 })
        XCTAssertTrue(rows.contains { $0.who == "Alex" && $0.amount == 50 })
    }
}
