import SwiftUI

/// Read-only view of a partner's full-shared account's transactions. Fetched LIVE on appear and held in
/// view state only - these rows are never written to SwiftData, so a partner's spending can't leak into
/// your own budgets/Trends/net-worth. Balances-only accounts never reach here (no drill-in).
struct SharedAccountTransactionsView: View {
    let account: Components.Schemas.AccountResponse

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @State private var transactions: [Components.Schemas.TransactionResponse] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Balance",
                               value: ((try? Mapping.decimal(account.balance, field: "balance")) ?? 0)
                                   .formatted(.currency(code: account.currency)))
                LabeledContent("Shared by", value: account.shared_by ?? "partner")
            }

            Section("Transactions") {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if transactions.isEmpty {
                    Text("No transactions.").foregroundStyle(.secondary)
                } else {
                    ForEach(transactions, id: \.id) { row($0) }
                }
            }
        }
        .navigationTitle(account.display_name ?? account.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .errorAlert($errorText)
    }

    @ViewBuilder
    private func row(_ t: Components.Schemas.TransactionResponse) -> some View {
        let amount = (try? Mapping.decimal(t.amount, field: "amount")) ?? 0
        let date = try? Mapping.dateOnly(t.date, field: "date")
        HStack(spacing: 12) {
            Image(systemName: categorySymbol(t.category))
                .foregroundStyle(categoryColor(t.category)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.description)
                HStack(spacing: 4) {
                    if let date { Text(date.dateOnly()) }
                    if let category = t.category { Text("· \(category)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(amount.formatted(.currency(code: t.currency)))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let id = try Mapping.uuid(account.id, field: "Account.id")
            transactions = try await env.accounts(context).fetchTransactions(accountId: id)
        } catch { errorText = errorMessage(error) }
    }
}
