import SwiftUI

/// The shared Merchant + Amount match-filter controls for the "Find Related" screens (transactions and
/// expenses), combined into one "Filters" section. Bound to the caller's `relatedTransactions.matchStrictness`
/// / `.amountMatch` AppStorage so the preference is consistent across both.
struct RelatedMatchFilters: View {
    @Binding var strictnessRaw: String
    @Binding var amountRaw: String
    /// Whether the seed has an amount (the Amount axis is hidden without one).
    let showAmount: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Merchant").font(.caption).foregroundStyle(.secondary)
                Picker("Merchant", selection: $strictnessRaw) {
                    ForEach(RelatedTransactions.MatchStrictness.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if showAmount {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Amount").font(.caption).foregroundStyle(.secondary)
                    Picker("Amount", selection: $amountRaw) {
                        ForEach(RelatedTransactions.AmountMatch.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        } header: {
            Text("Filters")
        } footer: {
            Text("How closely the merchant must match (Fuzzy to Exact)"
                 + (showAmount ? ", and optionally require a close or equal amount." : "."))
        }
    }
}
