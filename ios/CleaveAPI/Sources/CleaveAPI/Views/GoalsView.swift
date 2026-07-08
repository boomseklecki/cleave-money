import SwiftUI
import SwiftData
import Charts

/// The Goals tab, modeled on Mint: a monthly spending donut, a budgets tracker (category spend
/// goals), savings goals, and a link to Trends. Figures derive from Plaid transactions/accounts plus
/// your owed share of expenses that aren't linked to a transaction (cash splits, Splitwise).
struct GoalsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query private var goals: [Goal]
    @Query private var accounts: [Account]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var expenses: [Expense]
    @Query private var groups: [ExpenseGroup]
    @Query private var groupMembers: [GroupMember]
    @Query private var categoryMaps: [CategoryMap]

    @State private var month: Date = SpendingAnalytics.monthStart(Date())
    @State private var showingNew = false
    @State private var errorText: String?
    @State private var selectedCategory: String?
    @State private var showingReorder = false
    @State private var horizontalSwiping = false
    /// Partner-shared goals + the partner accounts they may track (live-fetched, never cached). Shown
    /// read-only; a shared save goal's progress is computable only when its account is also shared.
    @State private var sharedGoals: [Components.Schemas.GoalResponse] = []
    @State private var sharedAccountBalances: [String: Decimal] = [:]
    /// Accepted partner connections (identifier → display name), for combined household budgets.
    @State private var partners: [String: String] = [:]
    @AppStorage("goalsOrder") private var goalsOrderRaw = GoalSection.serialize(GoalSection.allCases)

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var me: String? { env.currentUser?.identifier }
    private var spendGoals: [Goal] { goals.filter { $0.goalKind == .spend }.sorted { $0.name < $1.name } }
    private var saveGoals: [Goal] { goals.filter { $0.goalKind == .save }.sorted { $0.name < $1.name } }
    private var sharedSpendGoals: [Components.Schemas.GoalResponse] {
        sharedGoals.filter { $0.kind == "spend" }.sorted { $0.name < $1.name }
    }
    private var sharedSaveGoals: [Components.Schemas.GoalResponse] {
        sharedGoals.filter { $0.kind == "save" }.sorted { $0.name < $1.name }
    }
    private var accountsById: [UUID: Account] {
        Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var categorySpend: [CategorySpend] {
        SpendingAnalytics.byCategory(in: month, transactions: transactions, accounts: accounts,
                                     lookup: lookup, expenses: expenses, groups: groups, me: me)
    }
    private var monthTotal: Decimal { categorySpend.reduce(0) { $0 + $1.total } }

    // MARK: Combined household budgets (shared spend goals)

    private var partnerIds: Set<String> { Set(partners.keys) }
    /// Groups whose cached membership contains both the viewer and a partner - their expenses are "shared".
    private var sharedGroupIds: Set<UUID> {
        guard let me else { return [] }
        return HouseholdBudget.sharedGroupIds(viewer: me, partners: partnerIds,
                                              membersByGroup: HouseholdBudget.membership(groupMembers))
    }
    /// The viewer + each connected partner (for drill-through attribution).
    private var householdMembers: [HouseholdBudget.Member] {
        guard let me else { return [] }
        return [HouseholdBudget.Member(identifier: me, label: "You", isViewer: true)]
            + partners.map { HouseholdBudget.Member(identifier: $0.key, label: $0.value, isViewer: false) }
    }
    /// Combined household spend per category for the selected month - built once per render (not per row).
    private func householdSpend() -> [String: HouseholdBudget.Spend] {
        guard let me else { return [:] }
        return HouseholdBudget.combinedByCategory(month: month, expenses: expenses,
                                                  sharedGroupIds: sharedGroupIds, viewer: me, partners: partnerIds)
    }
    /// The single partner's display name when there's exactly one (drives the "· Name $Y" breakdown).
    private var soloPartnerName: String? { partners.count == 1 ? partners.first?.value : nil }

    var body: some View {
        NavigationStack {
            List {
                Section { monthSelector }   // pinned top - controls every section
                ForEach(GoalSection.parse(goalsOrderRaw)) { section in
                    goalSection(section)
                }
                Section {                   // pinned bottom
                    NavigationLink {
                        TrendsView()
                    } label: {
                        Label("Trends", systemImage: "chart.bar.xaxis")
                    }
                    NavigationLink {
                        SubscriptionsView()
                    } label: {
                        Label("Subscriptions", systemImage: "repeat")
                    }
                }
            }
            // Swipe left/right anywhere on the page to change month (in addition to the chevrons).
            // `simultaneous` so vertical scrolling + row taps still work; the horizontal-dominance check in
            // `MonthSwipe.step` keeps vertical scrolls from triggering it.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        if abs(value.translation.width) > 16,
                           abs(value.translation.width) > abs(value.translation.height) {
                            horizontalSwiping = true  // suppress the donut's drill-in for this gesture
                        }
                    }
                    .onEnded { value in
                        defer { horizontalSwiping = false }
                        guard let step = MonthSwipe.step(value.translation) else { return }
                        if step > 0, month >= SpendingAnalytics.monthStart(Date()) { return }  // no future
                        shift(by: step)
                    }
            )
            .navigationTitle("Goals")
            .navigationDestination(for: Goal.self) { GoalDetailView(goal: $0) }
            .navigationDestination(item: $selectedCategory) { category in
                SpendContributorsView(title: category, month: month, scope: .category(category))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Reorder Sections", systemImage: "arrow.up.arrow.down") {
                            showingReorder = true
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNew = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingReorder) { CustomizeGoalsView() }
            .sheet(isPresented: $showingNew) { GoalEditView() }
            .refreshable {
                await env.smartRefresh(source: .bank,
                                       freshness: accounts.map(\.updatedAt).max(),
                                       context: context, reconcile: reconcileGoals)
            }
            .task { await reload() }
            .errorAlert($errorText)
        }
    }

    /// One reorderable Goals section. Order is user-controlled (Reorder Sections); the month selector and
    /// Trends link stay pinned in `body`.
    @ViewBuilder
    private func goalSection(_ section: GoalSection) -> some View {
        switch section {
        case .spending:
            Section {
                SpendingDonut(slices: categorySpend, total: monthTotal) {
                    if !horizontalSwiping { selectedCategory = $0 }  // don't drill in mid-swipe
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                if categorySpend.isEmpty {
                    Text("No spending this month yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(categorySpend.prefix(6)) { slice in
                        NavigationLink {
                            SpendContributorsView(title: slice.category, month: month,
                                                  scope: .category(slice.category))
                        } label: {
                            CategorySpendRow(slice: slice)
                        }
                    }
                    NavigationLink {
                        AllCategoriesView(month: month)
                    } label: {
                        Label("All Categories", systemImage: "list.bullet").font(.caption)
                    }
                }
            }
        case .budgets:
            // Combined spend per category, built once per render (not per row) - see [[swiftui-derived-dict-per-row]].
            let household = householdSpend()
            let ownSharedCategories = Set(spendGoals.filter { $0.shared }.compactMap { $0.category })
            Section("Budgets") {
                // Personal (non-shared) budgets - your spend only.
                ForEach(spendGoals.filter { !$0.shared }) { goal in
                    NavigationLink(value: goal) {
                        BudgetRow(goal: goal, spent: GoalProgress.spent(
                            for: goal.category ?? "", in: month, transactions: transactions,
                            accounts: accounts, lookup: lookup, expenses: expenses, me: me))
                    }
                }
                // Your shared budgets → combined household, navigable to the goal detail.
                ForEach(spendGoals.filter { $0.shared }) { goal in
                    NavigationLink(value: goal) {
                        HouseholdBudgetRow(
                            name: goal.name, category: goal.category, target: goal.targetAmount,
                            currency: goal.currency, spend: household[goal.category ?? ""] ?? .init(),
                            partnerName: soloPartnerName, sharedByLabel: nil)
                    }
                }
                // A partner's shared budget (category not already covered by one you own) → drill to contributors.
                ForEach(sharedSpendGoals.filter { !ownSharedCategories.contains($0.category ?? "") }, id: \.id) { goal in
                    NavigationLink {
                        HouseholdContributorsView(title: goal.name, category: goal.category ?? "",
                                                  month: month, partners: partners)
                    } label: {
                        HouseholdBudgetRow(
                            name: goal.name, category: goal.category,
                            target: (try? Mapping.decimal(goal.target_amount, field: "target")) ?? 0,
                            currency: goal.currency, spend: household[goal.category ?? ""] ?? .init(),
                            partnerName: goal.shared_by, sharedByLabel: goal.shared_by)
                    }
                }
                if spendGoals.isEmpty && sharedSpendGoals.isEmpty {
                    Text("Add a budget to track a category's monthly spend.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .savings:
            Section("Savings Goals") {
                ForEach(saveGoals) { goal in
                    NavigationLink(value: goal) {
                        SaveRow(goal: goal, account: goal.accountId.flatMap { accountsById[$0] })
                    }
                }
                ForEach(sharedSaveGoals, id: \.id) { goal in
                    SharedGoalRow(goal: goal, currentBalance: goal.account_id.flatMap { sharedAccountBalances[$0] })
                }
                if saveGoals.isEmpty && sharedSaveGoals.isEmpty {
                    Text("Set a goal to grow an account's balance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var monthSelector: some View {
        HStack {
            Button { shift(by: -1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
            Spacer()
            Button { shift(by: 1) } label: { Image(systemName: "chevron.right") }
                .disabled(month >= SpendingAnalytics.monthStart(Date()))
        }
        .buttonStyle(.borderless)
    }

    private func shift(by months: Int) {
        let cal = Calendar.current
        if let next = cal.date(byAdding: .month, value: months, to: month) {
            month = SpendingAnalytics.monthStart(next)
        }
    }

    private func reload() async {  // on appear: reconcile only
        do { try await reconcileGoals() } catch { errorText = errorMessage(error) }
    }

    private func reconcileGoals() async throws {
        try await env.accounts(context).refreshAccounts()
        // Pull a generous window so the donut/budgets and Trends charts have history.
        let since = Calendar.current.date(byAdding: .month, value: -6, to: Date())
        try await env.accounts(context).refreshTransactions(since: since, limit: 500)
        try await env.accounts(context).reapStalePending()  // clear pending rows Plaid dropped after posting
        try await env.goals(context).refresh()
        // Partner-shared goals (read-only) + the partner accounts that back any shared save goal, so its
        // progress can be shown. Best-effort: a failure here leaves the prior shared lists untouched.
        sharedGoals = (try? await env.goals(context).sharedInGoals()) ?? sharedGoals
        // Accepted partners drive the combined household budgets (their owed share of shared-group expenses).
        if let conns = try? await env.connections.list() {
            partners = Dictionary(conns.filter { $0.status == "accepted" }
                .map { ($0.other_identifier, $0.other_display_name) }, uniquingKeysWith: { first, _ in first })
        }
        if let shared = try? await env.accounts(context).sharedInAccounts() {
            sharedAccountBalances = Dictionary(
                shared.compactMap { acct in
                    (try? Mapping.decimal(acct.balance, field: "Account.balance")).map { (acct.id, $0) }
                },
                uniquingKeysWith: { first, _ in first })
        }
    }
}

/// A read-only Goals row for a partner's shared goal (budget or savings). No drill-in, no live spend; a
/// savings goal shows progress when its account is also shared (`currentBalance`), else just the target.
struct SharedGoalRow: View {
    let goal: Components.Schemas.GoalResponse
    let currentBalance: Decimal?

    private var target: Decimal { (try? Mapping.decimal(goal.target_amount, field: "target")) ?? 0 }
    private var isSave: Bool { goal.kind == "save" }
    private var fraction: Double? {
        guard isSave, let currentBalance, let type = goal.save_target_type.flatMap(SaveTargetType.init(rawValue:))
        else { return nil }
        let starting = (try? Mapping.optionalDecimal(goal.starting_balance, field: "start")) ?? 0
        return GoalProgress.saveFraction(current: currentBalance, starting: starting ?? 0,
                                         target: target, type: type)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isSave ? "banknote" : categorySymbol(goal.category))
                    .foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(goal.name)
                    Text("Shared by \(goal.shared_by ?? "partner")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let fraction {
                    Text("\(Int(fraction * 100))%").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(target.formatted(.currency(code: goal.currency)))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let fraction { ProgressView(value: fraction).tint(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

/// A donut of spend by category with the month total in the center. Tapping a slice reports its category.
struct SpendingDonut: View {
    let slices: [CategorySpend]
    let total: Decimal
    var caption: String = "Spent this month"
    var onSelect: (String) -> Void

    @State private var selectedAngle: Double?

    var body: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Spend", NSDecimalNumber(decimal: slice.total).doubleValue),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(categoryColor(slice.category))
        }
        .chartAngleSelection(value: $selectedAngle)
        .chartLegend(.hidden)
        .frame(height: 220)
        .overlay {
            VStack(spacing: 2) {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
                Text(total.formatted(.currency(code: "USD"))).font(.title2.bold()).monospacedDigit()
            }
            .allowsHitTesting(false)  // let taps reach the slices behind the center label
        }
        .onChange(of: selectedAngle) { _, angle in
            guard let angle, let category = category(at: angle) else { return }
            selectedAngle = nil  // reset so re-tapping the same slice fires again
            onSelect(category)
        }
    }

    /// The category whose cumulative spend wedge contains `angle` (plotted in `slices` order).
    private func category(at angle: Double) -> String? {
        var cumulative = 0.0
        for slice in slices {
            cumulative += NSDecimalNumber(decimal: slice.total).doubleValue
            if angle <= cumulative { return slice.category }
        }
        return slices.last?.category
    }
}

/// A category row: color dot, name, and spend total. Shared by the Goals donut list and All Categories.
struct CategorySpendRow: View {
    let slice: CategorySpend

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(categoryColor(slice.category)).frame(width: 10, height: 10)
            Text(slice.category)
            Spacer()
            Text(slice.total.formatted(.currency(code: "USD")))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
    }
}

/// A Mint-style budget row: category, a status-colored progress bar, "$spent of $budget", "$X left/over".
struct BudgetRow: View {
    let goal: Goal
    let spent: Decimal

    private var status: BudgetStatus { GoalProgress.budgetStatus(spent: spent, target: goal.targetAmount) }
    private var color: Color {
        switch status { case .under: return .green; case .nearing: return .orange; case .over: return .red }
    }
    private var remaining: Decimal { goal.targetAmount - spent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: categorySymbol(goal.category)).foregroundStyle(color).frame(width: 22)
                Text(goal.name)
                Spacer()
                Text(remaining >= 0
                     ? "\(remaining.formatted(.currency(code: "USD"))) left"
                     : "\((-remaining).formatted(.currency(code: "USD"))) over")
                    .font(.subheadline).foregroundStyle(color).monospacedDigit()
            }
            ProgressView(value: GoalProgress.budgetFraction(spent: spent, target: goal.targetAmount))
                .tint(color)
            Text("\(spent.formatted(.currency(code: "USD"))) of \(goal.targetAmount.formatted(.currency(code: "USD")))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

/// A combined household-budget row: one limit, both partners' shared-group spend toward it, with a status
/// bar and a "You $X · Partner $Y" breakdown. Used for shared spend goals (yours or a partner's).
struct HouseholdBudgetRow: View {
    let name: String
    let category: String?
    let target: Decimal
    let currency: String
    let spend: HouseholdBudget.Spend
    /// The partner's display name for the breakdown (nil → "Partner" when there are several).
    var partnerName: String? = nil
    /// "Shared by ..." for a partner-owned budget; nil = you own it (badge reads "Shared").
    var sharedByLabel: String? = nil

    private var combined: Decimal { spend.combined }
    private var status: BudgetStatus { GoalProgress.budgetStatus(spent: combined, target: target) }
    private var color: Color {
        switch status { case .under: return .green; case .nearing: return .orange; case .over: return .red }
    }
    private var remaining: Decimal { target - combined }
    private var breakdown: String {
        "You \(spend.mine.formatted(.currency(code: currency))) · "
            + "\(partnerName ?? "Partner") \(spend.partnerTotal.formatted(.currency(code: currency)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: categorySymbol(category)).foregroundStyle(color).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    Label(sharedByLabel.map { "Shared by \($0)" } ?? "Shared", systemImage: "person.2")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(remaining >= 0
                     ? "\(remaining.formatted(.currency(code: currency))) left"
                     : "\((-remaining).formatted(.currency(code: currency))) over")
                    .font(.subheadline).foregroundStyle(color).monospacedDigit()
            }
            ProgressView(value: GoalProgress.budgetFraction(spent: combined, target: target)).tint(color)
            HStack {
                Text("\(combined.formatted(.currency(code: currency))) of \(target.formatted(.currency(code: currency)))")
                Spacer()
                Text(breakdown)
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

/// A savings-goal row: account name, progress to target, "$current of $target".
struct SaveRow: View {
    let goal: Goal
    let account: Account?

    private var current: Decimal { account?.balance ?? 0 }
    private var fraction: Double {
        guard let type = goal.saveTarget else { return 0 }
        return GoalProgress.saveFraction(current: current, starting: goal.startingBalance ?? 0,
                                         target: goal.targetAmount, type: type)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "banknote").foregroundStyle(.green).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(goal.name)
                    if let account { Text(account.name).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text("\(Int(fraction * 100))%").font(.subheadline).foregroundStyle(.green).monospacedDigit()
            }
            ProgressView(value: fraction).tint(.green)
            Text("\(current.formatted(.currency(code: "USD"))) of \(goal.targetAmount.formatted(.currency(code: "USD")))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}
