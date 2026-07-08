import XCTest
@testable import CleaveAPI

/// Time-window resolution for the Goals sub-pages. Deterministic given `now`; assert the month count and the
/// numeric labels (the wide-month label is locale-fragile, so it's not asserted).
final class SpendPeriodTests: XCTestCase {
    private let cal = SpendingAnalytics.spendCalendar
    private func date(_ y: Int, _ m: Int, _ d: Int = 15) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testRollingWindows() {
        let anchor = date(2026, 1), now = date(2026, 3)
        XCTAssertEqual(SpendPeriod.last3.resolve(anchor: anchor, now: now).months, 3)
        XCTAssertEqual(SpendPeriod.last6.resolve(anchor: anchor, now: now).months, 6)
        XCTAssertEqual(SpendPeriod.last12.resolve(anchor: anchor, now: now).months, 12)
    }

    func testMonthIsSingleAnchorMonth() {
        let r = SpendPeriod.month.resolve(anchor: date(2026, 1), now: date(2026, 3))
        XCTAssertEqual(r.months, 1)
        XCTAssertEqual(r.start, r.end)
        XCTAssertEqual(r.start, SpendingAnalytics.monthStart(date(2026, 1), cal))
    }

    func testYearToDate() {
        let ytd = SpendPeriod.yearToDate.resolve(anchor: date(2026, 1), now: date(2026, 3))
        XCTAssertEqual(ytd.months, 3)                 // Jan → Mar
        XCTAssertEqual(ytd.label, "2026 YTD")
        // In January, YTD is a single month.
        XCTAssertEqual(SpendPeriod.yearToDate.resolve(anchor: date(2026, 1), now: date(2026, 1)).months, 1)
    }

    func testPreviousYearIsFullPriorCalendarYear() {
        let prev = SpendPeriod.previousYear.resolve(anchor: date(2026, 1), now: date(2026, 3))
        XCTAssertEqual(prev.months, 12)
        XCTAssertEqual(prev.label, "2025")
        XCTAssertEqual(prev.start, SpendingAnalytics.monthStart(date(2025, 1), cal))
        XCTAssertEqual(prev.end, SpendingAnalytics.monthStart(date(2025, 12), cal))
    }
}
