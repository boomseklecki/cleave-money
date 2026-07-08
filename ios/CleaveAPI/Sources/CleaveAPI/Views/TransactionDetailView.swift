import SwiftUI
import SwiftData

/// Drill-through detail for a single bank/manual transaction: a header with a tappable category icon
/// (like the expense detail), the transaction's fields, an on-device "categorize this one" action, and
/// a button that continues to the prefilled expense-creation flow (or links to the expense already made
/// from it). Recategorizing here writes a per-transaction override, independent of the Plaid label.
struct TransactionDetailView: View {
    let transaction: Transaction

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var categoryMaps: [CategoryMap]
    @Query(sort: \SpendCategory.position) private var spendCategories: [SpendCategory]
    @Query private var accounts: [Account]
    @Query private var subscriptionRules: [SubscriptionRule]

    @State private var showingCategoryPicker = false
    @State private var showingCreate = false
    @State private var showingLinkExpense = false
    @State private var showingItems = false
    @State private var showingReceiptManager = false
    @State private var editingNote = false
    @State private var categorizing = false
    @State private var aiAvailable = false
    @State private var brandModel = BrandModel()
    @State private var errorText: String?
    /// "This transaction already posted" flow: set when a customize action 404s on a pending row. `postedTwin`
    /// is the posted replacement (matched by `pendingTransactionId`), if we found it; `showingPosted` drives
    /// the prompt; `showingTwin` opens the twin in a sheet. `sheetDetectedGone` relays the signal from the
    /// items/link child sheets so we trigger the prompt only after the sheet has dismissed (no alert/sheet race).
    @State private var postedTwin: Transaction?
    @State private var showingPosted = false
    @State private var showingTwin = false
    @State private var sheetDetectedGone = false
    /// The expense linked to this transaction, loaded off the render path (see `loadLinkedExpense`). A
    /// body-time `@Query` over the expenses table blocked the navigation push on large datasets.
    @State private var linkedExpense: Expense?
    @State private var confirmItemReplace = false
    @AppStorage("debug.categoryProvenance") private var showProvenance = false

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var sources: [String: String] { CategoryMapping.sources(categoryMaps) }
    private var resolution: CategoryResolution {
        CategoryMapping.resolve(for: transaction, lookup: lookup, sources: sources)
    }
    private var effectiveCategory: String? { resolution.category }

    /// The account this transaction belongs to (for the name). Filtered in memory from the observed
    /// query - never fetch from the context during `body`, which loops the view.
    private var account: Account? {
        guard let id = transaction.accountId else { return nil }
        return accounts.first { $0.id == id }
    }

    /// This transaction's line items in entry order.
    private var itemsByAdded: [TransactionItem] {
        transaction.items.sorted { ($0.addedOn ?? .distantPast) < ($1.addedOn ?? .distantPast) }
    }

    /// When linked, the expense owns the shared items (only it feeds spend); else this transaction owns them.
    private var itemsCanonicalOwner: ItemOwner {
        if let e = linkedExpense { return .expense(e) }
        return .transaction(transaction)
    }
    /// Items shown in the Items section - the linked expense's when linked, else this transaction's.
    private var canonicalDisplayItems: [(id: UUID, name: String, category: String?, price: Decimal)] {
        if let e = linkedExpense { return e.items.map { ($0.id, $0.name, $0.category, $0.price) } }
        return itemsByAdded.map { ($0.id, $0.name, $0.category, $0.price) }
    }

    /// The raw Plaid label, humanized, shown only when it differs from the effective category.
    private var rawLabel: String? {
        guard let raw = transaction.category, !raw.isEmpty else { return nil }
        let humanized = PlaidCategory.humanized(raw)
        return humanized == effectiveCategory ? nil : humanized
    }

    private var amountText: String { transaction.amount.formatted(.currency(code: transaction.currency)) }

    /// This transaction's merchant key + any matching subscription rule (for the Mark-as-Subscription row).
    private var subscriptionMerchantKey: String { MerchantText.key(transaction.details) }
    private var subscriptionRule: SubscriptionRule? {
        subscriptionRules.first {
            $0.merchantKey == subscriptionMerchantKey
                && SubscriptionDetector.matches(amount: transaction.amount, rule: $0)
        }
    }

