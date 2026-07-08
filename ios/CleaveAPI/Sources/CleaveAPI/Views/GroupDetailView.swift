import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// One group: its balances, members, and expenses (with settle-up collapse). Entry point for
/// creating expenses, managing members, and (for Splitwise groups) importing as a local group.
struct GroupDetailView: View {
    let group: ExpenseGroup

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var expenses: [Expense]
    @Query private var members: [GroupMember]
    @Query private var users: [User]
    @Query private var balanceRows: [GroupBalance]
    @Query(sort: \SpendCategory.position) private var spendCategories: [SpendCategory]

    @State private var brandModel = BrandModel()
    @State private var showingNewExpense = false
    @State private var showingMembers = false
    @AppStorage("groupDetail.showSettled") private var showSettled = false
    @State private var errorText: String?
    @State private var scan = ReceiptScanModel()
    @State private var showingReceiptScanner = false
    @State private var receiptPhoto: PhotosPickerItem?
    @State private var confirmingDelete = false
    @State private var showingAvatar = false

    init(group: ExpenseGroup) {
        self.group = group
        let gid = group.id
        _expenses = Query(
            filter: #Predicate<Expense> { $0.groupId == gid },
            sort: \Expense.date, order: .reverse
        )
        _members = Query(
            filter: #Predicate<GroupMember> { $0.groupId == gid },
            sort: \GroupMember.userIdentifier
        )
        _balanceRows = Query(
            filter: #Predicate<GroupBalance> { $0.groupId == gid },
            sort: \GroupBalance.net, order: .reverse
        )
    }

    private var collapse: (visible: [Expense], collapsed: Int) {
        SettleUp.collapseOlder(expenses)
    }

    var body: some View {
        if group.isDeleted {
            // The group was just deleted from this screen - stop reading the dangling SwiftData model
            // (touching a deleted @Model crashes) and pop back instead.
            Color.clear.onAppear { dismiss() }
        } else {
            content
        }
    }

