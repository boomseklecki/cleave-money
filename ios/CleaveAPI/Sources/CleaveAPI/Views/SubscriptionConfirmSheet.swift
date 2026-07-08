import SwiftUI

/// Confirmation before accepting a "Track" suggestion - a newly detected recurring charge with no rule yet.
/// Shows the merchant, cadence, and amount, plus what tracking does, so the user opts in deliberately.
/// `onConfirm` performs the accept (InboxView → inserts a SubscriptionRule).
struct SubscriptionConfirmSheet: View {
    let suggestion: Suggestion
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        AvatarView(url: nil, name: suggestion.title, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.headline)
                            Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                } footer: {
                    Text("Marks this merchant as a recurring subscription so it’s recognized in your "
                         + "subscriptions and spending.")
                }
            }
            .navigationTitle("Track Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(suggestion.acceptLabel) { onConfirm(); dismiss() }
                }
            }
        }
    }
}
