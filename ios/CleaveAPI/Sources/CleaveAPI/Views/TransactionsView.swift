import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Cached transactions (date-desc). Add a manual transaction, or turn any transaction into an expense.
struct TransactionsView: View {
    let account: Account?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]
    @Query private var categoryMaps: [CategoryMap]
    @Query private var spendCategories: [SpendCategory]

    @State private var brandModel = BrandModel()
    @State private var showingManual = false
    @State private var scan = ReceiptScanModel()
    @State private var showingReceiptScanner = false
    @State private var receiptPhoto: PhotosPickerItem?
    @State private var errorText: String?
    @State private var search = ""
    /// When true, pending transactions get their own section at the top; when false they're interleaved
    /// with posted ones in date order (still styled as pending).
    @AppStorage("transactions.groupPending") private var groupPending = true

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }

    init(account: Account? = nil) {
        self.account = account
        if let accountId = account?.id {
            _transactions = Query(
                filter: #Predicate<Transaction> { $0.accountId == accountId },
                sort: \Transaction.date, order: .reverse
            )
        } else {
            _transactions = Query(sort: \Transaction.date, order: .reverse)
        }
    }

    var body: some View {
        // Build the raw→canonical map ONCE per render. Referencing the `lookup` computed property from
        // inside the row closure rebuilt this dictionary for every transaction - O(rows × maps) of
        // dictionary construction on the main thread, which froze long lists.
        let lookup = self.lookup
        // Filter by the search query ONCE per render (description or formatted amount), before the
        // pending/posted split - same derived-values-once discipline as the split below.
        let q = search.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? transactions : transactions.filter {
            $0.details.localizedCaseInsensitiveContains(q)
            || $0.amount.formatted(.currency(code: $0.currency)).localizedCaseInsensitiveContains(q)
        }
        // Split once per render (not inside the ForEach - building these per row is the derived-values
        // pitfall that froze long lists). The @Query is date-desc, so each group stays newest-first.
        let pending = shown.filter(\.pending)
        // Separate into Pending/Posted sections only when the user wants grouping and there's something
        // pending; otherwise show one date-ordered list (pending rows still styled with the pill).
        let separate = groupPending && !pending.isEmpty
        let posted = separate ? shown.filter { !$0.pending } : []
        return List {
            // Keep the List uniformly sectioned: a loose element before the row Sections makes SwiftUI
            // swallow the rows' tap/navigation (broke the account → transaction drill-through).
            if let account {
                Section { AccountSummaryHeader(account: account, transactions: transactions) }
            }
            if shown.isEmpty {
                Section {
                    ContentUnavailableView(
                        q.isEmpty ? "No Transactions" : "No Results",
                        systemImage: q.isEmpty ? "list.bullet.rectangle" : "magnifyingglass",
                        description: Text(!q.isEmpty
                            ? "No transactions match “\(q)”."
                            : account == nil
                                ? "Sync a linked bank or add one manually."
                                : "No transactions for this account yet.")
                    )
                }
            }
            if separate {
                Section("Pending") {
                    ForEach(pending) { transactionLink($0, lookup: lookup, isPending: true) }
                }
                // Posted rows get "Month Year" separators, matching the Expenses lists.
                ForEach(monthGroups(posted, date: \.date), id: \.id) { month in
                    Section {
                        ForEach(month.items) { transactionLink($0, lookup: lookup, isPending: false) }
                    } header: {
                        Text(month.label).textCase(nil)
                    }
                }
            } else {
                ForEach(monthGroups(shown, date: \.date), id: \.id) { month in
                    Section {
                        ForEach(month.items) { transactionLink($0, lookup: lookup, isPending: $0.pending) }
                    } header: {
                        Text(month.label).textCase(nil)
                    }
                }
            }
        }
        .navigationTitle(account?.displayLabel ?? "Transactions")
        .searchable(text: $search, prompt: "Search transactions")
        .toolbar {
            if account == nil {
                if !pending.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu { pendingToggle } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Blank Transaction", systemImage: "square.and.pencil") { showingManual = true }
                        Button("Scan Receipt", systemImage: "doc.viewfinder") { showingReceiptScanner = true }
                        PhotosPicker(selection: $receiptPhoto, matching: .images) {
                            Label("Receipt from Photo", systemImage: "photo")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            } else if let account {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !pending.isEmpty { Section("View") { pendingToggle } }
                        Section("Goals") {
                            Toggle("Include in spending", isOn: Binding(
                                get: { account.countsInSpending },
                                set: { setFlags(account, includeInSpending: $0) }))
                            Toggle("Include in cash flow", isOn: Binding(
                                get: { account.countsInCashFlow },
                                set: { setFlags(account, includeInCashFlow: $0) }))
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
        }
        .sheet(isPresented: $showingManual) { ManualTransactionView() }
        .receiptScanEntry(scan: scan, categories: spendCategories.map(\.name),
                          showingScanner: $showingReceiptScanner, photo: $receiptPhoto) { prefill, image in
            ManualTransactionView(prefill: prefill, attachImageData: image)
        }
        .task {
            // Load on appear so manual/synthetic transactions (e.g. the demo, where there's no Plaid
            // sync to populate the cache) show without a manual pull-to-refresh.
            do { try await env.accounts(context).refreshTransactions(accountId: account?.id) }
            catch { errorText = errorMessage(error) }
        }
        .task(id: transactions.map(\.id)) {
            // Warm the favicon cache for every row's note override + merchant (deduped). Catalog hits are
            // instant; unknowns cost one cached on-device lookup each. Rows read the result synchronously.
            let lookup = self.lookup
            await brandModel.resolve(merchantTexts: transactions.flatMap { t in
                let c = CategoryMapping.effectiveCategory(for: t, lookup: lookup)
                return [(text: t.note, category: c), (text: t.details, category: c)]
            })
        }
        .refreshable {
            if let account {  // one account → detail scope, sync just its bank
                await env.smartRefresh(source: account.plaidItemId != nil ? .bank : .none,
                                       freshness: account.updatedAt, plaidItemId: account.plaidItemId,
                                       context: context) {
                    try await env.accounts(context).refreshTransactions(accountId: account.id)
                    try await env.accounts(context).reapStalePending(accountId: account.id)
                }
            } else {  // all transactions → list scope, all banks (freshness = last bank sync)
                let freshness = (try? context.fetch(FetchDescriptor<Account>()))?.map(\.updatedAt).max()
                await env.smartRefresh(source: .bank, freshness: freshness, context: context) {
                    try await env.accounts(context).refreshTransactions(accountId: nil)
                    try await env.accounts(context).reapStalePending()
                }
            }
        }
        .errorAlert($errorText)
    }

    /// Toggle to group pending transactions into their own section vs interleave them by date.
    private var pendingToggle: some View {
        Toggle("Separate pending", systemImage: "clock.badge", isOn: $groupPending)
    }

    /// A row that drills into the transaction's detail. Closure-based (not value-based) nav: this list is
    /// pushed inside the Accounts tab stack, where value-based links drop the first tap.
    private func transactionLink(_ transaction: Transaction, lookup: [String: String],
                                 isPending: Bool) -> some View {
        // LazyView so SwiftUI doesn't eagerly build every row's detail view (with its @Query) on each
        // render - that eager construction spun an infinite re-render loop (main-thread freeze).
        NavigationLink {
            LazyView(TransactionDetailView(transaction: transaction))
        } label: {
            TransactionRow(transaction: transaction, lookup: lookup, brandModel: brandModel,
                           isPending: isPending)
        }
    }

    /// Persists one inclusion override (the unspecified flag is left untouched server-side).
    private func setFlags(_ account: Account, includeInSpending: Bool? = nil,
                          includeInCashFlow: Bool? = nil) {
        Task {
            do {
                try await env.accounts(context).updateFlags(
                    id: account.id, includeInSpending: includeInSpending,
                    includeInCashFlow: includeInCashFlow)
            } catch { errorText = errorMessage(error) }
        }
    }
}

/// One transaction row: category icon, description + date/category subtitle, and amount. A pending row is
/// drawn in lighter (secondary) text with a "Pending" pill so it reads as not-yet-final.
struct TransactionRow: View {
    let transaction: Transaction
    /// Prebuilt raw→canonical map (built once per render by the list - don't rebuild it here).
    let lookup: [String: String]
    /// Shared brand resolver owned by the list; drives the merchant favicon (falls back to the category icon).
    var brandModel: BrandModel
    var isPending: Bool = false

    var body: some View {
        // A dict lookup per row is fine; only rebuilding `lookup` per row was the perf bug.
        let category = CategoryMapping.effectiveCategory(for: transaction, lookup: lookup)
        HStack(spacing: 12) {
            MerchantAvatar(merchant: transaction.details, note: transaction.note,
                           category: category, size: 30, amount: transaction.amount, brandModel: brandModel)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(transaction.details).foregroundStyle(isPending ? .secondary : .primary)
                    if isPending { PendingPill() }
                }
                if let note = transaction.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(transaction.date.dateOnly())
                    if let category { Text("· \(category)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(transaction.amount.formatted(.currency(code: transaction.currency)))
                .foregroundStyle(isPending ? .secondary : .primary)
        }
    }
}

/// A small "Pending" pill, in the same orange the account summary uses for pending totals.
struct PendingPill: View {
    var body: some View {
        Text("Pending")
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
    }
}

/// A minimal manual-transaction form (source = manual on the backend).
/// A manual (cash/self-entered) transaction. Conforms to our other forms: a tappable category icon
/// top-left, plus an optional account. Categorized manual transactions count toward budgets/Trends.
struct ManualTransactionView: View {
    /// Receipt scan can seed a new transaction: the image is attached and the detected line items saved after
    /// the transaction is created. Nil for a blank manual entry.
    let attachImageData: Data?
    private let prefillItems: [ItemDraft]

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var details = ""
    @State private var amountString = ""
    @State private var date = Date()
    @State private var category: String?
    @State private var accountId: UUID?
    @State private var showingCategoryPicker = false
    @State private var saving = false
    @State private var errorText: String?
    /// Minted once per form instance so every Save retry sends the same Idempotency-Key - a re-tap or
    /// retry-after-timeout dedups to one transaction server-side.
    @State private var idempotencyKey = UUID().uuidString

    init(prefill: ExpensePrefill? = nil, attachImageData: Data? = nil) {
        self.attachImageData = attachImageData
        self.prefillItems = prefill?.items ?? []
        _details = State(initialValue: prefill?.details ?? "")
        _amountString = State(initialValue: prefill.map { NSDecimalNumber(decimal: $0.amount).stringValue } ?? "")
        _date = State(initialValue: prefill?.date ?? Date())
        _category = State(initialValue: prefill?.category)
    }

    private var amount: Decimal { Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
    /// An income/reimbursement category means money in - store it as an inflow (negative), matching Plaid.
    private var isIncome: Bool { category.map { CanonicalCategory.incomeLike.contains($0) } ?? false }
    private var canSave: Bool { !details.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Button { showingCategoryPicker = true } label: {
                            Image(systemName: categorySymbol(category))
                                .font(.title3).foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(.quaternary))
                        }
                        .buttonStyle(.plain)
                        TextField("Description", text: $details).font(.title3)
                    }
                    HStack(spacing: 8) {
                        Text(isIncome ? "+$" : "$").font(.title2)
                            .foregroundStyle(isIncome ? Color.green : .secondary)
                        TextField("0.00", text: $amountString).keyboardType(.decimalPad).font(.title2)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                } footer: {
                    if isIncome {
                        Text("Recorded as income (money in).").foregroundStyle(.green)
                    }
                }
                Section {
                    Picker("Account", selection: $accountId) {
                        Text("None (cash)").tag(UUID?.none)
                        ForEach(accounts) { Text($0.displayLabel).tag(UUID?.some($0.id)) }
                    }
                } footer: {
                    Text("Optional — scope it to an account, or leave as cash. Either way it counts toward your budgets by category.")
                }
                if !prefillItems.isEmpty {
                    Section {
                        ForEach(Array(prefillItems.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text(item.name)
                                Spacer()
                                Text(item.price, format: .currency(code: "USD")).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Detected items")
                    } footer: {
                        Text("Scanned from the receipt — saved with the transaction; edit them from its detail.")
                    }
                }
            }
            .navigationTitle("Manual Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: save).disabled(!canSave) }
            }
            .sheet(isPresented: $showingCategoryPicker) {
                CategoryPickerView(current: category) { category = $0 }
            }
            .errorAlert($errorText)
        }
    }

    private func save() {
        saving = true
        let draft = TransactionDraft(accountId: accountId, details: details,
                                     amount: isIncome ? -amount : amount,
                                     date: date, category: category)
        let items = prefillItems
        let image = attachImageData
        Task {
            defer { saving = false }
            do {
                let id = try await env.accounts(context).createTransaction(draft, idempotencyKey: idempotencyKey)
                if !items.isEmpty { try await env.accounts(context).setItems(id: id, items: items) }
                if let image { try await env.receipts(context).upload(transactionId: id, imageData: image) }
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}

/// Pick a group, then open the expense editor prefilled from the transaction (links via transaction_id).
/// The group list hides settled groups and sorts by recent activity, matching the Expenses tab.
/// Presented from `TransactionDetailView`'s "Add to a Group".
struct NewExpenseFromTransactionView: View {
    let transaction: Transaction
    /// Relayed up when the create fails because this (pending) transaction posted - the parent raises the
    /// "already posted" prompt after this sheet dismisses.
    var onTransactionGone: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<ExpenseGroup> { $0.supersededAt == nil && $0.hidden == false },
           sort: \ExpenseGroup.name)
    private var groups: [ExpenseGroup]
    @Query private var members: [GroupMember]
    @Query private var balanceRows: [GroupBalance]
    @State private var selectedGroupId: UUID?
    @State private var showingEditor = false
    @State private var editorGone = false
    @State private var showSettled = false
    @State private var myNets: [UUID: Decimal] = [:]
    @State private var lastExpense: [UUID: GroupSummary.Last] = [:]

    private var selectedGroup: ExpenseGroup? { groups.first { $0.id == selectedGroupId } }
    private var memberIdentifiers: [String] {
        members.filter { $0.groupId == selectedGroupId }.map(\.userIdentifier)
    }

    private var hiddenCount: Int {
        groups.filter { GroupSummary.isSettled($0, myNets: myNets, lastExpense: lastExpense) }.count
    }
    private var visibleGroups: [ExpenseGroup] {
        GroupSummary.visible(groups, myNets: myNets, lastExpense: lastExpense, includeSettled: showSettled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    Picker("Group", selection: $selectedGroupId) {
                        Text("Select a group").tag(UUID?.none)
                        ForEach(visibleGroups) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    if hiddenCount > 0 || showSettled {
                        Toggle("Show settled groups", isOn: $showSettled)
                    }
                }
                Section("Transaction") {
                    LabeledContent("Description", value: transaction.details)
                    LabeledContent("Amount", value: transaction.amount.formatted(.currency(code: transaction.currency)))
                    LabeledContent("Date", value: transaction.date.dateOnly())
                }
                Section {
                    Button("Create Expense") { showingEditor = true }.disabled(selectedGroupId == nil)
                }
            }
            .navigationTitle("From Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                myNets = GroupSummary.myNets(from: balanceRows, me: env.currentUser?.identifier)
                loadLastExpenses()
            }
            .onChange(of: showSettled) { _, _ in loadLastExpenses() }
            .sheet(isPresented: $showingEditor, onDismiss: {
                if editorGone { editorGone = false; onTransactionGone(); dismiss() }
            }) {
                if let selectedGroup {
                    ExpenseEditView(group: selectedGroup, members: memberIdentifiers,
                                    prefill: .from(transaction),
                                    onCreateTransactionGone: transaction.pending ? { editorGone = true } : nil)
                }
            }
        }
    }

    private func loadLastExpenses() {
        lastExpense = GroupSummary.lastExpenses(groups, myNets: myNets, includeSettled: showSettled, context: context)
    }
}