    private var content: some View {
        // Hoist per-render values out of the row builders - reading a @Query/env per row freezes the list on tap.
        let users = self.users
        let me = env.currentUser?.identifier
        // Cached server balances render instantly (a @Query); `reload` refreshes them in the background.
        let balances = balanceRows
        return List {
            Section {
                HStack(spacing: 12) {
                    Button { showingAvatar = true } label: {
                        AvatarView(url: group.avatarURL, name: group.name, size: 48, systemImage: group.typeSymbol)
                            .overlay(alignment: .bottomTrailing) { AvatarCameraBadge() }
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.headline)
                        if let type = group.groupType, !type.isEmpty {
                            Text(type.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        UpdatedAgo(date: group.updatedAt)
                    }
                }
            }

            if !balances.isEmpty {
                Section("Balances") {
                    ForEach(balances) { entry in
                        let phrase = BalancePhrase.member(
                            entry.net, isMe: entry.userIdentifier == me)
                        let name = users.displayName(for: entry.userIdentifier)
                        HStack {
                            AvatarView(url: users.avatarURL(for: entry.userIdentifier), name: name, size: 28)
                            Text(name)
                            Spacer()
                            Text(phrase.label).font(.caption).foregroundStyle(.secondary)
                            if let amount = phrase.amount {
                                Text(amount).foregroundStyle(phrase.color).monospacedDigit()
                            }
                        }
                    }
                }
            }

            let data = showSettled ? expenses : collapse.visible
            ForEach(expenseMonthGroups(data), id: \.id) { month in
                Section {
                    ForEach(month.expenses) { expense in
                        // Closure-based nav: value-based links nested here drop the first tap (off-by-one).
                        NavigationLink {
                            LazyView(ExpenseDetailView(expense: expense))
                        } label: {
                            ExpenseRow(expense: expense, users: users, meIdentifier: me,
                                       brandModel: brandModel)
                        }
                    }
                } header: {
                    Text(month.label).textCase(nil)
                }
            }
            if expenses.isEmpty {
                Section { Text("No expenses yet.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Blank Expense", systemImage: "square.and.pencil") { showingNewExpense = true }
                    Button("Scan Receipt", systemImage: "doc.viewfinder") { showingReceiptScanner = true }
                    PhotosPicker(selection: $receiptPhoto, matching: .images) {
                        Label("Receipt from Photo", systemImage: "photo")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if collapse.collapsed > 0 || showSettled {
                        Toggle(isOn: $showSettled) {
                            Label("Show settled (\(collapse.collapsed))", systemImage: "eye")
                        }
                    }
                    Button("Members", systemImage: "person.2") { showingMembers = true }
                    Section("Budget") {
                        Toggle("Include in spending", isOn: Binding(
                            get: { group.includeInSpending ?? true },
                            set: { setFlags(includeInSpending: $0) }))
                        Toggle("Include in cash flow", isOn: Binding(
                            get: { group.includeInCashFlow ?? true },
                            set: { setFlags(includeInCashFlow: $0) }))
                    }
                    if group.backendType == .splitwise {
                        Button("Import as Local Group", systemImage: "square.and.arrow.down", action: importLocal)
                    }
                    Divider()
                    Button("Delete Group", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingNewExpense) {
            ExpenseEditView(group: group, members: members.map(\.userIdentifier))
        }
        .sheet(isPresented: $showingMembers) {
            GroupMembersView(group: group)
        }
        .sheet(isPresented: $showingAvatar) {
            if group.hasCustomAvatar {
                AvatarManageView(target: .group(group.id), crop: group.avatarCrop)
            } else {
                AddAvatarView(target: .group(group.id))
            }
        }
        .receiptScanEntry(scan: scan, categories: spendCategories.map(\.name),
                          showingScanner: $showingReceiptScanner, photo: $receiptPhoto) { prefill, image in
            ExpenseEditView(group: group, members: members.map(\.userIdentifier),
                            prefill: prefill, attachImageData: image)
        }
        .overlay {
            if scan.isScanning {
                ProgressView("Reading receipt…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog("Delete this group?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Group", role: .destructive, action: deleteGroup)
        } message: {
            Text(group.backendType == .splitwise
                 ? "This permanently deletes the group on Splitwise for you and everyone in it."
                 : "This permanently deletes the group and all its expenses.")
        }
        .alert("Heads up", isPresented: Binding(
            get: { scan.infoMessage != nil }, set: { if !$0 { scan.infoMessage = nil } }
        )) {
            Button("OK") {}
        } message: { Text(scan.infoMessage ?? "") }
        .errorAlert(Binding(get: { scan.errorText }, set: { scan.errorText = $0 }))
        .refreshable {
            await env.smartRefresh(source: group.backendType == .splitwise ? .splitwise : .none,
                                   freshness: group.updatedAt,
                                   splitwiseScope: group.splitwiseGroupId.map { .group($0) } ?? .all,
                                   context: context, reconcile: reconcileGroup)
        }
        .task { await reload() }
        .task(id: expenses.map(\.id)) { await resolveBrands() }
        .errorAlert($errorText)
    }

    /// Warm the favicon cache for every row's note override + merchant (deduped), off the render path.
    private func resolveBrands() async {
        await brandModel.resolve(merchantTexts: expenses.flatMap { e in
            [(text: e.note, category: e.category), (text: e.details, category: e.category)]
        })
    }

    /// On-appear reconcile (local only - the pull-to-refresh path decides whether to live-sync first).
    private func reload() async {
        do { try await reconcileGroup() } catch { errorText = errorMessage(error) }
    }

    private func reconcileGroup() async throws {
        try await env.expenses(context).reconcileAll(groupId: group.id)
        try await env.groups(context).refreshMembers(groupId: group.id)
        try await env.balances(context).refreshGroup(group.id)
    }

    private func importLocal() {
        Task {
            do {
                try await env.groups(context).importLocal(groupId: group.id)
                try await env.expenses(context).reconcileAll()
            } catch { errorText = errorMessage(error) }
        }
    }

    private func setFlags(includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil) {
        let id = group.id
        Task {
            do {
                try await env.groups(context).update(
                    id: id, includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow)
            } catch { errorText = errorMessage(error) }
        }
    }

    private func deleteGroup() {
        let id = group.id
        Task {
            do {
                // Splitwise deletes are restorable server-side (any member); the Restore screen lists them.
                try await env.groups(context).delete(id: id)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}

/// An expense row: stacked date, category icon, description, a "who paid what" subtitle, and your
/// share as a "you owe / you are owed" amount. Settle-ups read "Alice paid Bob" with a neutral
/// amount (no owe/owed). `groupName` is shown in the subtitle on cross-group lists (All Expenses).
struct ExpenseRow: View {
    let expense: Expense
    let users: [User]
    let meIdentifier: String?
    var groupName: String? = nil
    /// Built once by the parent list; empty falls back to deterministic canonicalization (still folds
    /// Splitwise labels like "Dining out" → "Dining" for the icon).
    var lookup: [String: String] = [:]
    /// Shared brand resolver owned by the parent list; drives the merchant favicon (falls back to category).
    var brandModel: BrandModel

    private var isSettleUp: Bool { expense.category == SettleUp.category }
    private var isReimbursement: Bool { expense.category == Reimbursement.category }

    private var subtitle: String {
        var core: String
        if isReimbursement, let recipient = expense.splits.max(by: { $0.owedShare < $1.owedShare }) {
            core = "\(users.displayName(for: recipient.userIdentifier)) got "
                + recipient.owedShare.formatted(.currency(code: expense.currency)) + " back"
        } else if isSettleUp, let payer = expense.splits.first(where: { $0.paidShare > 0 }) {
            let payerName = users.displayName(for: payer.userIdentifier)
            if let recipient = expense.splits.first(where: { $0.owedShare > 0 && $0.paidShare == 0 }) {
                core = "\(payerName) paid \(users.displayName(for: recipient.userIdentifier))"
            } else {
                core = "\(payerName) paid"
            }
        } else {
            let payers = expense.splits.filter { $0.paidShare > 0 }
            if payers.count == 1, let first = payers.first {
                core = "\(users.displayName(for: first.userIdentifier)) paid "
                    + first.paidShare.formatted(.currency(code: expense.currency))
            } else if payers.count > 1 {
                core = "\(payers.count) people paid"
            } else {
                core = ""
            }
        }
        if let groupName {
            return core.isEmpty ? groupName : "\(groupName) · \(core)"
        }
        return core
    }

    /// Your net on this expense (paid − owed), or nil when you're not a participant.
    private var myNet: Decimal? {
        guard let me = meIdentifier,
              let split = expense.splits.first(where: { $0.userIdentifier == me }) else { return nil }
        return split.paidShare - split.owedShare
    }

    var body: some View {
        // Match the current icon's category derivation (Splitwise label → canonical), for the fallback.
        let category = expense.category.flatMap { CategoryMapping.canonical($0, lookup: lookup) }
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(expense.date.formatted(.dateTime.month(.abbreviated)))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(expense.date.formatted(.dateTime.day()))
                    .font(.headline).monospacedDigit()
            }
            .frame(width: 34)
            MerchantAvatar(merchant: expense.details, note: expense.note,
                           category: category, size: 30, amount: expense.amount, brandModel: brandModel)
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.details)
                if let note = expense.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isSettleUp {
            // Settle-up: neutral amount, no "you owe / you are owed".
            Text(expense.amount.formatted(.currency(code: expense.currency)))
                .foregroundStyle(.secondary).monospacedDigit()
        } else if let net = myNet {
            let phrase = BalancePhrase.mine(net, code: expense.currency)
            VStack(alignment: .trailing, spacing: 1) {
                Text(phrase.label).font(.caption2).foregroundStyle(.secondary)
                if let amount = phrase.amount {
                    Text(amount).fontWeight(.medium).foregroundStyle(phrase.color).monospacedDigit()
                }
            }
        } else {
            Text(expense.amount.formatted(.currency(code: expense.currency)))
                .foregroundStyle(.secondary)
        }
    }
}
