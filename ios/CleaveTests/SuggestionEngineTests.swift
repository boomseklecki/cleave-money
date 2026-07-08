import XCTest
@testable import CleaveAPI

/// Review-queue suggestion generation: each card type, the explicit-choice guard, and dismissal filtering.
final class SuggestionEngineTests: XCTestCase {
    private let me = "me", alex = "alex"

    private func txn(_ details: String, _ amount: Decimal, category: String? = nil, date: Date = Date(),
                     override: String? = nil, ai: String? = nil) -> Transaction {
        let t = Transaction(id: UUID(), accountId: UUID(), source: .plaid, details: details,
                            amount: amount, currency: "USD", date: date, category: category,
                            categoryOverride: override, createdAt: Date(), updatedAt: Date())
        t.aiSuggestedCategory = ai
        return t
    }

    private func expense(_ details: String, _ amount: Decimal, category: String?,
                         splits: [(String, Decimal)], date: Date = Date(), group: UUID = UUID(),
                         transactionId: UUID? = nil) -> Expense {
        let s = splits.map { Split(id: UUID(), userIdentifier: $0.0, paidShare: 0, owedShare: $0.1) }
        return Expense(id: UUID(), groupId: group, transactionId: transactionId, details: details,
                       amount: amount, currency: "USD", date: date, category: category,
                       createdAt: Date(), updatedAt: Date(), splits: s)
    }

    private func generate(transactions: [Transaction] = [], expenses: [Expense] = [],
                          templates: [SplitTemplate] = [], rules: [SubscriptionRule] = [],
                          decisions: [SuggestionDecision] = [],
                          linkThreshold: Double = SuggestionEngine.defaultLinkThreshold) -> [Suggestion] {
        let subscriptions = SubscriptionDetector.analyze(
            transactions: transactions, expenses: expenses, lookup: [:], me: me, rules: rules).subscriptions
        return SuggestionEngine.generate(transactions: transactions, expenses: expenses, lookup: [:], sources: [:],
                                         templates: templates, rules: rules, subscriptions: subscriptions,
                                         decisions: decisions, me: me, linkThreshold: linkThreshold)
    }

    func testCategorizeOverNonExplicit() {
        // GENERAL_SERVICES resolves to a deterministic "Other"; AI suggests Shopping → one card.
        let cards = generate(transactions: [txn("Store", 10, category: "GENERAL_SERVICES", ai: "Shopping")])
        let cat = cards.filter { $0.kind == .categorize }
        XCTAssertEqual(cat.count, 1)
        XCTAssertEqual(cat.first?.category, "Shopping")
    }

    func testCategorizeSuppressedByExplicitChoice() {
        // An explicit override must not be second-guessed by the AI.
        let cards = generate(transactions: [txn("Store", 10, category: "GENERAL_SERVICES",
                                                 override: "Dining", ai: "Shopping")])
        XCTAssertTrue(cards.filter { $0.kind == .categorize }.isEmpty)
    }

