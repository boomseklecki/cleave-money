import SwiftUI
import SwiftData

/// Create or edit an expense with split entry. The ±0.01 balance check is enforced client-side only
/// for self-hosted groups; Splitwise groups defer to Splitwise (the backend pushes on save).
struct ExpenseEditView: View {
    enum SplitMode: String, CaseIterable {
        case equal = "Equal"
        case exact = "Exact"
        case percentage = "Percent"
        case shares = "Shares"
        case adjustment = "+/−"
        case reimbursement = "Reimburse"
        case itemized = "Items"
        case settleUp = "Settle Up"
    }

    let editing: Expense?
    let attachImageData: Data?
    /// When a *create* fails because the source transaction no longer exists server-side (a pending charge
    /// that posted), the caller handles it (e.g. raises the "already posted" prompt) instead of a generic
    /// error. Only set by the from-transaction flow; nil everywhere else.
    let onCreateTransactionGone: (() -> Void)?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var users: [User]
    @Query(filter: #Predicate<ExpenseGroup> { $0.supersededAt == nil && $0.hidden == false },
           sort: \ExpenseGroup.name)
    private var groups: [ExpenseGroup]
    @Query private var allMembers: [GroupMember]
    @Query private var balanceRows: [GroupBalance]
    @Query(sort: \SpendCategory.position) private var spendCategories: [SpendCategory]

    @State private var myNets: [UUID: Decimal] = [:]
    @State private var lastExpense: [UUID: GroupSummary.Last] = [:]

    @State private var group: ExpenseGroup
    @State private var details: String
    @State private var amountString: String
    @State private var date: Date
    @State private var category: String?
    @State private var notes: String
    @State private var payer: String
    @State private var multiPayer: Bool
    @State private var paidBy: [String: String]
    @State private var settleUpTo: String
    @State private var mode: SplitMode = .equal
    @State private var customOwed: [String: String]
    @State private var percents: [String: String] = [:]
    @State private var shareCounts: [String: String] = [:]
    @State private var adjustments: [String: String] = [:]
    @State private var participants: [String]
    @State private var items: [ItemDraft]
    @State private var transactionId: UUID?
    @State private var categoryTarget: CategoryTarget?
    @State private var categorizingItems = false
    @State private var categorizingExpense = false
    @State private var saving = false
    @State private var errorText: String?
    /// Minted once per editor instance so every Save retry of THIS new expense sends the same
    /// Idempotency-Key - a re-tap or retry-after-timeout dedups to one row server-side (only used on create).
    @State private var idempotencyKey = UUID().uuidString

    /// Which category the picker is editing - the expense's, or a line item's (by index).
    private enum CategoryTarget: Identifiable {
        case expense, item(Int)
        var id: String { switch self { case .expense: "expense"; case let .item(i): "item-\(i)" } }
    }

    init(group: ExpenseGroup, members: [String], editing: Expense? = nil,
         prefill: ExpensePrefill? = nil, attachImageData: Data? = nil,
         onCreateTransactionGone: (() -> Void)? = nil) {
        self.editing = editing
        self.attachImageData = attachImageData
        self.onCreateTransactionGone = onCreateTransactionGone
        _group = State(initialValue: group)
        let people = members.isEmpty ? (editing?.splits.map(\.userIdentifier) ?? []) : members
        _participants = State(initialValue: people)
        _details = State(initialValue: editing?.details ?? prefill?.details ?? "")
        let seedAmount = editing.map(\.amount) ?? prefill?.amount
        _amountString = State(initialValue: seedAmount.map(Mapping.decimalString) ?? "")
        _date = State(initialValue: editing?.date ?? prefill?.date ?? Date())
        _category = State(initialValue: editing?.category ?? prefill?.category)
        _notes = State(initialValue: editing?.notes ?? "")
        let payingSplits = (editing?.splits ?? []).filter { $0.paidShare > 0 }
        _payer = State(initialValue: payingSplits.first?.userIdentifier ?? people.first ?? "")
        _multiPayer = State(initialValue: payingSplits.count > 1)
        var paid: [String: String] = [:]
        for split in payingSplits { paid[split.userIdentifier] = Mapping.decimalString(split.paidShare) }
        _paidBy = State(initialValue: paid)
        // Settle-up: the recipient is the participant who owes (paid nothing).
        let settleTo = editing?.splits.first { $0.owedShare > 0 && $0.paidShare == 0 }?.userIdentifier
        _settleUpTo = State(initialValue: settleTo ?? people.first { $0 != payingSplits.first?.userIdentifier } ?? "")
        var owed: [String: String] = [:]
        for split in editing?.splits ?? [] { owed[split.userIdentifier] = Mapping.decimalString(split.owedShare) }
        _customOwed = State(initialValue: owed)
        let existingItems = editing?.items.map {
            ItemDraft(id: $0.id, name: $0.name, quantity: $0.quantity, price: $0.price,
                      category: $0.category, owner: $0.ownerIdentifier)
        } ?? []
        let seedItems = existingItems + (prefill?.items ?? [])
        _items = State(initialValue: seedItems)
        _transactionId = State(initialValue: editing?.transactionId ?? prefill?.transactionId)
        // Preserve a stored split when editing (Reimbursement / Settle-up if marked, else Exact); new
        // expenses start on Equal.
        let editingMode: SplitMode
        if editing?.category == Reimbursement.category { editingMode = .reimbursement }
        else if editing?.category == SettleUp.category { editingMode = .settleUp }
        else { editingMode = .exact }
        _mode = State(initialValue: editing == nil ? .equal : editingMode)
    }

