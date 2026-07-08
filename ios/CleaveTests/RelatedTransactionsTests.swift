import XCTest
@testable import CleaveAPI

final class RelatedTransactionsTests: XCTestCase {
    private let cal = Calendar.current

    private func date(_ daysAgo: Int) -> Date {
        cal.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func txn(_ details: String, _ amount: Decimal = 20, daysAgo: Int = 0,
                     source: TransactionSource = .plaid) -> Transaction {
        Transaction(id: UUID(), accountId: UUID(), source: source, details: details,
                    amount: amount, currency: "USD", date: date(daysAgo), category: "Software",
                    createdAt: Date(), updatedAt: Date())
    }

    /// The user's case: three description variants of one merchant. Seeding from the multi-word variant
    /// catches all three via shared "anthropic"/"claude" tokens.
    func testMultiWordSeedGroupsAllVariants() {
        let all = [txn("ANTHROPIC"), txn("ANTHROPIC CLAUDE SUB"), txn("CLAUDE.AI SUBSCRIPTION"),
                   txn("NETFLIX.COM")]
        let group = RelatedTransactions.group(seedDescription: "ANTHROPIC CLAUDE SUB", in: all)
        let details = Set(group.map(\.details))
        XCTAssertEqual(details, ["ANTHROPIC", "ANTHROPIC CLAUDE SUB", "CLAUDE.AI SUBSCRIPTION"])
        XCTAssertFalse(details.contains("NETFLIX.COM"))
    }

    /// Conservative / seed-relative: a bare seed only matches descriptions sharing *its* word, so it does
    /// not transitively reach "CLAUDE.AI SUBSCRIPTION".
    func testBareSeedIsConservative() {
        let all = [txn("ANTHROPIC"), txn("ANTHROPIC CLAUDE SUB"), txn("CLAUDE.AI SUBSCRIPTION")]
        let details = Set(RelatedTransactions.group(seedDescription: "ANTHROPIC", in: all).map(\.details))
        XCTAssertEqual(details, ["ANTHROPIC", "ANTHROPIC CLAUDE SUB"])
        XCTAssertFalse(details.contains("CLAUDE.AI SUBSCRIPTION"))
    }

    func testUnrelatedMerchantExcluded() {
        let all = [txn("SPOTIFY USA"), txn("NETFLIX.COM"), txn("HULU 877-824-4858")]
        let group = RelatedTransactions.group(seedDescription: "SPOTIFY", in: all)
        XCTAssertEqual(group.map(\.details), ["SPOTIFY USA"])
    }

    /// A noise-only / empty seed has nothing meaningful to match on → empty group.
    func testNoiseOnlySeedGroupsNothing() {
        let all = [txn("ANTHROPIC"), txn("SUBSCRIPTION PAYMENT")]
        XCTAssertTrue(RelatedTransactions.group(seedDescription: "SUBSCRIPTION PAYMENT", in: all).isEmpty)
        XCTAssertTrue(RelatedTransactions.group(seedDescription: "", in: all).isEmpty)
    }

    func testResultsSortedNewestFirst() {
        let all = [txn("ANTHROPIC", daysAgo: 30), txn("ANTHROPIC CLAUDE", daysAgo: 0),
                   txn("ANTHROPIC", daysAgo: 60)]
        let group = RelatedTransactions.group(seedDescription: "ANTHROPIC", in: all)
        XCTAssertEqual(group.map(\.date), group.map(\.date).sorted(by: >))
    }

    func testDisplayNameTitleCasesBrandWords() {
        XCTAssertEqual(RelatedTransactions.displayName(for: "ANTHROPIC CLAUDE SUB"), "Anthropic Claude Sub")
        XCTAssertEqual(RelatedTransactions.displayName(for: "CLAUDE.AI SUBSCRIPTION"), "Claude")
    }

    // MARK: - Strictness tiers

    /// One shared generic word ("joes"/"trader") over-matches under Fuzzy but is cut by Balanced/Strict.
    func testTiersFilterSingleSharedWord() {
        let all = [txn("TRADER JOES #123"), txn("JOES CRAB SHACK"), txn("TRADER VICS")]
        func names(_ s: RelatedTransactions.MatchStrictness) -> Set<String> {
            Set(RelatedTransactions.group(seedDescription: "TRADER JOES #456", in: all, strictness: s)
                .map(\.details))
        }
        XCTAssertEqual(names(.fuzzy), ["TRADER JOES #123", "JOES CRAB SHACK", "TRADER VICS"])
        XCTAssertEqual(names(.balanced), ["TRADER JOES #123"])
        XCTAssertEqual(names(.strict), ["TRADER JOES #123"])
        XCTAssertEqual(names(.exact), ["TRADER JOES #123"])   // same merchant key
    }

    /// Two-of-three shared words: Balanced keeps it (0.667 > 0.5), Strict drops it (neither set is a subset).
    func testBalancedVsStrictDiverge() {
        let all = [txn("BLUE BOTTLE CAFE")]
        let seed = "BLUE BOTTLE COFFEE"
        XCTAssertEqual(RelatedTransactions.group(seedDescription: seed, in: all, strictness: .balanced).count, 1)
        XCTAssertTrue(RelatedTransactions.group(seedDescription: seed, in: all, strictness: .strict).isEmpty)
    }

    /// The default strictness is Balanced (a single-word overlap out of 2+ tokens is excluded).
    func testDefaultStrictnessIsBalanced() {
        let all = [txn("JOES CRAB SHACK")]
        XCTAssertTrue(RelatedTransactions.group(seedDescription: "TRADER JOES", in: all).isEmpty)
    }

    // MARK: - Exact merchant + amount axis

    /// The leak the user hit: seeding "APPLE STORE", a different merchant sharing only the generic word
    /// "store" ("STORE 24") leaks in under Strict (symmetric subset) but is excluded by Exact (merchant key).
    func testExactMerchantExcludesGenericWordLeak() {
        let all = [txn("APPLE STORE #123"), txn("STORE 24"), txn("APPLE STORE #456")]
        let strict = Set(RelatedTransactions.group(seedDescription: "APPLE STORE", in: all,
                                                   strictness: .strict).map(\.details))
        XCTAssertTrue(strict.contains("STORE 24"))                       // the old leak
        let exact = Set(RelatedTransactions.group(seedDescription: "APPLE STORE", in: all,
                                                  strictness: .exact).map(\.details))
        XCTAssertEqual(exact, ["APPLE STORE #123", "APPLE STORE #456"])  // no leak
    }

    /// Amount is now its own axis, independent of the merchant level: Any keeps all same-merchant rows
    /// (the user's varying-amount OFX case), Equal isolates the identical charge, Close keeps within-tolerance.
    func testAmountAxisIndependentOfMerchant() {
        let all = [txn("APPLE.COM/BILL", 9.99, daysAgo: 0), txn("APPLE.COM/BILL", 9.99, daysAgo: 30),
                   txn("APPLE.COM/BILL", 10.49, daysAgo: 10), txn("APPLE.COM/BILL", 4.99, daysAgo: 5)]
        func amounts(_ m: RelatedTransactions.AmountMatch) -> Set<Decimal> {
            Set(RelatedTransactions.group(seedDescription: "APPLE.COM/BILL", seedAmount: 9.99, in: all,
                                          strictness: .exact, amount: m).map(\.amount))
        }
        XCTAssertEqual(amounts(.any), [9.99, 10.49, 4.99])   // exact merchant, all amounts
        XCTAssertEqual(amounts(.equal), [9.99])              // identical only
        XCTAssertEqual(amounts(.close), [9.99, 10.49])       // within $1; not the $4.99
    }

    func testAmountsClose() {
        XCTAssertTrue(RelatedTransactions.amountsClose(9.99, 10.49))   // within $1
        XCTAssertTrue(RelatedTransactions.amountsClose(100, 120))      // within 25%
        XCTAssertTrue(RelatedTransactions.amountsClose(1.00, 1.50))    // small amounts (within $1)
        XCTAssertFalse(RelatedTransactions.amountsClose(9.99, 4.99))   // > $1 and > 25%
        XCTAssertFalse(RelatedTransactions.amountsClose(100, 130))     // 30% apart
    }

    /// The matcher is generic over `RelatedItem` (both `Transaction` and `Expense` conform), so the expense
    /// "Find Related Expenses" path groups identically - covered here without constructing SwiftData models.
    func testGenericGroupingOverRelatedItem() {
        struct Item: RelatedItem { let details: String; let amount: Decimal; let date: Date }
        let all = [Item(details: "UBER TRIP", amount: 12, date: date(0)),
                   Item(details: "UBER EATS", amount: 30, date: date(1)),
                   Item(details: "LYFT RIDE", amount: 12, date: date(2))]
        let fuzzy = RelatedTransactions.group(seedDescription: "UBER", in: all, strictness: .fuzzy)
        XCTAssertEqual(Set(fuzzy.map(\.details)), ["UBER TRIP", "UBER EATS"])   // share "uber"
        let equalAmt = RelatedTransactions.group(seedDescription: "UBER", seedAmount: 12, in: all,
                                                 strictness: .fuzzy, amount: .equal)
        XCTAssertEqual(Set(equalAmt.map(\.details)), ["UBER TRIP"])            // uber + $12 only
    }
}
