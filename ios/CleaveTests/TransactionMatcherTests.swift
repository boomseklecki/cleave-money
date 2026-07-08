import XCTest
@testable import CleaveAPI

final class TransactionMatcherTests: XCTestCase {
    private func txn(_ amount: Decimal, details: String, daysAgo: Int = 0,
                    date base: Date = Date()) -> Transaction {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: base)!
        return Transaction(id: UUID(), accountId: UUID(), source: .plaid, details: details,
                           amount: amount, currency: "USD", date: d, category: nil,
                           createdAt: Date(), updatedAt: Date())
    }

    /// A $2000 expense where `me` paid in full and owes `owed`, optionally recurring/linked.
    private func expense(_ amount: Decimal, details: String, me: String = "me", owed: Decimal,
                         repeats: Bool = false, transactionId: UUID? = nil, date: Date = Date()) -> Expense {
        let split = Split(id: UUID(), userIdentifier: me, paidShare: amount, owedShare: owed)
        let e = Expense(id: UUID(), groupId: UUID(), transactionId: transactionId, details: details,
                        amount: amount, currency: "USD", date: date, category: "Mortgage",
                        createdAt: Date(), updatedAt: Date(), splits: [split])
        e.repeats = repeats
        return e
    }

    func testFullBillSameDayRanksFirst() {
        let now = Date()
        let exp = expense(2000, details: "Mortgage", owed: 1000, date: now)
        let match = txn(2000, details: "WELLS FARGO MORTGAGE PMT", daysAgo: 0, date: now)
        let off = txn(57, details: "Coffee Shop", daysAgo: 1, date: now)
        let far = txn(2000, details: "Mortgage", daysAgo: 60, date: now)   // outside the window
        let ranked = TransactionMatcher.transactionCandidates(for: exp, transactions: [off, match, far],
                                                   expenses: [exp], me: "me")
        XCTAssertEqual(ranked.first?.transaction.id, match.id)
        XCTAssertFalse(ranked.contains { $0.transaction.id == far.id })   // windowed out
        XCTAssertGreaterThan(ranked.first!.score, 0.8)
    }

    func testMatchesPayerShareWhenBillNotFull() {
        // The expense's full cost is $100 but the user only paid their $50 share from the bank.
        let now = Date()
        let exp = expense(100, details: "Dinner", owed: 50, date: now)
        let mySplit = Split(id: UUID(), userIdentifier: "me", paidShare: 50, owedShare: 50)
        exp.splits = [mySplit]
        let half = txn(50, details: "Dinner", daysAgo: 0, date: now)
        let ranked = TransactionMatcher.transactionCandidates(for: exp, transactions: [half], expenses: [exp], me: "me")
        XCTAssertEqual(ranked.first?.transaction.id, half.id)
    }

    func testExcludesTransactionsLinkedToAnotherExpense() {
        let now = Date()
        let exp = expense(2000, details: "Mortgage", owed: 1000, date: now)
        let candidate = txn(2000, details: "Mortgage", daysAgo: 0, date: now)
        // Another expense already owns that transaction → it must not be suggested.
        let other = expense(2000, details: "Mortgage", owed: 1000, transactionId: candidate.id, date: now)
        let ranked = TransactionMatcher.transactionCandidates(for: exp, transactions: [candidate],
                                                   expenses: [exp, other], me: "me")
        XCTAssertTrue(ranked.isEmpty)
    }

    func testWildlyDifferentAmountDropped() {
        let now = Date()
        let exp = expense(2000, details: "Mortgage", owed: 1000, date: now)
        let unrelated = txn(12, details: "Mortgage paperwork fee", daysAgo: 0, date: now)
        let ranked = TransactionMatcher.transactionCandidates(for: exp, transactions: [unrelated],
                                                   expenses: [exp], me: "me")
        XCTAssertTrue(ranked.isEmpty)  // amount closeness 0 → not a candidate
    }

    // MARK: Exponential precision targets
    // "ACH DEBIT" is all stop words → zero name overlap, so these isolate the amount + date signals.

    private let strictFloor = 0.85  // LinkSensitivity.strict.threshold

    /// Top match score for a `txnAmount` charge `daysAgo` from an `expenseAmount` expense.
    private func firstScore(_ expenseAmount: Decimal, txn txnAmount: Decimal, daysAgo: Int,
                            repeats: Bool) -> Double {
        let now = Date()
        let e = expense(expenseAmount, details: "Rent", owed: expenseAmount, repeats: repeats, date: now)
        let t = txn(txnAmount, details: "ACH DEBIT", daysAgo: daysAgo, date: now)
        return TransactionMatcher.transactionCandidates(for: e, transactions: [t], expenses: [e], me: "me").first?.score ?? 0
    }

    func testRecurringExactTwoDaysClears() {  // the user's true match
        XCTAssertGreaterThanOrEqual(firstScore(100, txn: 100, daysAgo: 2, repeats: true), strictFloor)
    }
    func testNonRecurringExactSameDayClears() {
        XCTAssertGreaterThanOrEqual(firstScore(100, txn: 100, daysAgo: 0, repeats: false), strictFloor)
    }
    func testNonRecurringExactOneDayClears() {  // bank posting lag
        XCTAssertGreaterThanOrEqual(firstScore(100, txn: 100, daysAgo: 1, repeats: false), strictFloor)
    }
    func testNonRecurringExactTwoDaysMisses() {  // no recurrence → require near-same-day
        XCTAssertLessThan(firstScore(100, txn: 100, daysAgo: 2, repeats: false), strictFloor)
    }
    func testNonRecurringNearAmountMisses() {  // "few dollars / few days" false positives
        XCTAssertLessThan(firstScore(100, txn: 103, daysAgo: 2, repeats: false), strictFloor)
    }
    func testNonRecurringSmallAmountDiffSameDayMisses() {  // a few $ off on a big bill isn't the charge, even same-day
        XCTAssertLessThan(firstScore(1000, txn: 1003, daysAgo: 0, repeats: false), strictFloor)
    }
    func testNonRecurringExactFiveDaysMisses() {
        XCTAssertLessThan(firstScore(100, txn: 100, daysAgo: 5, repeats: false), strictFloor)
    }
    func testRecurringExactFiveDaysClears() {  // recurring tolerates billing slack
        XCTAssertGreaterThanOrEqual(firstScore(100, txn: 100, daysAgo: 5, repeats: true), strictFloor)
    }
}
