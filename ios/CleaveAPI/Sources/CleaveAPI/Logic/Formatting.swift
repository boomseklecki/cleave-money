import Foundation

/// Shared display formatting so the currency/date styles aren't re-spelled across views.
extension Decimal {
    /// The amount as localized currency in `code` (e.g. "$12.34"). One definition for what was several per-view
    /// `currency(_:)` helpers + scattered `.formatted(.currency(code:))` calls.
    func currency(_ code: String) -> String { formatted(.currency(code: code)) }
}

extension Date {
    /// Calendar date only, abbreviated (e.g. "Jun 3, 2026") - the app's standard row/detail date style.
    func dateOnly() -> String { formatted(date: .abbreviated, time: .omitted) }
}
