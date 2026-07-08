import XCTest
import SwiftUI
@testable import CleaveAPI

final class TransactionMappingTests: XCTestCase {
    func testMainTabParseIsRobust() {
        // A stored order is preserved, with newer tabs (inbox) forward-filled for existing users.
        XCTAssertEqual(MainTab.parse("goals,accounts,splits"), [.goals, .accounts, .splits, .inbox])
        // Missing tabs are appended in canonical order; invalid ids and dupes dropped.
        XCTAssertEqual(MainTab.parse("goals,bogus,goals"), [.goals, .accounts, .splits, .inbox])
        // Empty falls back to the full canonical order.
        XCTAssertEqual(MainTab.parse(""), MainTab.allCases)
        // Round-trips through serialize (newer tabs still forward-filled).
        XCTAssertEqual(MainTab.parse(MainTab.serialize([.splits, .goals, .accounts])),
                       [.splits, .goals, .accounts, .inbox])
    }

    func testGoalSectionParseIsRobust() {
        XCTAssertEqual(GoalSection.parse("budgets,savings,spending"), [.budgets, .savings, .spending])
        XCTAssertEqual(GoalSection.parse("budgets,bogus,budgets"), [.budgets, .spending, .savings])
        XCTAssertEqual(GoalSection.parse(""), GoalSection.allCases)
    }

    func testOrderSnapshotRoundTrip() throws {
        let snap = OrderSnapshot(order: ["goals", "accounts", "splits"])
        let decoded = try JSONDecoder().decode(OrderSnapshot.self, from: try JSONEncoder().encode(snap))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.order, ["goals", "accounts", "splits"])
    }

    func testMonthSwipeStep() {
        XCTAssertEqual(MonthSwipe.step(CGSize(width: -90, height: 10)), 1)    // swipe left → next month
        XCTAssertEqual(MonthSwipe.step(CGSize(width: 90, height: -10)), -1)   // swipe right → previous
        XCTAssertNil(MonthSwipe.step(CGSize(width: 30, height: 5)))           // too small
        XCTAssertNil(MonthSwipe.step(CGSize(width: 70, height: 90)))          // too vertical
    }

    func testAppearanceModeColorScheme() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
    }

    func testTransactionCreateReverseMapper() {
        let draft = TransactionDraft(
            details: "Coffee", amount: Decimal(string: "4.50")!,
            date: Mapping.dateOnlyFormatter.date(from: "2026-06-19")!, category: "coffee"
        )
        let create = Mapping.transactionCreate(draft)
        XCTAssertEqual(create.amount, "4.5")  // Decimal("4.50") normalizes to 4.5; server accepts it
        XCTAssertEqual(create.description, "Coffee")
        XCTAssertEqual(create.date, "2026-06-19")
        XCTAssertEqual(create.category, "coffee")
        XCTAssertNil(create.account_id)
    }

    func testMonthGroupsBucketsNewestFirst() {
        let cal = Calendar.current
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d))!
        }
        // Two June dates and one May date, fed in mixed order.
        let dates = [day(2026, 6, 20), day(2026, 5, 2), day(2026, 6, 5)]
        let groups = monthGroups(dates, date: { $0 })
        XCTAssertEqual(groups.map(\.id), ["2026-6", "2026-5"])           // newest month first
        XCTAssertEqual(groups.map(\.label), ["June 2026", "May 2026"])
        XCTAssertEqual(groups.first?.items.count, 2)                      // both June dates bucketed together
        XCTAssertEqual(groups.last?.items, [day(2026, 5, 2)])
    }

    func testExpensePrefillFromTransaction() {
        let id = UUID()
        let transaction = Transaction(
            id: id, source: .manual, details: "Lunch", amount: Decimal(string: "20.00")!,
            currency: "USD", date: Mapping.dateOnlyFormatter.date(from: "2026-06-18")!,
            category: "food", createdAt: Date(), updatedAt: Date()
        )
        let prefill = ExpensePrefill.from(transaction)
        XCTAssertEqual(prefill.details, "Lunch")
        XCTAssertEqual(prefill.amount, Decimal(string: "20.00"))
        XCTAssertEqual(prefill.category, "food")
        XCTAssertEqual(prefill.transactionId, id)
        XCTAssertTrue(prefill.items.isEmpty)
    }
}
