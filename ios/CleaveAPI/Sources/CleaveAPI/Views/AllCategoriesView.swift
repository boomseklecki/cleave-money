import SwiftUI
import SwiftData

/// The full per-category spend breakdown for a selectable period (every category, not just the donut's top 6),
/// led by the spend donut + period total. Each row - and each donut slice - drills into that category's
/// contributing transactions/expenses over the same window. Pushed from the Goals donut section; opens on the
/// month it came from, then a period menu widens the window (Last N months / YTD / a prior year).
struct AllCategoriesView: View {
    /// The anchor month (the Goals page's selected month); the default `.month` period shows just this month.
    let month: Date

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var expenses: [Expense]
    @Query private var groups: [ExpenseGroup]
    @Query private var categoryMaps: [CategoryMap]

    @AppStorage("allCategories.period") private var periodRaw = SpendPeriod.month.rawValue
    @State private var selectedCategory: String?

    private var period: SpendPeriod { SpendPeriod(rawValue: periodRaw) ?? .month }
    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var me: String? { env.currentUser?.identifier }

    var body: some View {
        let window = period.resolve(anchor: month)
        let slices = SpendingAnalytics.byCategory(
            from: window.start, to: window.end, transactions: transactions, accounts: accounts,
            lookup: lookup, expenses: expenses, groups: groups, me: me)
        let total = slices.reduce(Decimal(0)) { $0 + $1.total }

        return List {
            Section {
                SpendingDonut(slices: slices, total: total, caption: window.label) { selectedCategory = $0 }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            Section {
                ForEach(slices) { slice in
                    NavigationLink {
                        SpendContributorsView(title: slice.category, from: window.start, to: window.end,
                                              scope: .category(slice.category))
                    } label: {
                        CategorySpendRow(slice: slice)
                    }
                }
                if slices.isEmpty {
                    Text("No spending in this period.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("All Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Period", selection: $periodRaw) {
                        ForEach(SpendPeriod.allCases) { p in
                            Text(p.resolve(anchor: month).label).tag(p.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "calendar")
                }
            }
        }
        .navigationDestination(item: $selectedCategory) { category in
            SpendContributorsView(title: category, from: window.start, to: window.end,
                                  scope: .category(category))
        }
    }
}
