import SwiftUI
import SwiftData

/// Manage manual subscription rules - merchants you've force-included or excluded from detection. Swipe a
/// rule away to revert that merchant to automatic. Reached from Subscriptions → toolbar.
struct SubscriptionRulesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \SubscriptionRule.displayName) private var rules: [SubscriptionRule]

    private var included: [SubscriptionRule] { rules.filter(\.isSubscription) }
    private var excluded: [SubscriptionRule] { rules.filter { !$0.isSubscription } }

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView("No Rules", systemImage: "slider.horizontal.3",
                    description: Text("Mark a charge as a subscription (or not) and it'll appear here."))
            }
            if !included.isEmpty {
                Section("Marked as Subscription") {
                    ForEach(included) { ruleRow($0) }.onDelete { delete(included, $0) }
                }
            }
            if !excluded.isEmpty {
                Section("Excluded") {
                    ForEach(excluded) { ruleRow($0) }.onDelete { delete(excluded, $0) }
                }
            }
        }
        .navigationTitle("Subscription Rules")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func ruleRow(_ rule: SubscriptionRule) -> some View {
        HStack {
            Text(rule.displayName)
            Spacer()
            Text("~\(rule.amount.formatted(.currency(code: "USD")))")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func delete(_ list: [SubscriptionRule], _ offsets: IndexSet) {
        for index in offsets { context.delete(list[index]) }
        try? context.save()
        env.pushSuggestionsSync(context)
    }
}
