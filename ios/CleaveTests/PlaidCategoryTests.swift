import XCTest
@testable import CleaveAPI

/// The deterministic Plaid taxonomy → canonical mapping (mirrored server-side; `test_category_builtin.py`
/// pins the parity dict - this is the iOS half) plus the humanization helpers.
final class PlaidCategoryTests: XCTestCase {
    func testCanonicalDetailedOverrideBeatsPrimary() {
        XCTAssertEqual(PlaidCategory.canonical("FOOD_AND_DRINK_GROCERIES"), "Groceries")   // detailed override
        XCTAssertEqual(PlaidCategory.canonical("FOOD_AND_DRINK_BEER_WINE_AND_LIQUOR"), "Alcohol")
        XCTAssertEqual(PlaidCategory.canonical("TRANSPORTATION_GAS"), "Fuel")
        XCTAssertEqual(PlaidCategory.canonical("RENT_AND_UTILITIES_RENT"), "Rent")
    }

    func testCanonicalPrimaryPrefixMatch() {
        XCTAssertEqual(PlaidCategory.canonical("FOOD_AND_DRINK"), "Dining")
        XCTAssertEqual(PlaidCategory.canonical("FOOD_AND_DRINK_FAST_FOOD"), "Dining")   // detailed → primary
        XCTAssertEqual(PlaidCategory.canonical("INCOME"), "Income")
        XCTAssertEqual(PlaidCategory.canonical("GENERAL_SERVICES"), "Other")
    }

    func testCanonicalUnknownIsNil() {
        XCTAssertNil(PlaidCategory.canonical("NOT_A_PLAID_CATEGORY"))
        XCTAssertNil(PlaidCategory.canonical(""))
    }

    func testHumanized() {
        XCTAssertEqual(PlaidCategory.humanized("PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS"),
                       "Personal Care Gyms And Fitness Centers")
        XCTAssertEqual(PlaidCategory.humanized("FOOD_AND_DRINK"), "Food And Drink")
    }

    func testDisplayLabel() {
        XCTAssertEqual(PlaidCategory.displayLabel("GENERAL_SERVICES"), "General Services")  // Plaid format
        XCTAssertEqual(PlaidCategory.displayLabel("INCOME"), "Income")
        XCTAssertEqual(PlaidCategory.displayLabel("Dining out"), "Dining out")              // readable → passthrough
        XCTAssertEqual(PlaidCategory.displayLabel("TV/Phone/Internet"), "TV/Phone/Internet")
    }
}
