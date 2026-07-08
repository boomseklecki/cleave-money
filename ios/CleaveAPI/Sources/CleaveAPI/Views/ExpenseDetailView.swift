import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Full expense detail: a header with a tappable category icon + receipt thumbnail, a "who paid /
/// who owes" split breakdown, line items, receipt management, and edit/delete.
struct ExpenseDetailView: View {
    let expense: Expense

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var users: [User]
    @Query private var categoryMaps: [CategoryMap]
    @Query(sort: \SpendCategory.position) private var spendCategories: [SpendCategory]
    @AppStorage("debug.categoryProvenance") private var showProvenance = false

    @State private var showingEdit = false
    @State private var editPrefill: ExpensePrefill?
    @State private var showingCategoryPicker = false
    @State private var confirmingDelete = false
    @State private var errorText: String?
    @State private var showingReceiptManager = false
    @State private var showingMatcher = false
    @State private var rememberedSplit = false
    @State private var editingNote = false
    @State private var confirmItemReplace = false
    @State private var brandModel = BrandModel()

    private var meIdentifier: String? { env.currentUser?.identifier }
    private var isSettleUp: Bool { expense.category == SettleUp.category }
    /// A real shared, transaction-linked expense whose split is worth remembering for future charges.
    private var isSharedSplit: Bool {
        expense.transactionId != nil && expense.splits.filter { $0.owedShare > 0 }.count >= 2
    }

    private func rememberSplit() {
        do { try env.suggestions(context).rememberSplit(expense); rememberedSplit = true }
        catch { errorText = errorMessage(error) }
    }

    // Category display is canonical (so imported Splitwise labels like "Dining out" read "Dining"), with
    // provenance - matching the transaction detail.
    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var sources: [String: String] { CategoryMapping.sources(categoryMaps) }
    private var resolution: CategoryResolution {
        CategoryMapping.resolve(expenseCategory: expense.category, lookup: lookup, sources: sources)
    }
    private var displayCategory: String? { resolution.category }

