import SwiftUI
import SwiftData

/// Drill-through behind a combined household budget: the shared-group expenses (and items) in a category for
/// a month, each tagged with who incurred it ("You"/partner). Every row is a real cached group expense both
/// partners can open, so it pushes to the regular `ExpenseDetailView`.
struct HouseholdContributorsView: View {
    let title: String
    let category: String
    let start: Date
    let end: Date
    /// Accepted partners (identifier → display name), passed from the Goals screen.
    let partners: [String: String]

    init(title: String, category: String, month: Date, partners: [String: String]) {
        self.init(title: title, category: category, from: month, to: month, partners: partners)
    }

    init(title: String, category: String, from start: Date, to end: Date, partners: [String: String]) {
        self.title = title
        self.category = category
        self.start = start
        self.end = end
        self.partners = partners
    }

    @Environment(AppEnvironment.self) private var env
    @Query private var expenses: [Expense]
    @Query private var groupMembers: [GroupMember]

    private var me: String? { env.currentUser?.identifier }

    private var household: [HouseholdBudget.Member] {
        guard let me else { return [] }
        return [HouseholdBudget.Member(identifier: me, label: "You", isViewer: true)]
            + partners.map { HouseholdBudget.Member(identifier: $0.key, label: $0.value, isViewer: false) }
    }
    private var sharedGroupIds: Set<UUID> {
        guard let me else { return [] }
        return HouseholdBudget.sharedGroupIds(viewer: me, partners: Set(partners.keys),
                                              membersByGroup: HouseholdBudget.membership(groupMembers))
    }
    private var rows: [HouseholdBudget.Contributor] {
        HouseholdBudget.contributors(category: category, from: start, to: end, expenses: expenses,
                                     sharedGroupIds: sharedGroupIds, household: household)
    }
    private var total: Decimal { rows.reduce(0) { $0 + $1.amount } }

    var body: some View {
        List {
            Section {
                if rows.isEmpty {
                    Text("Nothing shared in this category yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { HouseholdContributorRow(row: $0, category: category) }
                }
            } footer: {
                if !rows.isEmpty {
                    HStack {
                        Text("Combined")
                        Spacer()
                        Text(total.formatted(.currency(code: "USD"))).monospacedDigit()
                    }
                    .font(.subheadline).fontWeight(.medium)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One household-contributor row: category icon, label, who ("You"/partner) + date, and the amount. Pushes
/// to the shared expense's `ExpenseDetailView` (both partners are group members).
struct HouseholdContributorRow: View {
    let row: HouseholdBudget.Contributor
    let category: String

    var body: some View {
        NavigationLink {
            LazyView(ExpenseDetailView(expense: row.expense))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: categorySymbol(category))
                    .font(.title3).foregroundStyle(categoryColor(category)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).lineLimit(1)
                    Text("\(row.who) · \(row.date.dateOnly())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.amount.formatted(.currency(code: "USD"))).monospacedDigit()
            }
        }
    }
}
