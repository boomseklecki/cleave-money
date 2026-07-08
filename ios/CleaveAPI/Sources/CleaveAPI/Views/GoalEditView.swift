import SwiftUI
import SwiftData

/// Create or edit a goal. Budget goals track a canonical category's monthly spend; savings goals track
/// a Plaid account's balance toward a target (reach a balance, or save an amount), snapshotting the
/// starting balance at creation.
struct GoalEditView: View {
    let editing: Goal?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]

    @State private var kind: GoalKind
    @State private var name: String
    @State private var category: String?
    @State private var accountId: UUID?
    @State private var amountString: String
    @State private var saveType: SaveTargetType
    @State private var shared: Bool
    @State private var showingCategoryPicker = false
    @State private var saving = false
    @State private var errorText: String?

    /// `editing` drives an edit; otherwise `prefill*` preset a new (spend) goal - used by the inbox's
    /// "shared budget candidate" card to land in the editor with the category/amount/shared filled in.
    init(editing: Goal? = nil, prefillCategory: String? = nil, prefillAmount: Decimal? = nil,
         prefillShared: Bool = false) {
        self.editing = editing
        _kind = State(initialValue: editing?.goalKind ?? .spend)
        _name = State(initialValue: editing?.name ?? "")
        _category = State(initialValue: editing?.category ?? prefillCategory)
        _accountId = State(initialValue: editing?.accountId)
        _amountString = State(initialValue: editing.map { Mapping.decimalString($0.targetAmount) }
            ?? prefillAmount.map(Mapping.decimalString) ?? "")
        _saveType = State(initialValue: editing?.saveTarget ?? .balance)
        _shared = State(initialValue: editing?.shared ?? prefillShared)
    }

    private var amount: Decimal { Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
    private var plaidAccounts: [Account] {
        accounts.filter { $0.plaidAccountId != nil }.sorted { $0.displayLabel < $1.displayLabel }
    }
    private var selectedAccount: Account? { accountId.flatMap { id in accounts.first { $0.id == id } } }
    private var canSave: Bool {
        guard amount > 0, !saving else { return false }
        return kind == .spend ? (category != nil) : (accountId != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Budget").tag(GoalKind.spend)
                        Text("Savings").tag(GoalKind.save)
                    }
                    .pickerStyle(.segmented)
                    .disabled(editing != nil)  // don't let an existing goal switch kind
                }

                if kind == .spend {
                    Section("Budget") {
                        Button { showingCategoryPicker = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: categorySymbol(category))
                                    .foregroundStyle(categoryColor(category)).frame(width: 28)
                                Text(category ?? "Choose a category")
                                    .foregroundStyle(category == nil ? .secondary : .primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        amountField(label: "Monthly limit")
                    }
                } else {
                    Section("Savings") {
                        Picker("Account", selection: $accountId) {
                            Text("Choose an account").tag(UUID?.none)
                            ForEach(plaidAccounts) { Text($0.displayLabel).tag(UUID?.some($0.id)) }
                        }
                        Picker("Target", selection: $saveType) {
                            Text("Reach a balance").tag(SaveTargetType.balance)
                            Text("Save an amount").tag(SaveTargetType.amount)
                        }
                        .pickerStyle(.segmented)
                        amountField(label: saveType == .balance ? "Target balance" : "Amount to save")
                        if let account = selectedAccount {
                            Text("Current balance \(account.balance.formatted(.currency(code: account.currency)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Name") {
                    TextField(defaultName, text: $name)
                }

                Section {
                    Toggle("Share with partner", isOn: $shared)
                } footer: {
                    Text("Connected partners see this goal read-only.")
                }
            }
            .navigationTitle(editing == nil ? "New Goal" : "Edit Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .sheet(isPresented: $showingCategoryPicker) {
                CategoryPickerView(current: category) { category = $0 }
            }
            .errorAlert($errorText)
        }
    }

    private func amountField(label: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("0.00", text: $amountString)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110)
        }
    }

    /// The name used when the field is left blank.
    private var defaultName: String {
        if kind == .spend { return category ?? "Budget" }
        return selectedAccount?.displayLabel ?? "Savings goal"
    }

    private func save() {
        saving = true
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name
        // Snapshot the starting balance for a new savings goal; preserve it when editing.
        let startingBalance: Decimal? = kind == .save
            ? (editing?.startingBalance ?? selectedAccount?.balance ?? 0) : nil
        let startingDate: Date? = kind == .save ? (editing?.startingDate ?? Date()) : nil
        let draft = GoalDraft(
            kind: kind,
            name: finalName,
            category: kind == .spend ? category : nil,
            accountId: kind == .save ? accountId : nil,
            targetAmount: amount,
            saveTargetType: kind == .save ? saveType : nil,
            startingBalance: startingBalance,
            startingDate: startingDate,
            shared: shared
        )
        Task {
            defer { saving = false }
            do {
                if let editing {
                    try await env.goals(context).update(id: editing.id, draft)
                } else {
                    _ = try await env.goals(context).create(draft)
                }
                dismiss()
            } catch {
                errorText = errorMessage(error)
            }
        }
    }
}