    /// The bank/manual transaction this expense is linked to, if any (mirrors the `group` lookup).
    private var linkedTransaction: Transaction? {
        guard let tid = expense.transactionId else { return nil }
        return try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == tid })).first
    }

    /// Whether linking applies - settle-ups/reimbursements are neutral and never count as spend.
    private var linkable: Bool { !isSettleUp && !isReimbursement }

    private var group: ExpenseGroup? {
        let gid = expense.groupId
        return try? context.fetch(FetchDescriptor<ExpenseGroup>(predicate: #Predicate { $0.id == gid })).first
    }

    /// "Added by Alice on Jun 19" using the real Splitwise added-on date (falling back to our import
    /// time when unknown).
    private var addedText: String {
        let date = (expense.splitwiseCreatedAt ?? expense.createdAt).dateOnly()
        if let by = expense.createdByIdentifier {
            return "Added by \(users.displayName(for: by)) on \(date)"
        }
        return "Added \(date)"
    }

    /// "Edited by Bob on Jun 20" when it was edited after creation; nil otherwise.
    private var editedText: String? {
        guard let updated = expense.splitwiseUpdatedAt else { return nil }
        if let created = expense.splitwiseCreatedAt, abs(updated.timeIntervalSince(created)) < 1 { return nil }
        let date = updated.dateOnly()
        if let by = expense.updatedByIdentifier {
            return "Edited by \(users.displayName(for: by)) on \(date)"
        }
        return "Edited \(date)"
    }

    private func currency(_ value: Decimal) -> String { value.currency(expense.currency) }
    private func nameOrYou(_ id: String) -> String { id == meIdentifier ? "You" : users.displayName(for: id) }

    private var payers: [Split] {
        expense.splits.filter { $0.paidShare > 0 }.sorted { $0.userIdentifier < $1.userIdentifier }
    }
    private var owers: [Split] {
        expense.splits.filter { $0.owedShare > 0 && $0.paidShare == 0 }.sorted { $0.userIdentifier < $1.userIdentifier }
    }

    private var isReimbursement: Bool { expense.category == Reimbursement.category }
    /// The reimbursed person (encoded with owedShare == the full amount).
    private var reimbursementRecipient: Split? { expense.splits.max { $0.owedShare < $1.owedShare } }
    private func getsBackText(_ split: Split, amount: Decimal) -> String {
        let isMe = split.userIdentifier == meIdentifier
        let name = isMe ? "You" : users.displayName(for: split.userIdentifier)
        return "\(name) \(isMe ? "get back" : "gets back") \(currency(amount))"
    }

    private var settleUpText: String {
        let amount = currency(expense.amount)
        guard let payer = payers.first else { return amount }
        if let recipient = owers.first {
            return "\(nameOrYou(payer.userIdentifier)) paid \(nameOrYou(recipient.userIdentifier)) \(amount)"
        }
        return "\(nameOrYou(payer.userIdentifier)) paid \(amount)"
    }

    var body: some View {
        if expense.isDeleted {
            // Deleted from this screen - don't read the dangling SwiftData model (crashes); pop back.
            Color.clear.onAppear { dismiss() }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            Section {
                header
                if let note = expense.note, !note.isEmpty { NoteRow(note) }
                if isReimbursement, let recipient = reimbursementRecipient {
                    // Main row: the recipient and the gross amount they got back ("Alice got back $100").
                    Text("\(nameOrYou(recipient.userIdentifier)) got back \(currency(recipient.owedShare))")
                        .fontWeight(.medium)
                    // Indented: each other member's equal share ("Bob gets back $50").
                    ForEach(expense.splits
                        .filter { $0.userIdentifier != recipient.userIdentifier }
                        .sorted { $0.userIdentifier < $1.userIdentifier }, id: \.userIdentifier) { split in
                        Text(getsBackText(split, amount: split.paidShare))
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }
                } else if isSettleUp {
                    Text(settleUpText).fontWeight(.medium)
                } else {
                    ForEach(payers, id: \.userIdentifier) { split in
                        Text("\(nameOrYou(split.userIdentifier)) paid \(currency(split.paidShare))")
                            .fontWeight(.medium)
                    }
                    ForEach(owers, id: \.userIdentifier) { split in
                        let isMe = split.userIdentifier == meIdentifier
                        Text("\(nameOrYou(split.userIdentifier)) \(isMe ? "owe" : "owes") \(currency(split.owedShare))")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }
                }
                if isSharedSplit {
                    Button(rememberedSplit ? "Split Remembered" : "Remember This Split",
                           systemImage: rememberedSplit ? "checkmark.circle" : "arrow.triangle.2.circlepath") {
                        rememberSplit()
                    }
                    .disabled(rememberedSplit)
                }
                LabeledContent("Updated", value: expense.updatedAt.relativeUpdatedCapitalized)
            } footer: {
                if isSharedSplit {
                    Text("“Remember This Split” reuses these shares for future charges from this merchant.")
                }
            }

            Section {
                NavigationLink {
                    RelatedExpensesView(seedDescription: expense.details, seedCategory: expense.category,
                                        seedAmount: expense.amount, seedNote: expense.note,
                                        seedDate: expense.date)
                } label: {
                    Label("Find Related Expenses", systemImage: "text.magnifyingglass")
                }
            } footer: {
                Text("Group expenses with a similar description and recategorize them together.")
            }

            if linkable {
                Section {
                    if let t = linkedTransaction {
                        NavigationLink {
                            TransactionDetailView(transaction: t)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.details)
                                    Text(t.date.dateOnly())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(currency(t.amount)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Button("Unlink Transaction", systemImage: "link.badge.plus", role: .destructive) {
                            link(nil)
                        }
                    } else {
                        Button {
                            showingMatcher = true
                        } label: {
                            Label("Link a Transaction", systemImage: "link")
                        }
                    }
                } header: {
                    Text("Linked Transaction")
                } footer: {
                    Text(linkedTransaction == nil
                         ? "Link the bank payment for this expense so spending counts your share once, not "
                            + "both the expense and the full transaction."
                         : "Spending counts your share of this expense instead of the full bank transaction.")
                }
            }

            if !expense.items.isEmpty {
                Section("Items") {
                    ForEach(expense.items) { item in
                        let itemCategory = item.category.flatMap { CategoryMapping.canonical($0, lookup: lookup) }
                        // Item ownership is local-only (see ItemizedSpend); don't show a (possibly stale)
                        // assignee on Splitwise items.
                        let owner = expense.splitwiseExpenseId == nil ? item.ownerIdentifier.map(nameOrYou) : nil
                        ItemListRow(name: item.name, category: itemCategory, owner: owner,
                                    price: currency(item.price))
                    }
                }
            }

            BudgetFlagsSection(
                includeInSpending: Binding(
                    get: { expense.includeInSpending ?? group?.includeInSpending ?? true },
                    set: { setFlags(includeInSpending: $0) }),
                includeInCashFlow: Binding(
                    get: { expense.includeInCashFlow ?? group?.includeInCashFlow ?? true },
                    set: { setFlags(includeInCashFlow: $0) }),
                footer: "Turn off to keep your share of this expense out of spending / cash flow and Trends. "
                    + "Doesn't change any balances.")

            if let notes = expense.notes, !notes.isEmpty {
                Section(expense.splitwiseExpenseId != nil ? "Splitwise Notes" : "Notes") { Text(notes) }
            }

            Section("Activity") {
                Text(addedText).font(.caption).foregroundStyle(.secondary)
                if let editedText {
                    Text(editedText).font(.caption).foregroundStyle(.secondary)
                }
                if expense.repeats == true {
                    Label(expense.repeatInterval.map { "Repeats \($0)" } ?? "Repeating",
                          systemImage: "repeat")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Delete Expense", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle("Expense")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {  // leaf: always live-sync this expense's Splitwise group (if any), then reconcile
            await env.smartRefresh(source: group?.backendType == .splitwise ? .splitwise : .none,
                                   freshness: expense.updatedAt,
                                   splitwiseScope: expense.splitwiseExpenseId.map { .expense($0) } ?? .all,
                                   context: context) {
                try await env.expenses(context).reconcileAll(groupId: expense.groupId)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editPrefill = nil; showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            if let group {
                ExpenseEditView(group: group, members: [], editing: expense, prefill: editPrefill)
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: expense.category) { newCategory in
                updateCategory(newCategory)
            }
        }
        .sheet(isPresented: $showingMatcher, onDismiss: reconcileLinkedItems) {
            TransactionLinkView(expense: expense)
        }
        .alert("Both have items", isPresented: $confirmItemReplace) {
            Button("Use Expense's Items", role: .destructive) { Task { await clearLinkedTransactionItems() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This expense and the linked transaction both have items. The expense's items will be used; "
                 + "the transaction's items will be replaced.")
        }
        .confirmationDialog("Delete this expense?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text(expense.splitwiseExpenseId != nil
                 ? "This permanently deletes the expense here and on Splitwise."
                 : "This permanently deletes the expense.")
        }
        .sheet(isPresented: $showingReceiptManager) {
            ReceiptManagerView(owner: .expense(expense, linkedTransaction: linkedTransaction))
        }
        .sheet(isPresented: $editingNote) {
            NoteEditorSheet(initial: expense.note ?? "") { saveNote($0) }
        }
        .task(id: [expense.note, expense.details]) {
            await brandModel.resolve(merchantTexts: [(text: expense.note, category: expense.category),
                                                     (text: expense.details, category: expense.category)])
        }
        .errorAlert($errorText)
    }

    /// Header: tappable category icon (→ picker), amount + category + date, receipt thumbnail.
    private var header: some View {
        DetailHeader(symbol: categorySymbol(displayCategory), iconColor: nil,
                     logoURL: brandModel.logoURL(note: expense.note, merchant: expense.details,
                                                 amount: expense.amount),
                     amount: currency(expense.amount), date: expense.date.dateOnly(), description: expense.details,
                     category: displayCategory, provenance: resolution.source,
                     inspector: showProvenance ? resolution.inspectorString : nil,
                     onCategoryTap: { showingCategoryPicker = true }) {
            NoteButton(hasNote: expense.note?.isEmpty == false) { editingNote = true }
            ReceiptButton(owner: .expense(expense, linkedTransaction: linkedTransaction)) { showingReceiptManager = true }
        }
    }

    /// Link this expense to a transaction (nil unlinks). De-dupes the pair in spending.
    private func link(_ transactionId: UUID?) {
        let id = expense.id
        Task {
            do { try await env.expenses(context).linkTransaction(expenseId: id, transactionId: transactionId) }
            catch { errorText = errorMessage(error) }
        }
    }

    /// After linking a transaction here, make this expense the single owner of the shared items: migrate the
    /// transaction's items onto an empty expense, or - if both already have items - confirm before replacing.
    private func reconcileLinkedItems() {
        guard let t = linkedTransaction, !t.items.isEmpty else { return }
        if expense.items.isEmpty {
            Task { await migrateItems(from: t) }
        } else {
            confirmItemReplace = true
        }
    }

    private func migrateItems(from t: Transaction) async {
        let drafts = t.items.map {
            ItemDraft(name: $0.name, quantity: $0.quantity, price: $0.price, category: $0.category)
        }
        do {
            try await env.expenses(context).setItems(id: expense.id, items: drafts,
                                                     updatedBy: env.currentUser?.identifier)
            try await env.accounts(context).setItems(id: t.id, items: [])
        } catch { errorText = errorMessage(error) }
    }

    private func clearLinkedTransactionItems() async {
        guard let t = linkedTransaction else { return }
        do { try await env.accounts(context).setItems(id: t.id, items: []) }
        catch { errorText = errorMessage(error) }
    }

    private func updateCategory(_ category: String) {
        let id = expense.id
        let me = env.currentUser?.identifier
        Task {
            do { try await env.expenses(context).updateCategory(id: id, category: category, updatedBy: me) }
            catch { errorText = errorMessage(error) }
        }
    }


    private func delete() {
        let id = expense.id
        Task {
            do {
                try await env.expenses(context).delete(id: id)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }

    private func setFlags(includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil) {
        let id = expense.id
        Task {
            do {
                try await env.expenses(context).setFlags(
                    id: id, includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow)
            } catch { errorText = errorMessage(error) }
        }
    }

    private func saveNote(_ note: String) {
        let id = expense.id
        Task {
            do { try await env.expenses(context).setNote(id: id, note: note) }
            catch { errorText = errorMessage(error) }
        }
    }
}
