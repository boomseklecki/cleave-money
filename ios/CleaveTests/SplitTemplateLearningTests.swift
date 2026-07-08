import XCTest
@testable import CleaveAPI

/// Auto-derivation of split templates from history.
final class SplitTemplateLearningTests: XCTestCase {
    private let me = "me", alex = "alex"

    private func sharedExpense(_ details: String, group: UUID, splits: [(String, Decimal)],
                               category: String? = "Rent", linked: Bool = true) -> Expense {
        let s = splits.map { Split(id: UUID(), userIdentifier: $0.0, paidShare: 0, owedShare: $0.1) }
        return Expense(id: UUID(), groupId: group, transactionId: linked ? UUID() : nil, details: details,
                       amount: splits.reduce(Decimal(0)) { $0 + $1.1 }, currency: "USD", date: Date(),
                       category: category, createdAt: Date(), updatedAt: Date(), splits: s)
    }

    func testDerivesTemplateFromRepeatedSplits() {
        let g = UUID()
        let expenses = [
            sharedExpense("Rent", group: g, splits: [(me, 1000), (alex, 1000)]),
            sharedExpense("Rent", group: g, splits: [(me, 1000), (alex, 1000)]),
        ]
        let templates = SplitTemplateLearning.derive(expenses: expenses)
        XCTAssertEqual(templates.count, 1)
        let t = templates[0]
        XCTAssertEqual(t.merchantKey, MerchantText.key("Rent"))
        XCTAssertEqual(t.groupId, g)
        XCTAssertEqual(t.source, "auto")
        XCTAssertEqual(t.shares[me] ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(t.shares[alex] ?? 0, 0.5, accuracy: 0.01)
    }

    func testOneOffNotDerived() {
        let templates = SplitTemplateLearning.derive(
            expenses: [sharedExpense("Rent", group: UUID(), splits: [(me, 1000), (alex, 1000)])])
        XCTAssertTrue(templates.isEmpty)  // needs ≥2 occurrences
    }

    func testUnlinkedNotDerived() {
        let g = UUID()
        let templates = SplitTemplateLearning.derive(expenses: [
            sharedExpense("Rent", group: g, splits: [(me, 1000), (alex, 1000)], linked: false),
            sharedExpense("Rent", group: g, splits: [(me, 1000), (alex, 1000)], linked: false),
        ])
        XCTAssertTrue(templates.isEmpty)  // only transaction-linked charges count
    }

    func testSoloNotDerived() {
        let g = UUID()
        let templates = SplitTemplateLearning.derive(expenses: [
            sharedExpense("Rent", group: g, splits: [(me, 2000)]),
            sharedExpense("Rent", group: g, splits: [(me, 2000)]),
        ])
        XCTAssertTrue(templates.isEmpty)  // not actually shared (one participant)
    }
}
