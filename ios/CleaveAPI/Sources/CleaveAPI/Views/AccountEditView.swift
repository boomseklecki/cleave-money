import SwiftUI
import SwiftData

/// Manage a single account: rename it, set its type (Cash flow / Liability / Savings), and choose
/// whether it counts toward spending and cash flow. No transaction list - that lives on the Accounts
/// tab. Reached from Settings → Plaid → Linked Banks → an account. Overrides persist server-side and
/// survive a Plaid re-sync.
struct AccountEditView: View {
    let account: Account

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var kind: AccountKind
    @State private var includeInSpending: Bool
    @State private var includeInCashFlow: Bool
    @State private var shareLevel: AccountShareLevel
    @State private var saving = false
    @State private var errorText: String?

    init(account: Account) {
        self.account = account
        _displayName = State(initialValue: account.displayName ?? "")
        _kind = State(initialValue: account.kind)
        _includeInSpending = State(initialValue: account.countsInSpending)
        _includeInCashFlow = State(initialValue: account.countsInCashFlow)
        _shareLevel = State(initialValue: account.shareLevelValue)
    }

    var body: some View {
        Form {
            if account.institutionName != nil || account.institutionLogoURL != nil {
                Section("Institution") {
                    HStack(spacing: 12) {
                        AvatarView(url: account.institutionLogoURL,
                                   name: account.institutionName ?? account.name, size: 56,
                                   systemImage: "building.columns", logo: true)
                        Text(account.institutionName ?? "Bank").fontWeight(.medium)
                        Spacer()
                        if let color = Color(hex: account.institutionColor) {
                            RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 18, height: 18)
                        }
                    }
                    if let domain = account.institutionDomain, !domain.isEmpty,
                       let url = URL(string: "https://\(domain)") {
                        Link(destination: url) { Label(domain, systemImage: "safari") }
                    }
                    if let status = statusText {
                        LabeledContent("Status") {
                            HStack(spacing: 6) {
                                Circle().fill(statusColor).frame(width: 8, height: 8)
                                Text(status)
                            }
                        }
                    }
                    LabeledContent("Updated", value: account.updatedAt.relativeUpdated)
                }
            }

            Section {
                TextField(account.name, text: $displayName)
                    .autocorrectionDisabled()
            } header: {
                Text("Display Name")
            } footer: {
                Text("Shown throughout the app. Leave blank to use the bank's name (\(account.name))."
                     + (account.maskLabel.map { " Account \($0)." } ?? ""))
            }

            Section {
                Picker("Type", selection: $kind) {
                    ForEach(AccountKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
            } header: {
                Text("Type")
            } footer: {
                Text("Sets how the balance is colored and the default for the toggles below. "
                     + "Savings accounts are excluded from spending and cash flow by default.")
            }

            Section("Goals") {
                Toggle("Include in spending", isOn: $includeInSpending)
                Toggle("Include in cash flow", isOn: $includeInCashFlow)
            }

            Section {
                Picker("Share with partner", selection: $shareLevel) {
                    ForEach(AccountShareLevel.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Sharing")
            } footer: {
                Text("Partners you've connected with see this account based on your choice: nothing when "
                     + "private, the balance only, or the balance plus its transactions.")
            }

            Section {
                LabeledContent("Balance",
                               value: account.balance.formatted(.currency(code: account.currency)))
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(saving)
            }
        }
        .errorAlert($errorText)
    }

    /// Plaid connection status, humanized (nil when unknown).
    private var statusText: String? {
        switch account.institutionStatus?.uppercased() {
        case "HEALTHY": return "Healthy"
        case "DEGRADED": return "Degraded"
        case "DOWN": return "Down"
        case let other?: return other.capitalized
        default: return nil
        }
    }

    private var statusColor: Color {
        switch account.institutionStatus?.uppercased() {
        case "HEALTHY": return .green
        case "DEGRADED": return .orange
        case "DOWN": return .red
        default: return .secondary
        }
    }

    private func save() {
        saving = true
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { saving = false }
            do {
                // Empty display name resets to the Plaid name (the backend normalizes "" → null). The
                // include flags are pinned to the toggles' current values.
                try await env.accounts(context).update(
                    id: account.id, displayName: name, kind: kind.canonical,
                    includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow,
                    shareLevel: shareLevel.rawValue)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}
