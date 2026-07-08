import XCTest
@testable import CleaveAPI

final class SubscriptionDetectorTests: XCTestCase {
    private let cal = Calendar.current

    /// Exact decimal from a string - float literals (e.g. `17.99`) build an imprecise `Decimal`.
    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private func date(_ daysAgo: Int) -> Date {
        cal.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func txn(_ amount: Decimal, _ details: String, daysAgo: Int) -> Transaction {
        Transaction(id: UUID(), accountId: UUID(), source: .plaid, details: details,
                    amount: amount, currency: "USD", date: date(daysAgo), category: "Entertainment",
                    createdAt: Date(), updatedAt: Date())
    }

    private func expense(_ amount: Decimal, _ details: String, me: String = "me", owed: Decimal,
                         daysAgo: Int) -> Expense {
        let split = Split(id: UUID(), userIdentifier: me, paidShare: amount, owedShare: owed)
        return Expense(id: UUID(), groupId: UUID(), details: details, amount: amount, currency: "USD",
                       date: date(daysAgo), category: "Subscriptions",
                       createdAt: Date(), updatedAt: Date(), splits: [split])
    }

    func testMonthlySubscriptionWithPriceIncrease() {
        // Netflix: $15.99 for four months, then $17.99 most recently (every ~30 days).
        let txns = [
            txn(d("15.99"), "NETFLIX.COM", daysAgo: 120),
            txn(d("15.99"), "Netflix.com 866-579-7172", daysAgo: 90),
            txn(d("15.99"), "NETFLIX.COM CA", daysAgo: 60),
            txn(d("15.99"), "NETFLIX.COM", daysAgo: 30),
            txn(d("17.99"), "NETFLIX.COM", daysAgo: 0),
        ]
        let subs = SubscriptionDetector.detect(transactions: txns, expenses: [], lookup: [:], me: "me")
        XCTAssertEqual(subs.count, 1)
        let sub = try! XCTUnwrap(subs.first)
        XCTAssertEqual(sub.cadence, .monthly)
        XCTAssertEqual(sub.latestAmount, d("17.99"))
        XCTAssertEqual(sub.priorAmount, d("15.99"))
        XCTAssertTrue(sub.increased)
        XCTAssertEqual(sub.annualCost, d("215.88"))  // 17.99 × 12
        XCTAssertEqual(sub.charges.count, 5)
        XCTAssertFalse(sub.isShared)
        // Next charge predicted ~30 days after the last one.
        let days = cal.dateComponents([.day], from: sub.lastDate, to: sub.nextDate).day
        XCTAssertEqual(days, 30)
        XCTAssertTrue(sub.displayName.lowercased().contains("netflix"))
    }

    func testIrregularMerchantNotDetected() {
        // Same merchant, but random spacing and wildly different amounts (variable spend, not a sub).
        let txns = [
            txn(12, "AMAZON", daysAgo: 51),
            txn(140, "AMAZON", daysAgo: 44),
            txn(8, "AMAZON", daysAgo: 9),
            txn(63, "AMAZON", daysAgo: 2),
        ]
        XCTAssertTrue(SubscriptionDetector.detect(transactions: txns, expenses: [], lookup: [:], me: "me").isEmpty)
    }

    func testTwoChargesNotEnoughForMonthly() {
        let txns = [txn(9.99, "HULU", daysAgo: 30), txn(9.99, "HULU", daysAgo: 0)]
        XCTAssertTrue(SubscriptionDetector.detect(transactions: txns, expenses: [], lookup: [:], me: "me").isEmpty)
    }

    func testSharedSubscriptionUsesOwedShare() {
        // A monthly Spotify family plan tracked as a Splitwise expense; my half is the recurring amount.
        let exps = [
            expense(20, "Spotify Family", owed: 10, daysAgo: 60),
            expense(20, "Spotify Family", owed: 10, daysAgo: 30),
            expense(20, "Spotify Family", owed: 10, daysAgo: 0),
        ]
        let subs = SubscriptionDetector.detect(transactions: [], expenses: exps, lookup: [:], me: "me")
        let sub = try! XCTUnwrap(subs.first)
        XCTAssertEqual(sub.cadence, .monthly)
        XCTAssertEqual(sub.latestAmount, 10)   // owed share, not the $20 gross
        XCTAssertTrue(sub.isShared)
        XCTAssertEqual(sub.annualCost, 120)
    }

    func testMerchantKeyNormalization() {
        XCTAssertEqual(MerchantText.key("NETFLIX.COM 866-579-7172 CA"), "netflix")
        XCTAssertEqual(MerchantText.key("Spotify USA"), "spotify")
    }

    // MARK: Manual rules + candidates

    func testExcludeRuleDropsDetectedSub() {
        let txns = [txn(d("15.99"), "NETFLIX.COM", daysAgo: 90), txn(d("15.99"), "NETFLIX.COM", daysAgo: 60),
                    txn(d("15.99"), "NETFLIX.COM", daysAgo: 30), txn(d("15.99"), "NETFLIX.COM", daysAgo: 0)]
        XCTAssertEqual(SubscriptionDetector.detect(transactions: txns, expenses: [], lookup: [:], me: "me").count, 1)
        let rule = SubscriptionRule(merchantKey: "netflix", amount: d("15.99"), isSubscription: false, displayName: "Netflix")
        let result = SubscriptionDetector.analyze(transactions: txns, expenses: [], lookup: [:], me: "me", rules: [rule])
        XCTAssertTrue(result.subscriptions.isEmpty)
    }

    func testIncludeRuleForcesUndetectedMerchant() {
        // Two monthly charges - below the 3-occurrence auto bar, so not auto-detected.
        let txns = [txn(d("20.00"), "Claude AI Subscription", daysAgo: 30),
                    txn(d("20.00"), "Claude AI Subscription", daysAgo: 0)]
        XCTAssertTrue(SubscriptionDetector.detect(transactions: txns, expenses: [], lookup: [:], me: "me").isEmpty)
        let key = MerchantText.key("Claude AI Subscription")  // "claude ai" (drops "subscription")
        let rule = SubscriptionRule(merchantKey: key, amount: d("20.00"), isSubscription: true, displayName: "Claude AI")
        let subs = SubscriptionDetector.analyze(transactions: txns, expenses: [], lookup: [:], me: "me", rules: [rule]).subscriptions
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.cadence, .monthly)
    }

