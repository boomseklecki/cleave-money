import SwiftUI

/// Create a manual account (cash, or a card/loan you track by hand). The create endpoint takes a Plaid-style
/// `type`; we send the chosen kind's representative subtype so the account classifies into the right bucket.
struct NewAccountView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: AccountKind = .cashFlow
    @State private var balanceString = ""
    @State private var currency = "USD"
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(AccountKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    TextField("Starting balance", text: $balanceString).keyboardType(.decimalPad)
                    TextField("Currency", text: $currency).textInputAutocapitalization(.characters)
                } footer: {
                    Text("Optional. For a liability (card/loan), the balance is what you owe.")
                }
            }
            .navigationTitle("New Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .errorAlert($errorText)
        }
    }

    private func save() {
        saving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let balance = Decimal(string: balanceString.trimmingCharacters(in: .whitespaces)) ?? 0
        let cur = currency.trimmingCharacters(in: .whitespaces)
        Task {
            defer { saving = false }
            do {
                try await env.accounts(context).createAccount(
                    name: trimmedName, type: kind.representativeSubtype, balance: balance,
                    currency: cur.isEmpty ? nil : cur)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}
