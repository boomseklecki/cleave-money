import SwiftUI
import SwiftData

/// Confirmation before accepting a "Split" suggestion - a recent unlinked charge matching a learned split
/// template. Previews the shared expense it will create (charge, group, category, and who owes what) so the
/// user opts in deliberately, since this is the one Inbox accept that *creates* an expense. `onConfirm`
/// performs the accept (InboxView → `SuggestionService.acceptRecurringSplit`: creates the expense + links the
/// transaction).
struct RecurringSplitConfirmSheet: View {
    let suggestion: Suggestion
    let onConfirm: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var transaction: Transaction?
    @State private var template: SplitTemplate?
    @State private var groupName: String?
    @State private var directory: [User] = []

    private var me: String? { env.currentUser?.identifier }

    private struct OwedShare: Identifiable { let uid: String; let amount: Decimal; var id: String { uid } }

    /// The owed split computed from the template fractions over the charge amount - the same math the accept
    /// uses (`SuggestionService.distribute`), so the preview matches exactly (remainder to the largest share).
    private var owed: [OwedShare] {
        guard let transaction, let template else { return [] }
        return SuggestionService.distribute(transaction.amount, fractions: template.shares)
            .map { OwedShare(uid: $0.0, amount: $0.1) }
    }

    private func name(_ uid: String) -> String { uid == me ? "You" : directory.displayName(for: uid) }

    var body: some View {
        NavigationStack {
            List {
                if let transaction, let template {
                    Section {
                        NavigationLink {
                            LazyView(TransactionDetailView(transaction: transaction))
                        } label: {
                            SuggestionRecordRow(
                                title: transaction.details, amount: transaction.amount,
                                currency: transaction.currency, date: transaction.date,
                                category: template.category, source: groupName, sourceIcon: "person.2")
                        }
                    }
                    Section {
                        // You front the charge (the accept sets your paidShare to the full amount); everyone
                        // (incl. you) owes their share.
                        LabeledContent("Paid by You",
                                       value: transaction.amount.formatted(.currency(code: transaction.currency)))
                        ForEach(owed) { row in
                            LabeledContent(name(row.uid),
                                           value: row.amount.formatted(.currency(code: transaction.currency)))
                        }
                    } header: {
                        Text("Split")
                    } footer: {
                        Text("Creates a shared expense\(groupName.map { " in \($0)" } ?? "") and links this "
                             + "transaction — like last time.")
                    }
                } else {
                    Section { Text("This suggestion is no longer available.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Confirm Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(suggestion.acceptLabel) { onConfirm(); dismiss() }
                        .disabled(transaction == nil || template == nil)
                }
            }
            .task { resolve() }
        }
    }

    private func resolve() {
        if let tid = suggestion.transactionId {
            transaction = (try? context.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == tid })))?.first
        }
        if let key = suggestion.templateMerchantKey {
            template = (try? context.fetch(
                FetchDescriptor<SplitTemplate>(predicate: #Predicate { $0.merchantKey == key })))?.first
        }
        if let gid = template?.groupId {
            groupName = (try? context.fetch(
                FetchDescriptor<ExpenseGroup>(predicate: #Predicate { $0.id == gid })))?.first?.name
        }
        directory = (try? context.fetch(FetchDescriptor<User>())) ?? []
    }
}
