import SwiftData
import SwiftUI

/// Confirmation before accepting a categorize suggestion - the on-device AI disagrees with a
/// transaction's current category. Shows the transaction and the current → chosen change, with a tappable
/// category avatar (the same affordance as Find Related Transactions) so the user can **correct** a wrong
/// guess before it becomes an override. `onConfirm` receives the chosen category (InboxView → setCategoryOverride).
struct CategorizeConfirmSheet: View {
    let suggestion: Suggestion
    let onConfirm: (String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var transactions: [Transaction] = []
    @State private var accountNames: [UUID: String] = [:]   // accountId → "Name •••• 1234"
    @State private var chosen: String?
    @State private var showingPicker = false

    init(suggestion: Suggestion, onConfirm: @escaping (String) -> Void) {
        self.suggestion = suggestion
        self.onConfirm = onConfirm
        _chosen = State(initialValue: suggestion.category)
    }

    var body: some View {
        NavigationStack {
            List {
                if !transactions.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Button { showingPicker = true } label: {
                                CategoryAvatar(category: chosen)
                            }
                            .buttonStyle(.plain)
                            Text(chosen ?? "Pick a category")
                                .font(.title3).fontWeight(.semibold)
                            Text("was \(suggestion.currentCategory ?? "Uncategorized")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    } footer: {
                        let n = transactions.count
                        let subject = n == 1 ? "this transaction" : "\(n) transactions"
                        Text(suggestion.userRule
                             ? "From your saved merchant rule. Sets the category on \(subject). Tap the icon to change it."
                             : "Sets the category on \(subject). Tap the icon to change it.")
                    }
                    Section("Transactions (\(transactions.count))") {
                        ForEach(transactions) { t in
                            NavigationLink {
                                LazyView(TransactionDetailView(transaction: t))
                            } label: {
                                SuggestionRecordRow(title: t.details, amount: t.amount,
                                                    currency: t.currency, date: t.date,
                                                    source: t.accountId.flatMap { accountNames[$0] },
                                                    sourceIcon: "building.columns")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Couldn’t load the transactions", systemImage: "questionmark.circle")
                }
            }
            .navigationTitle("Confirm Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Categorize") {
                        if let chosen { onConfirm(chosen); dismiss() }
                    }
                    .disabled(transactions.isEmpty || chosen == nil)
                }
            }
            .sheet(isPresented: $showingPicker) {
                CategoryPickerView(current: chosen, subject: suggestion.title) { chosen = $0 }
            }
            .task { resolve() }
        }
    }

    private func resolve() {
        let ids = suggestion.transactionIds.isEmpty
            ? [suggestion.transactionId].compactMap { $0 } : suggestion.transactionIds
        let idSet = Set(ids)
        let fetched = (try? context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { idSet.contains($0.id) }))) ?? []
        // Preserve the suggestion's order (newest-first from the engine).
        transactions = ids.compactMap { id in fetched.first { $0.id == id } }

        // Resolve each transaction's account (the rows may span accounts) so they read like the Link confirm.
        let accountIds = Set(transactions.compactMap(\.accountId))
        let accounts = (try? context.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { accountIds.contains($0.id) }))) ?? []
        accountNames = Dictionary(uniqueKeysWithValues: accounts.map { account in
            (account.id, [account.displayLabel, account.maskLabel].compactMap { $0 }.joined(separator: " "))
        })
    }
}
