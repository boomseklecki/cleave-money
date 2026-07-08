import SwiftData
import SwiftUI

/// Confirmation before accepting a **Link** suggestion. These matches are heuristic (not exact), so this
/// shows the expense next to the proposed bank transaction - amounts, dates, categories, and the match
/// strength - and lets the user verify before de-duping, pick a different transaction, or back out.
/// `onConfirm` performs the actual link (InboxView's `accept` → `linkTransaction` + reload); `onExternalChange`
/// lets the picker correction path refresh the Inbox after it links a different transaction itself.
struct LinkConfirmSheet: View {
    let suggestion: Suggestion
    let onConfirm: () -> Void
    var onExternalChange: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var expense: Expense?
    @State private var transaction: Transaction?
    @State private var groupName: String?
    @State private var accountName: String?
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                if let expense, let transaction {
                    Section("Expense") {
                        NavigationLink {
                            LazyView(ExpenseDetailView(expense: expense))
                        } label: {
                            SuggestionRecordRow(title: expense.details, amount: expense.amount,
                                                currency: expense.currency, date: expense.date,
                                                category: expense.category,
                                                source: groupName, sourceIcon: "person.2")
                        }
                    }
                    Section {
                        NavigationLink {
                            LazyView(TransactionDetailView(transaction: transaction))
                        } label: {
                            SuggestionRecordRow(title: transaction.details, amount: transaction.amount,
                                                currency: transaction.currency, date: transaction.date,
                                                category: transaction.category,
                                                source: accountName, sourceIcon: "building.columns")
                        }
                    } header: {
                        HStack {
                            Text("Bank transaction")
                            Spacer()
                            if let score = suggestion.matchScore {
                                Text(TransactionMatcher.confidenceLabel(score)).foregroundStyle(.tint)
                            }
                        }
                    } footer: {
                        Text("Linking de-duplicates your spending so this charge counts once, not twice.")
                    }
                    Section {
                        Button { showPicker = true } label: {
                            Label("Choose a different transaction…", systemImage: "arrow.triangle.swap")
                        }
                    }
                } else {
                    ContentUnavailableView("Couldn’t load the match", systemImage: "questionmark.circle")
                }
            }
            .navigationTitle("Confirm Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link") { onConfirm(); dismiss() }
                        .disabled(expense == nil || transaction == nil)
                }
            }
            .task { resolve() }
            .sheet(isPresented: $showPicker, onDismiss: pickerDismissed) {
                if let expense { TransactionLinkView(expense: expense) }
            }
        }
    }

    private func resolve() {
        if let eid = suggestion.expenseId {
            expense = try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.id == eid })).first
        }
        if let tid = suggestion.transactionId {
            transaction = try? context.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == tid })).first
        }
        // The split group the expense lives in, and the account behind the transaction - so the two sides of
        // the link read as counterparts.
        if let gid = expense?.groupId {
            groupName = (try? context.fetch(
                FetchDescriptor<ExpenseGroup>(predicate: #Predicate { $0.id == gid })))?.first?.name
        }
        if let aid = transaction?.accountId,
           let account = try? context.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { $0.id == aid })).first {
            accountName = [account.displayLabel, account.maskLabel].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// If the picker linked a (different) transaction itself, refresh the Inbox and close this sheet too.
    private func pickerDismissed() {
        resolve()
        if expense?.transactionId != nil {
            onExternalChange()
            dismiss()
        }
    }
}
