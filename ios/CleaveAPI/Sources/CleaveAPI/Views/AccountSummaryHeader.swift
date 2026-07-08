import SwiftUI

extension AccountKind {
    /// Tint for an account's balance, by kind: cash-flow assets green, liabilities red (money owed),
    /// holdings indigo.
    var balanceColor: Color {
        switch self {
        case .cashFlow: return .green
        case .liability: return .red
        case .holdings: return .indigo
        }
    }
}

/// Summary header at the top of an account's transaction list. Three variants by `AccountKind`:
/// cash-flow (money in vs sent this month), liability (spent this month + pending), and holdings
/// (minimal - balance, type, last synced only). All variants share name (the nav title), type,
/// current balance, and last-synced.
struct AccountSummaryHeader: View {
    let account: Account
    let transactions: [Transaction]

    private var kind: AccountKind { account.kind }
    private var code: String { account.currency }

    private var monthTransactions: [Transaction] {
        transactions.filter { Calendar.current.isDate($0.date, equalTo: .now, toGranularity: .month) }
    }
    // Sign convention: positive = money out (spent/sent), negative = money in.
    private var sentThisMonth: Decimal { monthTransactions.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount } }
    private var inThisMonth: Decimal { monthTransactions.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount } }
    private var pending: [Transaction] { transactions.filter(\.pending) }
    private var pendingTotal: Decimal { pending.reduce(0) { $0 + max($1.amount, 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .liability ? "Balance owed" : "Current balance")
                    .font(.caption).foregroundStyle(.secondary)
                Text(account.balance.formatted(.currency(code: code)))
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(kind == .liability ? .red : .primary)
                Text("\(typeLabel) · Updated \(account.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            switch kind {
            case .cashFlow:
                HStack(spacing: 24) {
                    stat("In this month", inThisMonth.formatted(.currency(code: code)), .green)
                    stat("Sent this month", sentThisMonth.formatted(.currency(code: code)), .primary)
                }
            case .liability:
                HStack(spacing: 24) {
                    stat("Spent this month", sentThisMonth.formatted(.currency(code: code)), .primary)
                    if let available = account.availableBalance {
                        stat("Available credit", available.formatted(.currency(code: code)), .green)
                    }
                    if !pending.isEmpty {
                        stat("Pending", "\(pending.count) · \(pendingTotal.formatted(.currency(code: code)))", .orange)
                    }
                }
            case .holdings:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var typeLabel: String { account.kind.label }

    @ViewBuilder
    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).fontWeight(.medium).foregroundStyle(color).monospacedDigit()
        }
    }
}