    func testMerchantRuleOverridesConfidentCategory() {
        // A confidently-categorized row (FOOD_AND_DRINK -> Dining) plus a saved rule -> one "Your rule" card
        // to Education. The rule must be able to override a confident built-in category (the Costco $10 case).
        let cards = SuggestionEngine.generateCategorize(
            transactions: [txn("Costco", 10, category: "FOOD_AND_DRINK")], lookup: [:], sources: [:],
            prefCategory: { $0.details == "Costco" ? "Education" : nil })
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.category, "Education")
        XCTAssertEqual(cards.first?.userRule, true)
        XCTAssertEqual(cards.first?.icon, "person.crop.circle.badge.checkmark")
        XCTAssertTrue(cards.first?.id.hasPrefix("prefcat:") ?? false)
    }

    func testMerchantRuleWinsOverAIOpinion() {
        // When both a rule and an AI opinion apply, the user's rule takes priority.
        let cards = SuggestionEngine.generateCategorize(
            transactions: [txn("Costco", 10, category: "GENERAL_SERVICES", ai: "Shopping")],
            lookup: [:], sources: [:], prefCategory: { _ in "Dining" })
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.category, "Dining")
        XCTAssertEqual(cards.first?.userRule, true)
    }

    func testMerchantRuleSuppressedByExplicitChoice() {
        // Already user-set (override) -> no rule card, same guard as the AI path.
        let cards = SuggestionEngine.generateCategorize(
            transactions: [txn("Costco", 10, category: "GENERAL_SERVICES", override: "Groceries")],
            lookup: [:], sources: [:], prefCategory: { _ in "Dining" })
        XCTAssertTrue(cards.isEmpty)
    }

    func testFallsBackToAIWhenNoRule() {
        let cards = SuggestionEngine.generateCategorize(
            transactions: [txn("Store", 10, category: "GENERAL_SERVICES", ai: "Shopping")],
            lookup: [:], sources: [:], prefCategory: { _ in nil })
        XCTAssertEqual(cards.first?.category, "Shopping")
        XCTAssertEqual(cards.first?.userRule, false)
        XCTAssertTrue(cards.first?.id.hasPrefix("cat:") ?? false)
    }

    func testLinkHighConfidence() {
        let e = expense("Dinner", 50, category: "Dining", splits: [(me, 50)])
        let t = txn("Dinner", 50, date: e.date)
        let links = generate(transactions: [t], expenses: [e]).filter { $0.kind == .link }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.expenseId, e.id)
        XCTAssertEqual(links.first?.transactionId, t.id)
        // Confidence rides along for the confirmation sheet.
        XCTAssertEqual(links.first?.matchScore ?? 0, 1.0, accuracy: 0.0001)
    }

    func testLinkThresholdGatesLooserMatches() {
        // Exact amount but 5 days apart and no name overlap → score ≈ 0.78: below Strict (0.85), above Loose.
        let date = Date()
        let e = expense("Acme", 50, category: "Dining", splits: [(me, 50)], date: date)
        let t = txn("Zenith", 50, date: Calendar.current.date(byAdding: .day, value: 5, to: date)!)
        XCTAssertTrue(generate(transactions: [t], expenses: [e], linkThreshold: 0.85)
            .filter { $0.kind == .link }.isEmpty)
        let loose = generate(transactions: [t], expenses: [e], linkThreshold: 0.70).filter { $0.kind == .link }
        XCTAssertEqual(loose.count, 1)
        if let score = loose.first?.matchScore { XCTAssertTrue((0.70..<0.85).contains(score)) }
        else { XCTFail("expected a match score") }
    }

    func testLinkSensitivityThresholds() {
        XCTAssertEqual(LinkSensitivity.strict.threshold, 0.85, accuracy: 0.0001)
        XCTAssertEqual(LinkSensitivity.balanced.threshold, 0.78, accuracy: 0.0001)
        XCTAssertEqual(LinkSensitivity.loose.threshold, 0.70, accuracy: 0.0001)
    }

    func testLinkSensitivityDefaultsStrict() {
        let suite = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LinkSensitivity.current(d), .strict)       // unset → strict (preserves prior behavior)
        d.set(LinkSensitivity.loose.rawValue, forKey: LinkSensitivity.storageKey)
        XCTAssertEqual(LinkSensitivity.current(d), .loose)
    }

    func testSubscriptionCardThenSuppressedByRule() {
        let cal = Calendar.current
        let charges = (0..<4).map { i in
            txn("Netflix", 15, date: cal.date(byAdding: .day, value: -30 * i, to: Date())!)
        }
        let key = MerchantText.key("Netflix")
        let withCard = generate(transactions: charges).filter { $0.kind == .subscription }
        XCTAssertTrue(withCard.contains { $0.merchantKey == key })

        let rule = SubscriptionRule(merchantKey: key, amount: 15, isSubscription: true, displayName: "Netflix")
        let suppressed = generate(transactions: charges, rules: [rule]).filter { $0.kind == .subscription }
        XCTAssertFalse(suppressed.contains { $0.merchantKey == key })
    }

    func testRecurringSplitFromTemplate() {
        let group = UUID()
        let tmpl = SplitTemplate(merchantKey: MerchantText.key("Rent"), groupId: group,
                                 category: "Rent", sharesJSON: SplitTemplate.encode([me: 0.5, alex: 0.5]),
                                 source: "auto", displayName: "Rent")
        let t = txn("Rent", 2000)
        let cards = generate(transactions: [t], templates: [tmpl]).filter { $0.kind == .recurringSplit }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.transactionId, t.id)
    }

    func testDismissalSuppresses() {
        // The categorize card is keyed by merchant (lowercased details) + suggestion, so a dismissal sticks.
        let t = txn("Store", 10, category: "GENERAL_SERVICES", ai: "Shopping")
        let decision = SuggestionDecision(key: "cat:store:Shopping", decision: "dismissed")
        let cards = generate(transactions: [t], decisions: [decision])
        XCTAssertTrue(cards.filter { $0.kind == .categorize }.isEmpty)
    }

    func testCategorizeAggregatesByDescription() {
        // Same merchant + same AI suggestion → one accept-all card; a different merchant → its own.
        let cards = generate(transactions: [
            txn("BURRITO PALACE", 12, category: "GENERAL_SERVICES", ai: "Dining"),
            txn("BURRITO PALACE", 9, category: "GENERAL_SERVICES", ai: "Dining"),
            txn("ACME FUEL", 40, category: "GENERAL_SERVICES", ai: "Fuel"),
        ]).filter { $0.kind == .categorize }
        XCTAssertEqual(cards.count, 2)
        let burrito = cards.first { $0.title == "BURRITO PALACE" }
        XCTAssertEqual(burrito?.transactionIds.count, 2)
        XCTAssertEqual(burrito?.category, "Dining")
        XCTAssertTrue(burrito?.subtitle.contains("2 transactions") ?? false)
        let fuel = cards.first { $0.title == "ACME FUEL" }
        XCTAssertEqual(fuel?.transactionIds.count, 1)
        XCTAssertFalse(fuel?.subtitle.contains("transactions") ?? true)  // no count suffix for a single txn
    }

    func testNeverForMerchantSilencesAllRecategorizeButNotSubscription() {
        // A recategorize card now carries a merchantKey → "Never for this merchant" dismissal blocks ALL
        // recategorize cards for that merchant (e.g. Amazon → any category), kept separate from subscriptions.
        let amzn = "AMZN MKTP US"
        let key = MerchantText.key(amzn)
        let txns = [txn(amzn, 10, category: "GENERAL_SERVICES", ai: "Shopping"),
                    txn(amzn, 25, category: "GENERAL_SERVICES", ai: "Groceries")]   // two different suggestions
        XCTAssertEqual(generate(transactions: txns).filter { $0.kind == .categorize }.count, 2)

        // Dismiss "for merchant" uses the categorize scope key "recat:<key>".
        let dismiss = SuggestionDecision(key: "recat:\(key)", decision: "dismissed")
        XCTAssertTrue(generate(transactions: txns, decisions: [dismiss])
            .filter { $0.kind == .categorize }.isEmpty)                 // every recategorize card silenced

        // The same merchant's subscription card (scope "merchant:<key>") is unaffected.
        let cal = Calendar.current
        let charges = (0..<4).map { i in txn(amzn, 9.99, date: cal.date(byAdding: .day, value: -30 * i, to: Date())!) }
        let subs = generate(transactions: charges, decisions: [dismiss]).filter { $0.kind == .subscription }
        XCTAssertTrue(subs.contains { $0.merchantKey == key })
    }

    func testSplitPassesPartitionByKind() {
        // generateCategorize → only categorize cards; generateDeterministic → never categorize (link/sub/rsplit).
        let cat = SuggestionEngine.generateCategorize(
            transactions: [txn("Store", 10, category: "GENERAL_SERVICES", ai: "Shopping")],
            lookup: [:], sources: [:])
        XCTAssertFalse(cat.isEmpty)
        XCTAssertTrue(cat.allSatisfy { $0.kind == .categorize })

        let e = expense("Dinner", 50, category: "Dining", splits: [(me, 50)])
        let det = SuggestionEngine.generateDeterministic(
            transactions: [txn("Dinner", 50, date: e.date)], expenses: [e], templates: [], rules: [],
            subscriptions: [], me: me)
        XCTAssertTrue(det.allSatisfy { $0.kind != .categorize })
        XCTAssertTrue(det.contains { $0.kind == .link })
    }

    @MainActor
    func testDeterministicCacheMemoizesAndInvalidates() {
        let cache = SuggestionAnalysisCache()
        let t = txn("Netflix", 15.99)
        var computes = 0
        func det(_ txns: [Transaction], threshold: Double = SuggestionEngine.defaultLinkThreshold) -> [Suggestion] {
            cache.deterministicSuggestions(transactions: txns, expenses: [], me: me, rules: [], templates: [],
                                           asOf: Date(), linkThreshold: threshold) {
                computes += 1
                return SuggestionEngine.generateDeterministic(
                    transactions: txns, expenses: [], templates: [], rules: [], subscriptions: [], me: me,
                    linkThreshold: threshold)
            }
        }
        _ = det([t]); _ = det([t])
        XCTAssertEqual(computes, 1)                         // repeat call is a cache hit
        t.aiSuggestedCategory = "Streaming"; _ = det([t])
        XCTAssertEqual(computes, 1)                         // AI-opinion change doesn't invalidate the det memo
        _ = det([t, txn("Spotify", 9.99)])
        XCTAssertEqual(computes, 2)                         // a new transaction invalidates
        _ = det([t], threshold: 0.70)
        XCTAssertEqual(computes, 3)                         // linkThreshold change invalidates
    }

    func testDistributeRoundsToExactTotal() {
        let parts = SuggestionService.distribute(100, fractions: [me: 0.5, alex: 0.5])
        XCTAssertEqual(parts.reduce(Decimal(0)) { $0 + $1.1 }, 100)
        // A 1/3 split still sums exactly (remainder absorbed).
        let thirds = SuggestionService.distribute(100, fractions: ["a": 1, "b": 1, "c": 1])
        XCTAssertEqual(thirds.reduce(Decimal(0)) { $0 + $1.1 }, 100)
    }
}
