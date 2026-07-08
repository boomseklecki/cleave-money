import Foundation

/// A fixed set of UI items the user can reorder (main tabs, Goals-page sections, ...). The order is stored as a
/// comma-joined `rawValue` string and synced via the preferences blob. `parse` tolerates a stored order
/// that's missing/has extra ids, so it always returns every case exactly once.
protocol ReorderableSection: RawRepresentable, CaseIterable, Identifiable, Hashable where RawValue == String {}

extension ReorderableSection {
    var id: String { rawValue }

    /// Parse a stored comma-joined order: keep valid ids in order, append any missing cases (forward-compat),
    /// and drop duplicates.
    static func parse(_ raw: String) -> [Self] {
        var order = raw.split(separator: ",").compactMap { Self(rawValue: String($0)) }
        for item in allCases where !order.contains(item) { order.append(item) }
        var seen = Set<Self>()
        return order.filter { seen.insert($0).inserted }
    }

    static func serialize(_ order: [Self]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }
}
