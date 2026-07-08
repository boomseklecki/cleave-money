import SwiftUI

/// A consistent "Updated <relative>" caption (e.g. "Updated 2 hours ago"), used wherever a header or list row
/// shows its last-synced time. Hidden when the date is nil. Matches the account-summary header phrasing.
/// Detail screens that use `LabeledContent` rows show the same value via `Date.relativeUpdated` instead.
struct UpdatedAgo: View {
    let date: Date?

    var body: some View {
        if let date {
            Text("Updated \(date.relativeUpdated)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension Date {
    /// The shared relative phrasing (e.g. "2 hours ago") for inline "Updated <x>" captions.
    var relativeUpdated: String { formatted(.relative(presentation: .named)) }

    /// Sentence-cased for standalone value displays like a `LabeledContent("Updated", ...)` row, where the
    /// value stands on its own: "Last week", "2 days ago".
    var relativeUpdatedCapitalized: String {
        let s = relativeUpdated
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}
