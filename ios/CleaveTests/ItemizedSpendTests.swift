import XCTest
@testable import CleaveAPI

/// Per-item category attribution feeding spend-by-category / budgets / the donut. Pure - builds standalone
/// models (init takes `splits:`/`items:` directly).
final class ItemizedSpendTests: XCTestCase {
    private func split(_ id: String, owed: Decimal) -> Split {
        Split(id: UUID(), userIdentifier: id, paidShare: 0, owedShare: owed)
    }
    private func item(_ category: String?, _ price: Decimal, owner: String? = nil) -> ExpenseItem {
        ExpenseItem(id: UUID(), name: category ?? "item", quantity: 1, price: price,
                    category: category, ownerIdentifier: owner)
    }
    private func expense(amount: Decimal, category: String?, splits: [Split],
                         items: [ExpenseItem] = [], splitwise: Bool = false) -> Expense {
        Expense(id: UUID(), groupId: UUID(), splitwiseExpenseId: splitwise ? "sw1" : nil,
                details: "e", amount: amount, currency: "USD", date: Date(), category: category,
                createdAt: Date(), updatedAt: Date(), splits: splits, items: items)
    }
    private func byCategory(_ e: Expense) -> [String: Decimal] {
        Dictionary(ItemizedSpend.categoryContributions(for: e, me: "me", lookup: [:])
            .map { ($0.category, $0.amount) }, uniquingKeysWith: +)
    }

    func testNoItemsIsSingleOwedShare() {
        let e = expense(amount: 100, category: "Groceries", splits: [split("me", owed: 40)])
        let d = ItemizedSpend.detailed(for: e, me: "me", lookup: [:])
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.category, "Groceries")
        XCTAssertEqual(d.first?.amount, 40)
        XCTAssertNil(d.first?.itemId)
    }

    func testZeroOwedOrNilCategoryYieldsNothing() {
        XCTAssertTrue(ItemizedSpend.detailed(
            for: expense(amount: 100, category: "Groceries", splits: [split("me", owed: 0)]),
            me: "me", lookup: [:]).isEmpty)
        XCTAssertTrue(ItemizedSpend.detailed(
            for: expense(amount: 100, category: nil, splits: [split("me", owed: 40)]),
            me: "me", lookup: [:]).isEmpty)
    }

    func testItemizedHonorsOwners() {
        // amount 100 (items 80 + $20 tax/tip remainder), I owe 60. My $50 Groceries item counts full; the
        // remaining $10 of my share spreads over the shared $30 Dining item + $20 remainder by price.
        let e = expense(amount: 100, category: "Groceries", splits: [split("me", owed: 60)],
                        items: [item("Groceries", 50, owner: "me"), item("Dining", 30)])
        let c = byCategory(e)
        XCTAssertEqual(c["Groceries"] ?? 0, 54, accuracy: 0.001)   // 50 + 10*(20/50)
        XCTAssertEqual(c["Dining"] ?? 0, 6, accuracy: 0.001)       // 10*(30/50)
        XCTAssertEqual((c.values.reduce(0, +)), 60, accuracy: 0.001)  // == owed share
    }

    func testSplitwiseExpenseIgnoresOwners() {
        // Same shape, but a Splitwise expense: owners are ignored (items don't sync), so my $60 share is fully
        // proportional across all $100 of price+remainder.
        let e = expense(amount: 100, category: "Groceries", splits: [split("me", owed: 60)],
                        items: [item("Groceries", 50, owner: "me"), item("Dining", 30)], splitwise: true)
        let c = byCategory(e)
        XCTAssertEqual(c["Groceries"] ?? 0, 42, accuracy: 0.001)   // 60*(50/100) + 60*(20/100)
        XCTAssertEqual(c["Dining"] ?? 0, 18, accuracy: 0.001)      // 60*(30/100)
    }

    func testTransactionDetailedSumsToAmount() {
        let items = [TransactionItem(id: UUID(), name: "a", quantity: 1, price: 30, category: "Groceries"),
                     TransactionItem(id: UUID(), name: "b", quantity: 1, price: 20, category: nil)]
        let t = Transaction(id: UUID(), accountId: UUID(), source: .plaid, details: "t", amount: 100,
                            currency: "USD", date: Date(), category: "FOOD_AND_DRINK", items: items,
                            createdAt: Date(), updatedAt: Date())
        let d = ItemizedSpend.transactionDetailed(for: t, lookup: [:])
        XCTAssertEqual(d.reduce(Decimal(0)) { $0 + $1.amount }, 100)   // sums to the whole txn
        let byCat = Dictionary(d.compactMap { e in e.category.map { ($0, e.amount) } }, uniquingKeysWith: +)
        XCTAssertEqual(byCat["Groceries"], 30)                        // item's own category
        XCTAssertEqual(byCat["Dining"], 70)                           // nil-item ($20) + remainder ($50) → effective
        // No items → empty.
        let flat = Transaction(id: UUID(), accountId: UUID(), source: .plaid, details: "t", amount: 10,
                               currency: "USD", date: Date(), category: "FOOD_AND_DRINK",
                               createdAt: Date(), updatedAt: Date())
        XCTAssertTrue(ItemizedSpend.transactionDetailed(for: flat, lookup: [:]).isEmpty)
    }
}
