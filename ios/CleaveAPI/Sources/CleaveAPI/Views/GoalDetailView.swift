import SwiftUI
import SwiftData
import Charts

/// A goal's detail: for budgets, the month's standing + a category spend trend with the target line;
/// for savings, progress to target + the account's monthly net contributions.
struct GoalDetailView: View {
    let goal: Goal

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var accounts: [Account]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var expenses: [Expense]
    @Query private var groups: [ExpenseGroup]
    @Query private var groupMembers: [GroupMember]
    @Query private var categoryMaps: [CategoryMap]

    @State private var showingEdit = false
    @State private var confirmingDelete = false
    @State private var errorText: String?
    /// Accepted partners (identifier → display name), for a shared budget's combined household figures.
    @State private var partners: [String: String] = [:]

    private let months = 6
    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var me: String? { env.currentUser?.identifier }
    private var month: Date { SpendingAnalytics.monthStart(Date()) }
    private var account: Account? { goal.accountId.flatMap { id in accounts.first { $0.id == id } } }

    var body: some View {
        if goal.isDeleted {
            // Deleted from this screen - don't read the dangling SwiftData model (crashes); pop back.
            Color.clear.onAppear { dismiss() }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            if goal.goalKind == .spend { budgetContent } else { saveContent }

            Section {
                Button("Edit Goal", systemImage: "pencil") { showingEdit = true }
                Button("Delete Goal", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(goal.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEdit) { GoalEditView(editing: goal) }
        .confirmationDialog("Delete this goal?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        }
        .task { await loadPartners() }
        .errorAlert($errorText)
    }

    private func loadPartners() async {
        guard goal.shared, let conns = try? await env.connections.list() else { return }
        partners = Dictionary(conns.filter { $0.status == "accepted" }
            .map { ($0.other_identifier, $0.other_display_name) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Combined household (shared spend goals)

    private var partnerIds: Set<String> { Set(partners.keys) }
    private var household: [HouseholdBudget.Member] {
        guard let me else { return [] }
        return [HouseholdBudget.Member(identifier: me, label: "You", isViewer: true)]
            + partners.map { HouseholdBudget.Member(identifier: $0.key, label: $0.value, isViewer: false) }
    }
    private var sharedGroupIds: Set<UUID> {
        guard let me else { return [] }
        return HouseholdBudget.sharedGroupIds(viewer: me, partners: partnerIds,
                                              membersByGroup: HouseholdBudget.membership(groupMembers))
    }
    private var soloPartnerName: String? { partners.count == 1 ? partners.first?.value : nil }
    private func combined(_ month: Date) -> HouseholdBudget.Spend {
        guard let me else { return .init() }
        return HouseholdBudget.combined(category: goal.category ?? "", month: month, expenses: expenses,
                                        sharedGroupIds: sharedGroupIds, viewer: me, partners: partnerIds)
    }
    private var combinedThisMonth: HouseholdBudget.Spend { combined(month) }
    private var combinedMonthly: [MonthlyValue] {
        SpendingAnalytics.monthRange(months: months, ending: Date(), cal: .current)
            .map { MonthlyValue(month: $0, value: combined($0).combined) }
    }
    private var combinedContributors: [HouseholdBudget.Contributor] {
        HouseholdBudget.contributors(category: goal.category ?? "", from: month, to: month,
                                     expenses: expenses, sharedGroupIds: sharedGroupIds, household: household)
    }

    // MARK: Budget

    private var spentThisMonth: Decimal {
        GoalProgress.spent(for: goal.category ?? "", in: month, transactions: transactions,
                           accounts: accounts, lookup: lookup, expenses: expenses, me: me)
    }
    private var monthlyCategorySpend: [MonthlyValue] {
        SpendingAnalytics.monthRange(months: months, ending: Date(), cal: .current).map { m in
            MonthlyValue(month: m, value: GoalProgress.spent(
                for: goal.category ?? "", in: m, transactions: transactions,
                accounts: accounts, lookup: lookup, expenses: expenses, me: me))
        }
    }
    /// The transactions, expenses, and items feeding this month's budget standing - each navigable.
    private var thisMonthSpend: [SpendContributor] {
        SpendContributors.of(scope: .category(goal.category ?? ""), month: month, transactions: transactions,
                             accounts: accounts, expenses: expenses, groups: groups, lookup: lookup, me: me)
    }

    @ViewBuilder private var budgetContent: some View {
        Section {
            if goal.shared {
                HouseholdBudgetRow(name: goal.name, category: goal.category, target: goal.targetAmount,
                                   currency: goal.currency, spend: combinedThisMonth,
                                   partnerName: soloPartnerName, sharedByLabel: nil)
            } else {
                BudgetRow(goal: goal, spent: spentThisMonth)
            }
        }
        Section("Last \(months) Months") {
            Chart {
                ForEach(goal.shared ? combinedMonthly : monthlyCategorySpend) { point in
                    BarMark(
                        x: .value("Month", point.month, unit: .month),
                        y: .value("Spent", NSDecimalNumber(decimal: point.value).doubleValue)
                    )
                    .foregroundStyle(categoryColor(goal.category))
                    .cornerRadius(4)
                }
                RuleMark(y: .value("Budget", NSDecimalNumber(decimal: goal.targetAmount).doubleValue))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Budget").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow))
            } }
            .frame(height: 180)
        }
        Section("This Month") {
            if goal.shared {
                if combinedContributors.isEmpty {
                    Text("Nothing shared in this category yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(combinedContributors) {
                        HouseholdContributorRow(row: $0, category: goal.category ?? "")
                    }
                }
            } else if thisMonthSpend.isEmpty {
                Text("No spending in this category yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(thisMonthSpend) { ContributorRow(row: $0) }
            }
        }
    }

    // MARK: Savings

    private var monthlyContributions: [MonthlyValue] {
        let cal = Calendar.current
        var totals: [Date: Decimal] = [:]
        for t in transactions where t.accountId == goal.accountId {
            // Net contribution = inflow (amount<0) minus outflow (amount>0) for the account.
            totals[SpendingAnalytics.monthStart(t.date, cal), default: 0] -= t.amount
        }
        return SpendingAnalytics.monthRange(months: months, ending: Date(), cal: cal)
            .map { MonthlyValue(month: $0, value: totals[$0] ?? 0) }
    }

    @ViewBuilder private var saveContent: some View {
        Section {
            SaveRow(goal: goal, account: account)
            if let date = goal.startingDate, let start = goal.startingBalance {
                Text("Since \(date.dateOnly()): started at \(start.formatted(.currency(code: goal.currency)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Monthly Net Contribution") {
            Chart(monthlyContributions) { point in
                BarMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Net", NSDecimalNumber(decimal: point.value).doubleValue)
                )
                .foregroundStyle(point.value >= 0 ? Color.green : Color.red)
                .cornerRadius(4)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow))
            } }
            .frame(height: 180)
        }
        if let account {
            Section {
                NavigationLink {
                    TransactionsView(account: account)
                } label: {
                    Label("Account Transactions", systemImage: "list.bullet")
                }
            }
        }
    }

    private func delete() {
        Task {
            do { try await env.goals(context).delete(id: goal.id); dismiss() }
            catch { errorText = errorMessage(error) }
        }
    }
}
