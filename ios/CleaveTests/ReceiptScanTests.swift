import XCTest
@testable import CleaveAPI

/// The scanned-receipt date is bounded to the last 60 days (else today) so a wrong-year AI extraction
/// doesn't slip a 2024 date into a fresh scan.
final class RecentReceiptDateTests: XCTestCase {
    private let cal = Calendar.current
    private lazy var now = cal.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))  // a fixed "today"
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: now)! }

    func testKeepsInWindowDate() {
        XCTAssertEqual(ExpensePrefill.recentReceiptDate(day(-10), now: now), day(-10))
    }

    func testKeepsWindowBoundary() {
        XCTAssertEqual(ExpensePrefill.recentReceiptDate(day(-60), now: now), day(-60))
    }

    func testFutureDateBecomesToday() {
        XCTAssertEqual(ExpensePrefill.recentReceiptDate(day(3), now: now), now)
    }

    func testTooOldBecomesToday() {
        XCTAssertEqual(ExpensePrefill.recentReceiptDate(day(-400), now: now), now)  // e.g. the 2024 case
        XCTAssertEqual(ExpensePrefill.recentReceiptDate(day(-61), now: now), now)
    }

    func testNilBecomesToday() {
        XCTAssertEqual(ExpensePrefill.recentReceiptDate(nil, now: now), now)
    }
}

/// Receipt categories are snapped to the user's list (case-insensitive), so a free-text AI guess like
/// "Beverages" can't leak an off-list category.
final class MatchCategoryTests: XCTestCase {
    private let cats = ["Dining", "Groceries", "Fuel"]

    func testExactMatchCaseInsensitive() {
        XCTAssertEqual(ExpensePrefill.matchCategory("dining", in: cats), "Dining")
        XCTAssertEqual(ExpensePrefill.matchCategory("  GROCERIES ", in: cats), "Groceries")
    }

    func testOffListReturnsNil() {
        XCTAssertNil(ExpensePrefill.matchCategory("Beverages", in: cats))
    }

    func testNilAndEmpty() {
        XCTAssertNil(ExpensePrefill.matchCategory(nil, in: cats))
        XCTAssertNil(ExpensePrefill.matchCategory("Dining", in: []))
        XCTAssertNil(ExpensePrefill.matchCategory("   ", in: cats))
    }
}

final class ReceiptHeuristicsTests: XCTestCase {
    func testTotalPrefersTotalLineOverSubtotal() {
        let text = "Store ABC\nSubtotal 10.00\nTax 2.34\nTotal 12.34"
        XCTAssertEqual(ReceiptHeuristics.parse(text).total, Decimal(string: "12.34"))
    }

    func testTotalFallsBackToLargestAmount() {
        let text = "Corner Shop\nItem A 3.00\nItem B 9.99"
        XCTAssertEqual(ReceiptHeuristics.parse(text).total, Decimal(string: "9.99"))
    }

    func testCommaThousandsSeparator() {
        XCTAssertEqual(ReceiptHeuristics.parse("Total 1,234.56").total, Decimal(string: "1234.56"))
    }

    func testMerchantIsFirstLine() {
        XCTAssertEqual(ReceiptHeuristics.parse("Trader Joe's\nfoo 1.00").merchant, "Trader Joe's")
    }

    func testDateDetected() {
        XCTAssertNotNil(ReceiptHeuristics.parse("Receipt\nDate 06/19/2026\nTotal 5.00").date)
    }
}

final class ExpensePrefillTests: XCTestCase {
    func testPrefillFromExtraction() async {
        let recent = Calendar.current.date(byAdding: .day, value: -3, to: Date())!  // in the 60-day window
        let extraction = ReceiptExtraction(
            merchant: "Cafe", date: Mapping.dateOnlyFormatter.string(from: recent), total: 12.5,
            items: [ExtractedItem(name: "Latte", quantity: 1, price: 5.5, category: "coffee")]
        )
        // Empty list short-circuits the on-device classifier (which the sim lacks); the snapping logic is
        // covered by MatchCategoryTests. So the expense + item categories resolve to nil here.
        let prefill = await ExpensePrefill.from(extraction, categories: [])
        XCTAssertEqual(prefill.details, "Cafe")
        XCTAssertEqual(prefill.amount, Decimal(string: "12.50"))
        XCTAssertTrue(Calendar.current.isDate(prefill.date, inSameDayAs: recent))
        XCTAssertEqual(prefill.items.count, 1)
        XCTAssertEqual(prefill.items.first?.price, Decimal(string: "5.50"))
        XCTAssertNil(prefill.category)              // no off-list category leaks
        XCTAssertNil(prefill.items.first?.category)
    }

    func testPrefillFromHeuristics() {
        let result = ReceiptHeuristics.Result(merchant: "Shop", date: nil, total: Decimal(string: "9.99"))
        let prefill = ExpensePrefill.from(result)
        XCTAssertEqual(prefill.details, "Shop")
        XCTAssertEqual(prefill.amount, Decimal(string: "9.99"))
        XCTAssertTrue(prefill.items.isEmpty)
    }
}