    var body: some View {
        List {
            Section {
                header
                if let note = transaction.note, !note.isEmpty { NoteRow(note) }
                if let account { LabeledContent("Account", value: account.name) }
                LabeledContent("Status", value: transaction.pending ? "Pending" : "Posted")
                LabeledContent("Source", value: transaction.source == .plaid ? "Bank" : "Manual")
                if let rawLabel { LabeledContent("Bank category", value: rawLabel) }
                LabeledContent("Updated", value: transaction.updatedAt.relativeUpdatedCapitalized)
            }

            Section {
                NavigationLink {
                    RelatedTransactionsView(seedDescription: transaction.details, seedCategory: effectiveCategory,
                                            seedAmount: transaction.amount, seedNote: transaction.note,
                                            seedDate: transaction.date)
                } label: {
                    Label("Find Related Transactions", systemImage: "text.magnifyingglass")
                }
            } footer: {
                Text("Group bank/manual transactions with a similar description and recategorize them together.")
            }

            Section {
                if let expense = linkedExpense {
                    NavigationLink {
                        LazyView(ExpenseDetailView(expense: expense))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(expense.details)
                                Text(expense.date.dateOnly())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(expense.amount.currency(expense.currency))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Button("Unlink Expense", systemImage: "link.badge.plus", role: .destructive) {
                        unlinkExpense()
                    }
                } else {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("Add to a Group", systemImage: "plus.circle")
                    }
                    Button {
                        showingLinkExpense = true
                    } label: {
                        Label("Link Existing Expense", systemImage: "link")
                    }
                }
            } header: {
                Text("Linked Expense")
            } footer: {
                Text(linkedExpense == nil
                     ? "Turn this transaction into a shared expense, or link one you already have so it "
                        + "isn't double-counted in spending."
                     : "Spending counts your share of the linked expense instead of the full transaction.")
            }

            if transaction.amount > 0 {
                Section {
                    ForEach(canonicalDisplayItems, id: \.id) { item in
                        let itemCategory = item.category.flatMap { CategoryMapping.canonical($0, lookup: lookup) }
                        ItemListRow(name: item.name, category: itemCategory, owner: nil,
                                    price: item.price.currency(transaction.currency))
                    }
                    Button {
                        showingItems = true
                    } label: {
                        Label(canonicalDisplayItems.isEmpty ? "Itemize…" : "Edit Items",
                              systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text("Items")
                } footer: {
                    Text(linkedExpense == nil
                         ? "Split this transaction across categories by line item — counts toward your budgets and Trends per item."
                         : "Shared with the linked expense — items live on the expense while linked.")
                }
            }

            if transaction.amount > 0 {
                Section {
                    if let rule = subscriptionRule {
                        Button(rule.isSubscription ? "Remove from Subscriptions" : "Remove Exclusion",
                               role: .destructive) {
                            context.delete(rule)
                            do { try context.save(); env.pushSuggestionsSync(context) }
                            catch { errorText = errorMessage(error) }
                        }
                    } else {
                        Button { markAsSubscription() } label: {
                            Label("Mark as Subscription", systemImage: "repeat")
                        }
                    }
                } footer: {
                    Text("Track this recurring charge in Subscriptions (matches this merchant near this amount).")
                }
            }

            BudgetFlagsSection(
                includeInSpending: Binding(
                    get: { transaction.includeInSpending ?? account?.countsInSpending ?? true },
                    set: { setFlags(includeInSpending: $0) }),
                includeInCashFlow: Binding(
                    get: { transaction.includeInCashFlow ?? account?.countsInCashFlow ?? true },
                    set: { setFlags(includeInCashFlow: $0) }),
                footer: "Turn off to keep this transaction out of spending / cash flow and Trends. Doesn't change "
                    + "any balances.")
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {  // leaf: always live-sync this transaction's bank (if any), then reconcile
            let pid = accounts.first { $0.id == transaction.accountId }?.plaidItemId
            await env.smartRefresh(source: pid != nil ? .bank : .none,
                                   freshness: transaction.updatedAt, plaidItemId: pid, context: context) {
                try await env.accounts(context).refreshTransactions(accountId: transaction.accountId)
            }
        }
        .task {
            aiAvailable = CategoryMapper.isAvailable
            loadLinkedExpense()
        }
        .task(id: [transaction.note, transaction.details]) {
            let c = CategoryMapping.effectiveCategory(for: transaction, lookup: lookup)
            await brandModel.resolve(merchantTexts: [(text: transaction.note, category: c),
                                                     (text: transaction.details, category: c)])
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: effectiveCategory,
                               onReset: canReset ? { resetCategory() } : nil) { setOverride($0) }
        }
        // Re-resolve the linked expense after creating/linking one (no @Query to auto-update now).
        .sheet(isPresented: $showingCreate, onDismiss: handleSheetDismiss) {
            NewExpenseFromTransactionView(transaction: transaction) { sheetDetectedGone = true }
        }
        .sheet(isPresented: $showingLinkExpense, onDismiss: handleSheetDismiss) {
            ExpenseLinkView(transaction: transaction) { sheetDetectedGone = true }
        }
        .sheet(isPresented: $showingItems, onDismiss: handleSheetDismiss) {
            ItemsEditorView(owner: itemsCanonicalOwner) { sheetDetectedGone = true }
        }
        .sheet(isPresented: $editingNote) {
            NoteEditorSheet(initial: transaction.note ?? "") { saveNote($0) }
        }
        .alert("Both have items", isPresented: $confirmItemReplace) {
            Button("Use Expense's Items", role: .destructive) { Task { await clearTransactionItems() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This transaction and the linked expense both have items. The expense's items will be used; "
                 + "this transaction's items will be replaced.")
        }
        .sheet(isPresented: $showingReceiptManager) {
            ReceiptManagerView(owner: .transaction(transaction, linkedExpense: linkedExpense))
        }
        .sheet(isPresented: $showingTwin) {
            if let twin = postedTwin {
                NavigationStack { TransactionDetailView(transaction: twin) }
            }
        }
        .alert("This transaction has already posted", isPresented: $showingPosted) {
            if postedTwin != nil {
                Button("View posted transaction") { showingTwin = true }
            }
            Button("Back to account", role: .cancel) { dismiss() }
        } message: {
            Text(postedTwin != nil
                 ? "Your change wasn’t saved here — this pending charge posted as a new transaction. Open it to make the change there."
                 : "Your change wasn’t saved here — this pending charge posted as a new transaction. It’ll appear in your account in a moment.")
        }
        .errorAlert($errorText)
    }

    /// Header mirroring the expense detail: tappable category icon (→ picker), amount, category, date.
    private var header: some View {
        DetailHeader(symbol: categorySymbol(effectiveCategory), iconColor: categoryColor(effectiveCategory),
                     logoURL: brandModel.logoURL(note: transaction.note, merchant: transaction.details,
                                                 amount: transaction.amount),
                     amount: amountText, date: transaction.date.dateOnly(), description: transaction.details,
                     category: effectiveCategory, provenance: resolution.source,
                     inspector: showProvenance ? resolution.inspectorString : nil,
                     onCategoryTap: { showingCategoryPicker = true }) {
            if aiAvailable {
                AICategorizeButton(running: categorizing) { Task { await categorizeWithAI() } }
            }
            NoteButton(hasNote: transaction.note?.isEmpty == false) { editingNote = true }
            ReceiptButton(owner: .transaction(transaction, linkedExpense: linkedExpense)) { showingReceiptManager = true }
        }
    }

    /// Fetch the linked expense with a scoped, single-row descriptor - off the body/render path so opening
    /// the detail never blocks on the expenses table.
    private func loadLinkedExpense() {
        let tid = transaction.id
        // Local scan first - reflects a just-made link immediately, no matter the back-reference's freshness.
        var descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.transactionId == tid })
        descriptor.fetchLimit = 1
        if let found = (try? context.fetch(descriptor))?.first { linkedExpense = found; return }
        // Not in the local cache (e.g. the expense was pruned by reconcileAll's cap) - resolve via the server
        // back-reference, fetching the detail on demand.
        guard let eid = transaction.linkedExpenseId else { linkedExpense = nil; return }
        if let cached = try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.id == eid })).first {
            linkedExpense = cached
            return
        }
        Task {
            try? await env.expenses(context).refreshDetail(id: eid)
            linkedExpense = try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.id == eid })).first
        }
    }

    /// Unlink the expense from this transaction (clears `expense.transaction_id`), matching the expense's Unlink.
    private func unlinkExpense() {
        guard let eid = linkedExpense?.id else { return }
        Task {
            do {
                try await env.expenses(context).linkTransaction(expenseId: eid, transactionId: nil)
                // Refresh first so the (now-stale) linked_expense_id back-reference doesn't re-show the expense.
                try? await env.accounts(context).refreshTransaction(id: transaction.id)
                loadLinkedExpense()
            } catch { errorText = errorMessage(error) }
        }
    }

    /// Force this merchant into Subscriptions (an include rule keyed by merchant + this amount).
    private func markAsSubscription() {
        let name = subscriptionMerchantKey
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        context.insert(SubscriptionRule(merchantKey: subscriptionMerchantKey, amount: transaction.amount,
                                        isSubscription: true,
                                        displayName: name.isEmpty ? transaction.details : name))
        do { try context.save(); env.pushSuggestionsSync(context) } catch { errorText = errorMessage(error) }
    }

    private func setOverride(_ category: String?) {
        let id = transaction.id
        Task {
            do { try await env.accounts(context).setCategoryOverride(id: id, category: category) }
            catch { await handleCustomizeError(error) }
        }
    }

    private func saveNote(_ note: String) {
        let id = transaction.id
        // Note changed? Let the background suggestion pass reconsider this row with the new context - clearing
        // the once-set `aiSuggestedCategory` re-admits it to `refreshAI`, surfacing a note-informed suggestion.
        let changed = (transaction.note ?? "") != note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await env.accounts(context).setTransactionNote(id: id, note: note)
                if changed { transaction.aiSuggestedCategory = nil; try? context.save() }
            } catch { await handleCustomizeError(error) }
        }
    }

    /// Whether there's a per-row category signal (manual override or AI refinement) to reset.
    private var canReset: Bool {
        transaction.categoryOverride != nil || (transaction.refinedCategory.map { !$0.isEmpty } ?? false)
    }

    /// "Reset to Automatic": drop the override + AI refinement so the row falls back to its automatic category.
    /// Optimistic local clear + best-effort server (see `AccountRepository.resetCategory`).
    private func resetCategory() {
        transaction.categoryOverride = nil
        transaction.refinedCategory = nil
        try? context.save()
        let id = transaction.id
        Task {
            do { try await env.accounts(context).resetCategory(id: id) }
            catch { await handleCustomizeError(error) }
        }
    }

    private func setFlags(includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil) {
        let id = transaction.id
        Task {
            do {
                try await env.accounts(context).setTransactionFlags(
                    id: id, includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow)
            } catch { await handleCustomizeError(error) }
        }
    }

    /// A customize action failed. If it's a pending row that the server no longer has, the charge posted - 
    /// run the "already posted" flow instead of a generic error.
    private func handleCustomizeError(_ error: Error) async {
        if transaction.pending, (error as? BackendError) == .notFound {
            await handlePosted()
        } else {
            errorText = errorMessage(error)
        }
    }

    /// Refresh (upsert-only, so we don't reap THIS still-displayed row), locate the posted twin by the
    /// pending charge's plaid id, and raise the prompt.
    private func handlePosted() async {
        try? await env.accounts(context).refreshTransactions(accountId: transaction.accountId)
        if let p1 = transaction.plaidTransactionId {
            var descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.pendingTransactionId == p1 && !$0.pending })
            descriptor.fetchLimit = 1
            postedTwin = (try? context.fetch(descriptor))?.first
        }
        showingPosted = true
    }

    /// After an items/link child sheet dismisses, relay its "transaction gone" signal into the posted flow.
    private func handleSheetDismiss() {
        loadLinkedExpense()
        reconcileLinkedItems()
        // A link made from this screen writes expense.transaction_id; refresh so the transaction's own
        // linked_expense_id back-reference is populated (durable if the linked expense is later evicted).
        if let e = linkedExpense, transaction.linkedExpenseId != e.id {
            Task { try? await env.accounts(context).refreshTransaction(id: transaction.id) }
        }
        guard sheetDetectedGone else { return }
        sheetDetectedGone = false
        Task { await handlePosted() }
    }

    /// After a link is (re)established, make the expense the single owner of the shared items: migrate this
    /// transaction's items onto an empty expense, or - if both already have items - confirm before the
    /// expense's replace them.
    private func reconcileLinkedItems() {
        guard let expense = linkedExpense, !transaction.items.isEmpty else { return }
        if expense.items.isEmpty {
            Task { await migrateItems(to: expense) }
        } else {
            confirmItemReplace = true
        }
    }

    private func migrateItems(to expense: Expense) async {
        let drafts = transaction.items.map {
            ItemDraft(name: $0.name, quantity: $0.quantity, price: $0.price, category: $0.category)
        }
        do {
            try await env.expenses(context).setItems(id: expense.id, items: drafts,
                                                     updatedBy: env.currentUser?.identifier)
            try await env.accounts(context).setItems(id: transaction.id, items: [])
        } catch { errorText = errorMessage(error) }
    }

    private func clearTransactionItems() async {
        do { try await env.accounts(context).setItems(id: transaction.id, items: []) }
        catch { errorText = errorMessage(error) }
    }

    private func categorizeWithAI() async {
        categorizing = true
        defer { categorizing = false }
        // Anchor on the current effective category so `refine` only replaces a confident category when the
        // model is *clearly* more accurate (its `changeIsClear` gate); an uncategorized/"Other" row (nil/vague
        // anchor) is just classified. This keeps a good built-in mapping from being second-guessed.
        let item = CategoryMapper.Item(id: transaction.id, description: transaction.details,
                                       rawCategory: transaction.category, current: effectiveCategory,
                                       note: transaction.note)
        let result = await CategoryMapper.refine([item], allowed: spendCategories.map(\.name))
        guard let category = result[transaction.id] else { return }  // keep prior if the model abstains
        // AI categorization writes `refinedCategory` (provenance "AI"), not an override; clear any existing
        // manual override so the explicitly-invoked AI result wins and shows.
        let id = transaction.id
        let hadOverride = transaction.categoryOverride != nil
        do {
            try await env.accounts(context).setRefinedCategory(id: id, category: category)
            if hadOverride { try await env.accounts(context).setCategoryOverride(id: id, category: nil) }
        } catch { await handleCustomizeError(error) }
    }
}