    func testIncludeBandToleratesPriceIncrease() {
        // $15 baseline + a $28 charge: too far apart to auto-cluster, but $28 is within the rule's ~2x band.
        let txns = [txn(d("15.00"), "Spotify", daysAgo: 60), txn(d("15.00"), "Spotify", daysAgo: 30),
                    txn(d("28.00"), "Spotify", daysAgo: 0)]
        XCTAssertTrue(SubscriptionDetector.detect(transactions: txns, expenses: [], lookup: [:], me: "me").isEmpty)
        let rule = SubscriptionRule(merchantKey: "spotify", amount: d("15.00"), isSubscription: true, displayName: "Spotify")
        let subs = SubscriptionDetector.analyze(transactions: txns, expenses: [], lookup: [:], me: "me", rules: [rule]).subscriptions
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.latestAmount, d("28.00"))  // the increased charge is matched + included
    }

    func testCandidateSurfacesNearMissAndRuleMovesIt() {
        // Monthly but wildly variable amounts → fails the strict amount cluster → surfaces as a candidate.
        let txns = [txn(d("10.00"), "City Gym", daysAgo: 60), txn(d("30.00"), "City Gym", daysAgo: 30),
                    txn(d("60.00"), "City Gym", daysAgo: 0)]
        let auto = SubscriptionDetector.analyze(transactions: txns, expenses: [], lookup: [:], me: "me", rules: [])
        XCTAssertTrue(auto.subscriptions.isEmpty)
        XCTAssertEqual(auto.candidates.first?.id, "city gym")
        // Once included it becomes a subscription and leaves the candidate list.
        let rule = SubscriptionRule(merchantKey: "city gym", amount: d("30.00"), isSubscription: true, displayName: "City Gym")
        let ruled = SubscriptionDetector.analyze(transactions: txns, expenses: [], lookup: [:], me: "me", rules: [rule])
        XCTAssertEqual(ruled.subscriptions.count, 1)
        XCTAssertTrue(ruled.candidates.isEmpty)
    }
}