    private var amount: Decimal { Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
    private var isSelfHosted: Bool { group.backendType == .selfHosted }

    /// Groups the expense can be moved to (new expenses only). Same filtered/sorted list the
    /// transaction→expense picker uses (settled hidden, recent-activity first), with the current
    /// group always kept so it shows even when it would otherwise be filtered out.
    private var selectableGroups: [ExpenseGroup] {
        var list = GroupSummary.visible(groups, myNets: myNets, lastExpense: lastExpense, includeSettled: false)
        if !list.contains(where: { $0.id == group.id }) { list.insert(group, at: 0) }
        return list
    }

    /// Reimbursement is self-hosted only: it relies on a local "Reimbursement" marker + inverted shares
    /// that Splitwise can't represent and that's lost when an expense round-trips through Splitwise.
    private var availableModes: [SplitMode] {
        isSelfHosted ? SplitMode.allCases : SplitMode.allCases.filter { $0 != .reimbursement }
    }

    private func displayName(_ identifier: String) -> String { users.displayName(for: identifier) }
    /// "you" for the current user, otherwise the person's display name (for the compact payer button).
    private var payerLabel: String {
        if multiPayer { return "multiple" }
        return payer == env.currentUser?.identifier ? "you" : displayName(payer)
    }

    private func decimal(_ string: String?) -> Decimal {
        // Tolerate a leading "+" (the adjustment field's placeholder invites it) - Decimal(string:)
        // returns nil for "+6", which would silently drop the adjustment.
        var text = (string ?? "").trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+") { text.removeFirst() }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }
    private func numeric(_ map: [String: String]) -> [String: Decimal] {
        map.reduce(into: [:]) { $0[$1.key] = decimal($1.value) }
    }
    /// Per-person total of the line items assigned to them (itemized mode).
    private var assignedItemTotals: [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for item in items {
            if let owner = item.owner { totals[owner, default: 0] += item.price }
        }
        return totals
    }

    /// Who paid how much: the multi-payer map, or the single payer for the whole amount.
    private var paidShares: [String: Decimal] {
        multiPayer ? numeric(paidBy) : [payer: amount]
    }

    /// A settle-up is a one-way payment: the payer paid, the recipient owes it back.
    private var settleUpSplits: [SplitDraft] {
        [SplitDraft(userIdentifier: payer, paidShare: amount, owedShare: 0),
         SplitDraft(userIdentifier: settleUpTo, paidShare: 0, owedShare: amount)]
    }

    /// Owed shares per participant for the current split mode (paid shares are layered on separately).
    private var owedDrafts: [SplitDraft] {
        let nominal = participants.first ?? payer  // SplitMath needs a payer for paid, which we override
        switch mode {
        case .equal:
            return SplitMath.equalSplit(amount: amount, payer: nominal, participants: participants)
        case .exact:
            return participants.map { SplitDraft(userIdentifier: $0, paidShare: 0, owedShare: decimal(customOwed[$0])) }
        case .percentage:
            return SplitMath.weightedSplit(amount: amount, payer: nominal, participants: participants, weights: numeric(percents))
        case .shares:
            return SplitMath.weightedSplit(amount: amount, payer: nominal, participants: participants, weights: numeric(shareCounts))
        case .adjustment:
            return SplitMath.adjustmentSplit(amount: amount, payer: nominal, participants: participants, adjustments: numeric(adjustments))
        case .itemized:
            return SplitMath.itemizedSplit(amount: amount, payer: nominal, participants: participants, assigned: assignedItemTotals)
        case .reimbursement, .settleUp:
            return []  // handled in `splits`
        }
    }

    private var splits: [SplitDraft] {
        switch mode {
        case .reimbursement:
            return SplitMath.reimbursementSplit(amount: amount, payer: payer, participants: participants)
        case .settleUp:
            return settleUpSplits
        default:
            // Owed from the mode; paid from the (multi-)payer map.
            return owedDrafts.map { draft in
                SplitDraft(userIdentifier: draft.userIdentifier,
                           paidShare: paidShares[draft.userIdentifier] ?? 0,
                           owedShare: draft.owedShare)
            }
        }
    }

    private func owed(_ person: String) -> Decimal {
        splits.first { $0.userIdentifier == person }?.owedShare ?? 0
    }
    private func owedText(_ person: String) -> String {
        owed(person).formatted(.currency(code: "USD"))
    }
    /// Each person's equal share of the reimbursement ("gets back $50") - the per-person split, shown
    /// like the owed amount in every other mode. (The gross the recipient received is a detail-view
    /// concern, not the editor's.)
    private func reimbursementGetsBackText(_ person: String) -> String {
        let value = splits.first { $0.userIdentifier == person }?.paidShare ?? 0
        return "gets back " + value.formatted(.currency(code: "USD"))
    }

    private func entry(_ map: Binding<[String: String]>, _ key: String) -> Binding<String> {
        Binding(get: { map.wrappedValue[key, default: ""] }, set: { map.wrappedValue[key] = $0 })
    }

    /// One editable line item: name, price, a category capsule, and (itemized mode) an owner picker.
    @ViewBuilder
    private func itemRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Item", text: itemBinding(index, \.name))
                Spacer()
                Text("$").foregroundStyle(.secondary)
                TextField("0.00", text: itemPriceBinding(index))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
            }
            HStack(spacing: 12) {
                Button { categoryTarget = .item(index) } label: {
                    let category = items.indices.contains(index) ? items[index].category : nil
                    HStack(spacing: 4) {
                        Image(systemName: categorySymbol(category)).font(.caption)
                        Text(category ?? "Category").font(.caption)
                            .foregroundStyle(category == nil ? .secondary : .primary)
                    }
                }
                .buttonStyle(.borderless)
                Spacer()
                if mode == .itemized && isSelfHosted {  // item ownership is local-only (won't drift from Splitwise splits)
                    Picker("Assigned to", selection: itemOwnerBinding(index)) {
                        Text("Shared").tag("")
                        ForEach(participants, id: \.self) { Text(displayName($0)).tag($0) }
                    }
                    .labelsHidden().font(.caption)
                }
            }
        }
    }

    private func itemBinding(_ index: Int, _ keyPath: WritableKeyPath<ItemDraft, String>) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) ? items[index][keyPath: keyPath] : "" },
            set: { if items.indices.contains(index) { items[index][keyPath: keyPath] = $0 } }
        )
    }
    private func itemPriceBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) && items[index].price != 0 ? Mapping.decimalString(items[index].price) : "" },
            set: { if items.indices.contains(index) { items[index].price = decimal($0) } }
        )
    }
    private func itemOwnerBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) ? (items[index].owner ?? "") : "" },
            set: { if items.indices.contains(index) { items[index].owner = $0.isEmpty ? nil : $0 } }
        )
    }

    /// On-device categorization of named line items by their name (Apple Intelligence).
    private func categorizeItems() async {
        categorizingItems = true
        defer { categorizingItems = false }
        var idToIndex: [UUID: Int] = [:]
        var mapperItems: [CategoryMapper.Item] = []
        for (index, item) in items.enumerated() where !item.name.isEmpty {
            let tempId = UUID()
            idToIndex[tempId] = index
            mapperItems.append(.init(id: tempId, description: item.name, rawCategory: item.category,
                                     current: nil, note: editing?.note))
        }
        let refined = await CategoryMapper.refine(mapperItems, allowed: spendCategories.map(\.name))
        for (id, category) in refined {
            if let index = idToIndex[id], items.indices.contains(index) { items[index].category = category }
        }
    }

    /// Categorize the expense from its description (appears once a description is typed). Anchored on the
    /// current pick so `refine` only changes a set category when clearly more accurate; an unset one is
    /// classified. Expenses have a single `category` field (no AI-provenance badge, unlike transactions).
    private func categorizeExpense() async {
        categorizingExpense = true
        defer { categorizingExpense = false }
        let id = UUID()
        let item = CategoryMapper.Item(id: id, description: details, rawCategory: nil, current: category,
                                       note: editing?.note)
        let result = await CategoryMapper.refine([item], allowed: spendCategories.map(\.name))
        if let picked = result[id] { category = picked }
    }

    /// The trailing input for one participant, per split mode. Computed-only modes show the owed amount.
    @ViewBuilder
    private func splitInput(_ person: String) -> some View {
        switch mode {
        case .equal, .itemized, .settleUp:
            Text(owedText(person)).foregroundStyle(.secondary)
        case .reimbursement:
            Text(reimbursementGetsBackText(person)).foregroundStyle(.secondary)
        case .exact:
            TextField("0.00", text: entry($customOwed, person))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        case .percentage:
            HStack(spacing: 4) {
                TextField("0", text: entry($percents, person))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 48)
                Text("%").foregroundStyle(.secondary)
                Text(owedText(person)).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
        case .shares:
            HStack(spacing: 8) {
                TextField("0", text: entry($shareCounts, person))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 40)
                Text(owedText(person)).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
        case .adjustment:
            HStack(spacing: 8) {
                TextField("+0.00", text: entry($adjustments, person))
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(width: 64)
                Text(owedText(person)).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }

    private var balanced: Bool { SplitMath.isBalanced(amount: amount, splits: splits) }
    private var paidBalanced: Bool { abs(SplitMath.paidSum(splits) - amount) <= SplitMath.tolerance }
    private var canSave: Bool {
        guard amount > 0, !saving else { return false }
        if mode == .settleUp {
            return !payer.isEmpty && !settleUpTo.isEmpty && payer != settleUpTo
        }
        return !details.trimmingCharacters(in: .whitespaces).isEmpty && !payer.isEmpty
            && (!isSelfHosted || balanced)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); groupSelector; Spacer() }
                        .listRowBackground(Color.clear)
                }

                Section {
                    HStack(spacing: 12) {
                        if mode != .reimbursement && mode != .settleUp {
                            Button { categoryTarget = .expense } label: {
                                Image(systemName: categorySymbol(category))
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(.quaternary))
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("Description", text: $details)
                            .font(.title3)
                        if mode != .reimbursement && mode != .settleUp
                            && CategoryMapper.isAvailable && !details.isEmpty {
                            AICategorizeButton(running: categorizingExpense) {
                                Task { await categorizeExpense() }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Text("$").font(.title2).foregroundStyle(.secondary)
                        TextField("0.00", text: $amountString)
                            .keyboardType(.decimalPad).font(.title2)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                if mode != .reimbursement && mode != .settleUp {
                    Section {
                        ForEach(items.indices, id: \.self) { index in itemRow(index) }
                            .onDelete { items.remove(atOffsets: $0) }
                        Button { items.append(ItemDraft(name: "", price: 0)) } label: {
                            Label("Add Item", systemImage: "plus")
                        }
                    } header: {
                        HStack {
                            Text("Line Items")
                            Spacer()
                            if CategoryMapper.isAvailable && items.contains(where: { !$0.name.isEmpty }) {
                                AICategorizeButton(running: categorizingItems) {
                                    Task { await categorizeItems() }
                                }
                            }
                        }
                    }
                }

                if multiPayer && mode != .reimbursement && mode != .settleUp {
                    Section("Paid by") {
                        ForEach(participants, id: \.self) { person in
                            HStack {
                                Text(displayName(person))
                                Spacer()
                                TextField("0.00", text: entry($paidBy, person))
                                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            }
                        }
                        Label(
                            paidBalanced ? "Paid \(amount.formatted(.currency(code: "USD")))"
                                : "Paid \(SplitMath.paidSum(splits).formatted(.currency(code: "USD"))) of \(amount.formatted(.currency(code: "USD")))",
                            systemImage: paidBalanced ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(paidBalanced ? .green : .orange)
                        Button("Single payer") { multiPayer = false }
                    }
                }

                Section(mode == .settleUp ? "Settle Up" : "Split") {
                    splitSentence

                    if mode == .settleUp {
                        Picker("From", selection: $payer) {
                            ForEach(participants, id: \.self) { Text(displayName($0)).tag($0) }
                        }
                        Picker("To", selection: $settleUpTo) {
                            ForEach(participants, id: \.self) { Text(displayName($0)).tag($0) }
                        }
                        if payer == settleUpTo {
                            Text("Pick two different people.").font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        if mode == .reimbursement {
                            Text("\(payerLabel.capitalized) was reimbursed the full amount and splits it equally — \(payerLabel) owes the others their share.")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        ForEach(participants, id: \.self) { person in
                            HStack {
                                Text(displayName(person))
                                Spacer()
                                splitInput(person)
                            }
                        }

                        if isSelfHosted {
                            Label(
                                balanced ? "Balanced" : "Off by \((amount - SplitMath.owedSum(splits)).formatted(.currency(code: "USD")))",
                                systemImage: balanced ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(balanced ? .green : .orange)
                        } else {
                            Text("Splitwise validates this split on save.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(editing == nil ? "New Expense" : "Edit Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .sheet(item: $categoryTarget) { target in
                switch target {
                case .expense:
                    CategoryPickerView(current: category) { category = $0 }
                case let .item(index):
                    if items.indices.contains(index) {
                        CategoryPickerView(current: items[index].category) { items[index].category = $0 }
                    }
                }
            }
            .task {
                guard editing == nil else { return }
                // A Splitwise group's members are only in the local cache after a member sync. If the
                // editor opened before that ran, `participants` (from the caller's member list) is empty
                // and you can't pick a payer or split. Sync the group's members and seed from its full
                // roster. Self-hosted groups already have their members cached, so this is a no-op there.
                try? await env.groups(context).refreshMembers(groupId: group.id)
                let gid = group.id
                let synced = ((try? context.fetch(
                    FetchDescriptor<GroupMember>(predicate: #Predicate { $0.groupId == gid }))) ?? [])
                    .map(\.userIdentifier).sorted()
                if !synced.isEmpty {
                    participants = synced
                    if !synced.contains(payer) { payer = synced.first ?? "" }
                    if settleUpTo.isEmpty || !synced.contains(settleUpTo) {
                        settleUpTo = synced.first { $0 != payer } ?? ""
                    }
                }
                // Default "Paid by" to you (from /me) when you're a participant.
                if let me = env.currentUser?.identifier, participants.contains(me) { payer = me }
                // Settled-filtering + activity sort for the group switcher (mirrors the transaction picker).
                myNets = GroupSummary.myNets(from: balanceRows, me: env.currentUser?.identifier)
                lastExpense = GroupSummary.lastExpenses(groups, myNets: myNets, includeSettled: false, context: context)
            }
            .errorAlert($errorText)
        }
    }

    /// Centered group avatar + name; a menu to switch groups when creating a new expense and more
    /// than one is available.
    @ViewBuilder
    private var groupSelector: some View {
        if editing == nil, selectableGroups.count > 1 {
            Menu {
                ForEach(selectableGroups, id: \.id) { g in
                    Button {
                        selectGroup(g)
                    } label: {
                        if g.id == group.id { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
                    }
                }
            } label: {
                groupLabel(chevron: true)
            }
        } else {
            groupLabel(chevron: false)
        }
    }

    private func groupLabel(chevron: Bool) -> some View {
        HStack(spacing: 8) {
            AvatarView(url: group.avatarURL, name: group.name, size: 28, systemImage: group.typeSymbol)
            Text(group.name).font(.headline)
            if chevron { Image(systemName: "chevron.up.chevron.down").font(.caption2) }
        }
    }

    /// "Paid by [you] and split [Equally]" with the payer and mode as tappable capsule buttons. For
    /// settle-up the payer/payee live in the From/To pickers below, so only the mode capsule shows.
    private var splitSentence: some View {
        HStack(spacing: 6) {
            if mode != .settleUp {
                Text(mode == .reimbursement ? "Reimbursed to" : "Paid by").foregroundStyle(.secondary)
                Menu {
                    ForEach(participants, id: \.self) { person in
                        Button(displayName(person)) { payer = person; multiPayer = false }
                    }
                    if participants.count > 1 && mode != .reimbursement {
                        Divider()
                        Button("Multiple people…") { enableMultiPayer() }
                    }
                } label: { capsule(payerLabel) }
                Text("and split").foregroundStyle(.secondary)
            }
            Menu {
                ForEach(availableModes, id: \.self) { m in
                    Button(m.rawValue) { selectMode(m) }
                }
            } label: { capsule(mode.rawValue) }
            Spacer(minLength: 0)
        }
    }

    private func enableMultiPayer() {
        if numeric(paidBy).values.reduce(0, +) == 0 { paidBy = [payer: amountString] }
        multiPayer = true
    }

    /// Switch split mode; reimbursement and settle-up are single-payer, so leave multi-payer entry.
    private func selectMode(_ m: SplitMode) {
        mode = m
        if m == .reimbursement || m == .settleUp { multiPayer = false }
        if m == .settleUp, settleUpTo.isEmpty || settleUpTo == payer {
            settleUpTo = participants.first { $0 != payer } ?? ""
        }
    }

    private func capsule(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }

    /// Move a new expense to another group: reset participants/payer to that group's members and clear
    /// the per-mode entry maps (they key on identifiers that no longer apply).
    private func selectGroup(_ g: ExpenseGroup) {
        group = g
        let gid = g.id
        let members = allMembers.filter { $0.groupId == gid }.map(\.userIdentifier).sorted()
        participants = members
        payer = (env.currentUser?.identifier).flatMap { members.contains($0) ? $0 : nil } ?? members.first ?? ""
        multiPayer = false; paidBy = [:]
        settleUpTo = members.first { $0 != payer } ?? ""
        customOwed = [:]; percents = [:]; shareCounts = [:]; adjustments = [:]
        for i in items.indices { items[i].owner = nil }  // owners key on the old group's members
        if !availableModes.contains(mode) { mode = .equal }
    }

    private func save() {
        saving = true
        let me = env.currentUser?.identifier
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedCategory: String?
        switch mode {
        case .reimbursement: savedCategory = Reimbursement.category
        case .settleUp: savedCategory = SettleUp.category
        default: savedCategory = category
        }
        // Settle-ups commonly have no description; give it a sensible default.
        let trimmedDetails = details.trimmingCharacters(in: .whitespaces)
        let savedDetails = (mode == .settleUp && trimmedDetails.isEmpty) ? "Settle up" : details
        let draft = ExpenseDraft(
            groupId: group.id, details: savedDetails, amount: amount,
            date: date, category: savedCategory,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            createdBy: editing == nil ? me : nil,
            updatedBy: editing != nil ? me : nil,
            transactionId: transactionId,
            splits: splits, items: items
        )
        Task {
            defer { saving = false }
            do {
                if let editing {
                    try await env.expenses(context).update(id: editing.id, draft)
                } else {
                    let newId = try await env.expenses(context).create(draft, idempotencyKey: idempotencyKey)
                    if let attachImageData {
                        try await env.receipts(context).upload(expenseId: newId, imageData: attachImageData)
                    }
                }
                dismiss()
            } catch {
                if let onCreateTransactionGone, editing == nil, (error as? BackendError) == .notFound {
                    onCreateTransactionGone(); dismiss()
                } else if (error as? BackendError) == .notFound {
                    // create/update 404s when something the expense refers to is gone - its group, or a linked
                    // transaction (e.g. a pending charge that posted as a new one). Give a reasonable, actionable
                    // message instead of the bare "Not found."
                    errorText = "Couldn’t \(editing == nil ? "create" : "save") this expense — something it "
                        + "refers to (its group or a linked transaction) no longer exists. "
                        + "Pull to refresh and try again."
                } else { errorText = errorMessage(error) }
            }
        }
    }
}
