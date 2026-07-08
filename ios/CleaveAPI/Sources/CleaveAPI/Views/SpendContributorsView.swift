import SwiftUI
import SwiftData

/// Drill-through list behind a Goals/Trends total: the transactions, expenses, and expense items that make
/// up a category's spend, a month's total spend, or a month's cash flow. Each row pushes to the matching
/// `TransactionDetailView` / `ExpenseDetailView`.
struct SpendContributorsView: View {
    let title: String
    let start: Date
    let end: Date
    let scope: SpendContributors.Scope

    /// Single-month drill (Goals donut/top-6, Trends per-bar).
    init(title: String, month: Date, scope: SpendContributors.Scope) {
        self.init(title: title, from: month, to: month, scope: scope)
    }

    /// Range drill (All Categories with a period filter). `start`/`end` are inclusive month bounds.
    init(title: String, from start: Date, to end: Date, scope: SpendContributors.Scope) {
        self.title = title
        self.start = start
        self.end = end
        self.scope = scope
    }

    @Environment(AppEnvironment.self) private var env

    @Query private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var expenses: [Expense]
    @Query private var groups: [ExpenseGroup]
    @Query private var categoryMaps: [CategoryMap]

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var me: String? { env.currentUser?.identifier }

    private var rows: [SpendContributor] {
        SpendContributors.of(scope: scope, from: start, to: end, transactions: transactions,
                             accounts: accounts, expenses: expenses, groups: groups, lookup: lookup, me: me)
    }
    /// Signed total: spend totals for category/spending, net (inflows − outflows) for cash flow.
    private var total: Decimal { rows.reduce(0) { $0 + $1.amount } }

    var body: some View {
        List {
            Section {
                if rows.isEmpty {
                    Text("Nothing in this period.").foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { ContributorRow(row: $0) }
                }
            } footer: {
                if !rows.isEmpty { totalFooter }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var totalFooter: some View {
        TotalsFooter(metrics: [.custom(isCashFlow ? "Net" : "Total", signedCurrency(total))])
    }

    private var isCashFlow: Bool { scope == .cashFlow }
}

/// One contributor row: category icon, label, date, and a signed amount (green inflow / red outflow).
/// A closure-based `NavigationLink` so it pushes cleanly onto the host `NavigationStack`.
struct ContributorRow: View {
    let row: SpendContributor

    var body: some View {
        NavigationLink {
            // LazyView so the @Query-heavy detail isn't eagerly built for every row each render.
            switch row.source {
            case .transaction(let t): LazyView(TransactionDetailView(transaction: t))
            case .expense(let e): LazyView(ExpenseDetailView(expense: e))
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: categorySymbol(row.category))
                    .font(.title3).foregroundStyle(categoryColor(row.category)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).lineLimit(1)
                    Text(row.date.dateOnly())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(signedCurrency(row.amount))
                    .foregroundStyle(row.isInflow ? .green : .primary).monospacedDigit()
            }
        }
    }
}

/// "+$12.00" for an inflow (negative amount), "$12.00" for an outflow.
func signedCurrency(_ amount: Decimal, code: String = "USD") -> String {
    let magnitude = abs(amount).formatted(.currency(code: code))
    return amount < 0 ? "+\(magnitude)" : magnitude
}
