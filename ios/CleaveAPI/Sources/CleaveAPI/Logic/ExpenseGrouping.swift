import Foundation

/// Groups date-descending items into month buckets with a "June 2026" label, newest month first, preserving
/// order within each month. Generic over any row via a `date` accessor - shared by the Expenses lists and the
/// Transactions list.
func monthGroups<T>(_ items: [T], date: (T) -> Date) -> [(id: String, label: String, items: [T])] {
    let calendar = Calendar.current
    let buckets = Dictionary(grouping: items) {
        calendar.dateComponents([.year, .month], from: date($0))
    }
    return buckets.keys
        .sorted { (calendar.date(from: $0) ?? .distantPast) > (calendar.date(from: $1) ?? .distantPast) }
        .map { key in
            let date = calendar.date(from: key) ?? .now
            return ("\(key.year ?? 0)-\(key.month ?? 0)",
                    date.formatted(.dateTime.month(.wide).year()),
                    buckets[key] ?? [])
        }
}

/// Month buckets for expenses (newest month first). Shared by the group detail and All Expenses lists.
func expenseMonthGroups(_ expenses: [Expense]) -> [(id: String, label: String, expenses: [Expense])] {
    monthGroups(expenses, date: \.date).map { ($0.id, $0.label, $0.items) }
}
