import XCTest
@testable import CleaveAPI

final class SplitMathTests: XCTestCase {
    func testEqualSplitEvenlyDivisible() {
        let splits = SplitMath.equalSplit(amount: 10, payer: "alice", participants: ["alice", "bob"])
        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(SplitMath.owedSum(splits), 10)
        XCTAssertEqual(SplitMath.paidSum(splits), 10)
        XCTAssertEqual(splits.first(where: { $0.userIdentifier == "alice" })?.paidShare, 10)
        XCTAssertEqual(splits.first(where: { $0.userIdentifier == "bob" })?.paidShare, 0)
        XCTAssertTrue(splits.allSatisfy { $0.owedShare == 5 })
    }

    func testEqualSplitDistributesRemainderPennies() {
        let splits = SplitMath.equalSplit(amount: Decimal(string: "10.01")!,
                                          payer: "a", participants: ["a", "b", "c"])
        // 1001 cents / 3 = 333 each, remainder 2 -> first two get 3.34, last 3.33.
        XCTAssertEqual(SplitMath.owedSum(splits), Decimal(string: "10.01"))
        XCTAssertEqual(splits[0].owedShare, Decimal(string: "3.34"))
        XCTAssertEqual(splits[1].owedShare, Decimal(string: "3.34"))
        XCTAssertEqual(splits[2].owedShare, Decimal(string: "3.33"))
        XCTAssertTrue(SplitMath.isBalanced(amount: Decimal(string: "10.01")!, splits: splits))
    }

    func testWeightedSplitPercentages() {
        // 60/40 of $10 -> $6 / $4; both sum to amount.
        let splits = SplitMath.weightedSplit(amount: 10, payer: "a", participants: ["a", "b"],
                                             weights: ["a": 60, "b": 40])
        XCTAssertEqual(splits.first { $0.userIdentifier == "a" }?.owedShare, 6)
        XCTAssertEqual(splits.first { $0.userIdentifier == "b" }?.owedShare, 4)
        XCTAssertTrue(SplitMath.isBalanced(amount: 10, splits: splits))
    }

    func testWeightedSplitSharesWithRounding() {
        // 1:2 of $10 -> 3.33 / 6.67, sums exactly to 10.
        let splits = SplitMath.weightedSplit(amount: 10, payer: "a", participants: ["a", "b"],
                                             weights: ["a": 1, "b": 2])
        XCTAssertEqual(SplitMath.owedSum(splits), 10)
        XCTAssertTrue(SplitMath.isBalanced(amount: 10, splits: splits))
    }

    func testWeightedSplitZeroWeightsFallsBackToEqual() {
        let splits = SplitMath.weightedSplit(amount: 10, payer: "a", participants: ["a", "b"],
                                             weights: [:])
        XCTAssertTrue(splits.allSatisfy { $0.owedShare == 5 })
    }

    func testAdjustmentSplit() {
        // $20, +$4 for b: base on $16 -> $8 each, b owes $12, a owes $8.
        let splits = SplitMath.adjustmentSplit(amount: 20, payer: "a", participants: ["a", "b"],
                                               adjustments: ["b": 4])
        XCTAssertEqual(splits.first { $0.userIdentifier == "a" }?.owedShare, 8)
        XCTAssertEqual(splits.first { $0.userIdentifier == "b" }?.owedShare, 12)
        XCTAssertTrue(SplitMath.isBalanced(amount: 20, splits: splits))
    }

    func testAdjustmentSplitSubtractsBeforeSplitting() {
        // $30, +$6 on a: remove the $6 first, split $24 equally ($8), then add it back.
        // a owes exactly $6 more than the others; total stays $30.
        let splits = SplitMath.adjustmentSplit(amount: 30, payer: "a", participants: ["a", "b", "c"],
                                               adjustments: ["a": 6])
        XCTAssertEqual(splits.first { $0.userIdentifier == "a" }?.owedShare, 14)
        XCTAssertEqual(splits.first { $0.userIdentifier == "b" }?.owedShare, 8)
        XCTAssertEqual(splits.first { $0.userIdentifier == "c" }?.owedShare, 8)
        XCTAssertTrue(SplitMath.isBalanced(amount: 30, splits: splits))
    }

    func testReimbursementSplit() {
        // a was reimbursed $30 and splits it equally; a owes the others their $10 shares (nets -$20),
        // b and c each get back $10. Encoded as equal split with paid/owed swapped.
        let splits = SplitMath.reimbursementSplit(amount: 30, payer: "a", participants: ["a", "b", "c"])
        let a = splits.first { $0.userIdentifier == "a" }!
        XCTAssertEqual(a.owedShare, 30)              // "a gets back $30"
        XCTAssertEqual(a.paidShare - a.owedShare, -20)  // a owes 20
        XCTAssertEqual(splits.first { $0.userIdentifier == "b" }?.paidShare, 10)  // b gets back 10
        XCTAssertEqual(splits.first { $0.userIdentifier == "b" }?.owedShare, 0)
        XCTAssertTrue(SplitMath.isBalanced(amount: 30, splits: splits))
    }

    func testItemizedSplitWithUnassignedRemainder() {
        // $10 total, b assigned $4 of items; remaining $6 split equally ($3 each).
        let splits = SplitMath.itemizedSplit(amount: 10, payer: "a", participants: ["a", "b"],
                                             assigned: ["b": 4])
        XCTAssertEqual(splits.first { $0.userIdentifier == "a" }?.owedShare, 3)
        XCTAssertEqual(splits.first { $0.userIdentifier == "b" }?.owedShare, 7)
        XCTAssertTrue(SplitMath.isBalanced(amount: 10, splits: splits))
    }

    func testIsBalancedTolerance() {
        let off = [SplitDraft(userIdentifier: "a", paidShare: 10, owedShare: 9)]
        XCTAssertFalse(SplitMath.isBalanced(amount: 10, splits: off))
        let within = [SplitDraft(userIdentifier: "a", paidShare: 10, owedShare: Decimal(string: "9.995")!)]
        XCTAssertTrue(SplitMath.isBalanced(amount: 10, splits: within))
    }

    func testSettleUpCollapse() {
        func expense(_ name: String, category: String?) -> Expense {
            Expense(id: UUID(), groupId: UUID(), details: name, amount: 1, currency: "USD",
                    date: Date(), category: category, createdAt: Date(), updatedAt: Date())
        }
        // Newest-first: two recent, a settle-up, then two older.
        let expenses = [
            expense("new1", category: "food"),
            expense("new2", category: "food"),
            expense("settle", category: SettleUp.category),
            expense("old1", category: "food"),
            expense("old2", category: "food")
        ]
        let result = SettleUp.collapseOlder(expenses)
        XCTAssertEqual(result.visible.map(\.details), ["new1", "new2", "settle"])
        XCTAssertEqual(result.collapsed, 2)
    }

    func testSettleUpNoSettleUpShowsAll() {
        let result = SettleUp.collapseOlder([])
        XCTAssertEqual(result.collapsed, 0)
    }
}
