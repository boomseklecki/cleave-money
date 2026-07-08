import XCTest
@testable import CleaveAPI

/// Category provenance resolution (which precedence layer won) + the Splitwise raw-label display fix.
final class CategoryProvenanceTests: XCTestCase {
    private func txn(_ category: String?, override: String? = nil, refined: String? = nil) -> Transaction {
        let t = Transaction(id: UUID(), accountId: UUID(), source: .plaid, details: "t",
                            amount: 10, currency: "USD", date: Date(), category: category,
                            createdAt: Date(), updatedAt: Date())
        t.categoryOverride = override
        t.refinedCategory = refined
        return t
    }

    private func map(_ raw: String, _ canonical: String, source: String) -> CategoryMap {
        CategoryMap(id: UUID(), rawCategory: raw, canonicalCategory: canonical, source: source,
                    createdAt: Date(), updatedAt: Date())
    }

    func testOverrideWins() {
        let r = CategoryMapping.resolve(for: txn("FOOD_AND_DRINK_GROCERIES", override: "Dining"), lookup: [:])
        XCTAssertEqual(r.category, "Dining")
        XCTAssertEqual(r.source, .override)
    }

    func testMappedByYouVsAI() {
        let manual = [map("CUSTOM_RAW", "Shopping", source: "manual")]
        let you = CategoryMapping.resolve(for: txn("CUSTOM_RAW"),
            lookup: CategoryMapping.lookup(manual), sources: CategoryMapping.sources(manual))
        XCTAssertEqual(you.category, "Shopping")
        XCTAssertEqual(you.source, .mappedByYou)

        let ai = [map("CUSTOM_RAW", "Shopping", source: "ondevice")]
        let resolved = CategoryMapping.resolve(for: txn("CUSTOM_RAW"),
            lookup: CategoryMapping.lookup(ai), sources: CategoryMapping.sources(ai))
        XCTAssertEqual(resolved.source, .mappedByAI)
    }

    func testDeterministicPlaid() {
        let r = CategoryMapping.resolve(for: txn("FOOD_AND_DRINK_GROCERIES"), lookup: [:])
        XCTAssertEqual(r.category, "Groceries")
        XCTAssertEqual(r.source, .deterministic)
    }

    func testAiRefinedFallback() {
        // GENERAL_SERVICES → "Other" (vague), so the per-transaction AI refinement wins.
        let r = CategoryMapping.resolve(for: txn("GENERAL_SERVICES", refined: "Shopping"), lookup: [:])
        XCTAssertEqual(r.category, "Shopping")
        XCTAssertEqual(r.source, .aiRefined)
    }

    func testRefinedBeatsConfidentDeterministic() {
        // A deliberate AI refinement now outranks even a confident built-in Plaid mapping.
        let r = CategoryMapping.resolve(for: txn("FOOD_AND_DRINK_GROCERIES", refined: "Dining"), lookup: [:])
        XCTAssertEqual(r.category, "Dining")
        XCTAssertEqual(r.source, .aiRefined)
    }

    func testRefinedOnRowWithNoRawCategory() {
        // Plaid never labeled it (nil raw); the AI refinement is what categorizes it.
        let r = CategoryMapping.resolve(for: txn(nil, refined: "Shopping"), lookup: [:])
        XCTAssertEqual(r.category, "Shopping")
        XCTAssertEqual(r.source, .aiRefined)
    }

    func testOverrideBeatsRefined() {
        // A manual pick (override) still wins over an AI refinement.
        let r = CategoryMapping.resolve(for: txn("FOOD_AND_DRINK", override: "Travel", refined: "Shopping"),
                                        lookup: [:])
        XCTAssertEqual(r.category, "Travel")
        XCTAssertEqual(r.source, .override)
    }

    func testRawPassthrough() {
        let r = CategoryMapping.resolve(for: txn("ZZZ_UNKNOWN_LABEL"), lookup: [:])
        XCTAssertEqual(r.category, "ZZZ_UNKNOWN_LABEL")
        XCTAssertEqual(r.source, .raw)
    }

    func testSplitwiseExpenseCanonicalizes() {
        let r = CategoryMapping.resolve(expenseCategory: "Dining out", lookup: [:])
        XCTAssertEqual(r.category, "Dining")          // the display fix
        XCTAssertEqual(r.source, .deterministic)
        XCTAssertEqual(CategoryMapping.canonical("Dining out", lookup: [:]), "Dining")
    }

    func testExplicitCanonicalValue() {
        let r = CategoryMapping.resolve(expenseCategory: "Dining", lookup: [:])
        XCTAssertEqual(r.category, "Dining")
        XCTAssertEqual(r.source, .explicit)
    }

    func testInspectorString() {
        let r = CategoryMapping.resolve(expenseCategory: "Dining out", lookup: [:])
        XCTAssertEqual(r.inspectorString, "Dining out = Dining")  // "=" = deterministic
    }

    func testInspectorHumanizesPlaidRaw() {
        // The raw side is cleaned: SCREAMING_SNAKE Plaid → Title Case (Splitwise labels stay as-is above).
        let r = CategoryMapping.resolve(for: txn("FOOD_AND_DRINK_GROCERIES"), lookup: [:])
        XCTAssertEqual(r.inspectorString, "Food And Drink Groceries = Groceries")
    }

    func testDisplayLabel() {
        XCTAssertEqual(PlaidCategory.displayLabel("GENERAL_SERVICES"), "General Services")
        XCTAssertEqual(PlaidCategory.displayLabel("INCOME"), "Income")
        XCTAssertEqual(PlaidCategory.displayLabel("Dining out"), "Dining out")   // Splitwise - untouched
        XCTAssertEqual(PlaidCategory.displayLabel("Gas/fuel"), "Gas/fuel")       // untouched
        XCTAssertEqual(PlaidCategory.displayLabel("TV/Phone/Internet"), "TV/Phone/Internet")
    }

    func testBadges() {
        XCTAssertEqual(CategoryOrigin.mappedByAI.badgeLabel, "AI")
        XCTAssertEqual(CategoryOrigin.aiRefined.badgeLabel, "AI")
        XCTAssertEqual(CategoryOrigin.deterministic.badgeLabel, "Auto")
        XCTAssertEqual(CategoryOrigin.override.badgeLabel, "You")
        XCTAssertFalse(CategoryOrigin.raw.isNotable)
        XCTAssertTrue(CategoryOrigin.mappedByAI.isNotable)
    }
}
