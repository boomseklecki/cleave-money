import SwiftUI
import SwiftData

/// Every active expense across all groups, grouped into month sections, most recent first. Rows match
/// the group detail (stacked date, category icon, your share) with the group name in the subtitle.
struct AllExpensesView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Expense.date, order: .reverse)
    private var expenses: [Expense]
    @Query private var groups: [ExpenseGroup]
    @Query private var users: [User]

    @State private var brandModel = BrandModel()

    private var groupName: [UUID: String] {
        Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        // Build derived values ONCE per render, not inside the ForEach row. Reading `groupName`
        // (rebuilds a dict) or a `@Query` (`users`) per row makes tapping a row - which triggers the
        // ForEach update pass - freeze the list. (Same pitfall fixed earlier in TransactionsView.)
        let groupName = self.groupName
        let users = self.users
        let me = env.currentUser?.identifier
        return List {
            ForEach(expenseMonthGroups(expenses), id: \.id) { month in
                Section {
                    ForEach(month.expenses) { expense in
                        // Closure-based (not value-based): value-based links nested in the Splits
                        // NavigationStack drop the first tap (off-by-one push).
                        NavigationLink {
                            LazyView(ExpenseDetailView(expense: expense))
                        } label: {
                            ExpenseRow(expense: expense, users: users, meIdentifier: me,
                                       groupName: groupName[expense.groupId], brandModel: brandModel)
                        }
                    }
                } header: {
                    Text(month.label).textCase(nil)
                }
            }
        }
        .navigationTitle("All Expenses")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: expenses.map(\.id)) {
            await brandModel.resolve(merchantTexts: expenses.flatMap { e in
                [(text: e.note, category: e.category), (text: e.details, category: e.category)]
            })
        }
        .overlay {
            if expenses.isEmpty {
                ContentUnavailableView("No Expenses", systemImage: "list.bullet.rectangle",
                                       description: Text("Add an expense in a group."))
            }
        }
    }
}
