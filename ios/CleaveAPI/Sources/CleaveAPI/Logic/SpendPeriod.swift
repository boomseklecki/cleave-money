import Foundation

/// A selectable time window for the Goals sub-pages (All Categories, Trends). Everything downstream is
/// month-bucketed, so a period resolves to a contiguous, inclusive range of first-of-month dates.
enum SpendPeriod: String, CaseIterable, Identifiable {
    case month          // a single month (the page's anchor)
    case last3
    case last6
    case last12
    case yearToDate     // Jan of the current year → this month
    case previousYear   // the full prior calendar year

    var id: String { rawValue }

    /// The resolved window. `anchor` is the page's reference month (used by `.month`); `now` drives the
    /// rolling/calendar presets. Bounds are first-of-month and inclusive; `months` is the bar count for Trends.
    func resolve(anchor: Date, now: Date = .now) -> (start: Date, end: Date, label: String, months: Int) {
        let cal = SpendingAnalytics.spendCalendar
        let thisMonth = SpendingAnalytics.monthStart(now, cal)

        func back(_ n: Int) -> Date { cal.date(byAdding: .month, value: -n, to: thisMonth) ?? thisMonth }
        func months(_ start: Date, _ end: Date) -> Int {
            (cal.dateComponents([.month], from: start, to: end).month ?? 0) + 1
        }
        func make(_ start: Date, _ end: Date, _ label: String) -> (Date, Date, String, Int) {
            (start, end, label, months(start, end))
        }

        switch self {
        case .month:
            let m = SpendingAnalytics.monthStart(anchor, cal)
            return make(m, m, m.formatted(.dateTime.month(.wide).year()))
        case .last3:
            return make(back(2), thisMonth, "Last 3 months")
        case .last6:
            return make(back(5), thisMonth, "Last 6 months")
        case .last12:
            return make(back(11), thisMonth, "Last 12 months")
        case .yearToDate:
            let year = cal.component(.year, from: now)
            let jan = cal.date(from: DateComponents(year: year, month: 1)) ?? thisMonth
            return make(jan, thisMonth, "\(year) YTD")
        case .previousYear:
            let year = cal.component(.year, from: now) - 1
            let jan = cal.date(from: DateComponents(year: year, month: 1)) ?? thisMonth
            let dec = cal.date(from: DateComponents(year: year, month: 12)) ?? thisMonth
            return make(jan, dec, "\(year)")
        }
    }
}
