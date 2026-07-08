import SwiftUI
import SwiftData

/// Reverse flow: "link an existing expense to this transaction" - heuristic-ranked unlinked expenses.
struct ExpenseLinkView: View {
    let transaction: Transaction
    /// Called when linking fails because the (pending) transaction no longer exists server-side - it posted.
    var onTransactionGone: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var expenses: [Expense]

    @State private var linkingId: UUID?
    @State private var errorText: String?

    private var candidates: [Expense] {
        TransactionMatcher.expenseCandidates(for: transaction, expenses: expenses,
                                             me: env.currentUser?.identifier)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.details)
                            Text(transaction.date.dateOnly()).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(transaction.amount.formatted(.currency(code: transaction.currency)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                } footer: {
                    Text("Link an existing expense this transaction paid for, so it isn't double-counted.")
                }
                Section("Suggested Expenses") {
                    if candidates.isEmpty {
                        Text("No close expense matches.").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { expense in
                        Button { link(expense) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(expense.details)
                                    Text(expense.date.dateOnly())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if linkingId == expense.id {
                                    ProgressView()
                                } else {
                                    Text(expense.amount.formatted(.currency(code: expense.currency)))
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                        .disabled(linkingId != nil)
                    }
                }
            }
            .navigationTitle("Link an Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .errorAlert($errorText)
        }
    }

    private func link(_ expense: Expense) {
        linkingId = expense.id
        Task {
            defer { linkingId = nil }
            do {
                try await env.expenses(context).linkTransaction(expenseId: expense.id,
                                                                transactionId: transaction.id)
                dismiss()
            } catch {
                if transaction.pending, (error as? BackendError) == .notFound {
                    onTransactionGone()
                    dismiss()
                } else { errorText = errorMessage(error) }
            }
        }
    }
}
