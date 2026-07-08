import XCTest
@testable import CleaveAPI

/// The Splitwise taxonomy → canonical mapping (iOS side; backend parity is pinned in test_category_builtin.py).
final class SplitwiseCategoryTests: XCTestCase {
    func testKnownCategoriesMap() {
        XCTAssertEqual(SplitwiseCategory.canonical("Dining out"), "Dining")
        XCTAssertEqual(SplitwiseCategory.canonical("Gas/fuel"), "Fuel")
        XCTAssertEqual(SplitwiseCategory.canonical("Groceries"), "Groceries")
        XCTAssertEqual(SplitwiseCategory.canonical("TV/Phone/Internet"), "Utilities")
        XCTAssertEqual(SplitwiseCategory.canonical("Medical expenses"), "Health")
    }

    func testUnknownIsNil() {
        XCTAssertNil(SplitwiseCategory.canonical("Not a splitwise category"))
        XCTAssertNil(SplitwiseCategory.canonical(""))
    }
}
