import SwiftUI
import SwiftData

/// "Link a transaction" for an expense: on-device ranked suggestions (heuristic, re-ranked by Apple
/// Intelligence when available) plus a searchable browse of all transactions. Picking one links it so
/// spending counts your share of the expense once instead of both it and the gross transaction.
struct TransactionLinkView: View {
    let expense: Expense

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var expenses: [Expense]

    @State private var model = TransactionMatchModel()
    @State private var search = ""
    @State private var linkingId: UUID?
    @State private var errorText: String?

    private var browseResults: [Transaction] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(transactions.prefix(50)) }
        return transactions.filter { $0.details.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(expense.details)
                            Text(expense.date.dateOnly()).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(expense.amount.formatted(.currency(code: expense.currency)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                } footer: {
                    Text("Link the bank payment for this expense to de-duplicate it in your spending.")
                }

                Section {
                    if model.isRanking {
                        HStack { ProgressView(); Text("Finding matches…").foregroundStyle(.secondary) }
                    } else if model.candidates.isEmpty {
                        Text("No close matches — pick one below.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, match in
                            row(match.transaction, confidence: TransactionMatcher.confidenceLabel(match.score),
                                reason: index == 0 ? model.topReason : "")
                        }
                    }
                } header: {
                    HStack {
                        Text("Suggested")
                        if model.usedAppleIntelligence {
                            Image(systemName: "sparkles").foregroundStyle(.tint)
                        }
                    }
                }

                Section("All Transactions") {
                    if browseResults.isEmpty {
                        Text("No transactions found.").foregroundStyle(.secondary)
                    }
                    ForEach(browseResults) { row($0, confidence: nil, reason: "") }
                }
            }
            .navigationTitle("Link a Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search transactions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                await model.load(expense: expense, transactions: transactions,
                                 expenses: expenses, me: env.currentUser?.identifier)
            }
            .errorAlert($errorText)
        }
    }

    @ViewBuilder
    private func row(_ t: Transaction, confidence: String?, reason: String) -> some View {
        Button { link(t) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.details).foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(t.date.dateOnly())
                        if let confidence { Text("· \(confidence)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if !reason.isEmpty {
                        Text(reason).font(.caption2).foregroundStyle(.tint)
                    }
                }
                Spacer()
                if linkingId == t.id {
                    ProgressView()
                } else {
                    Text(t.amount.formatted(.currency(code: t.currency)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .disabled(linkingId != nil)
    }

    private func link(_ t: Transaction) {
        linkingId = t.id
        Task {
            defer { linkingId = nil }
            do {
                try await env.expenses(context).linkTransaction(expenseId: expense.id, transactionId: t.id)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}
