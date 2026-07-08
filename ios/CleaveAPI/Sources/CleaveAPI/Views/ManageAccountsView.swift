import SwiftUI
import SwiftData

/// Unified account management: Plaid-linked banks, OFX-imported accounts, and manual accounts - each grouped
/// under an institution avatar, rows opening the account editor. The toolbar `+` links a bank / imports a
/// statement / creates a manual account; per-section `+` quick-adds (import / a manual transaction); imported
/// and manual accounts can be deleted with all their transactions, and a whole bank can be unlinked. Reached
/// from Settings → Accounts.
struct ManageAccountsView: View {
    @Binding var items: [Components.Schemas.PlaidItemResponse]

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var confirmingUnlink: UnlinkTarget?
    @State private var confirmingDelete: Account?
    @State private var errorText: String?
    @State private var linkSession: LinkSession?
    @State private var linking = false
    @State private var importingStatement = false
    @State private var statementSummary: String?
    @State private var showingNewAccount = false
    @State private var showingManualTxn = false
    @State private var showingSupportedBanks = false
    @State private var showingSimpleFin = false

    struct UnlinkTarget: Identifiable { let id: String; let name: String }

    /// (mask|domain) keys of the linked-bank accounts, to spot an imported account that's the same card.
    private var plaidIdentities: Set<String> {
        Set(accounts.filter(\.isPlaid).compactMap { a in
            guard let m = a.mask, let d = a.institutionDomain, !d.isEmpty else { return nil }
            return "\(m)|\(d)"
        })
    }
    private func likelyDuplicate(_ a: Account) -> Bool {
        guard let m = a.mask, let d = a.institutionDomain, !d.isEmpty else { return false }
        return plaidIdentities.contains("\(m)|\(d)")
    }

    private var imported: [Account] { accounts.filter(\.isImported) }
    private var manual: [Account] { accounts.filter(\.isManual) }
    /// Imported accounts grouped by institution name (alphabetical), each with its resolved domain for the logo.
    private var importedByInstitution: [(name: String, domain: String?, accounts: [Account])] {
        let groups = Dictionary(grouping: imported) { $0.institutionName ?? "Imported" }
        return groups.keys.sorted().map { name in
            let accts = groups[name]!.sorted { $0.name < $1.name }
            return (name, accts.first?.institutionDomain, accts)
        }
    }

    var body: some View {
        // Correlate each Plaid item's accounts to cached models once per render (avoid per-row dict builds).
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return List {
            if items.isEmpty && imported.isEmpty && manual.isEmpty {
                ContentUnavailableView("No Accounts", systemImage: "building.columns",
                    description: Text("Link a bank, import a statement, or create a manual account from the + menu."))
            }

            // 1) Linked banks (Plaid) - one section per bank.
            ForEach(items, id: \.id) { item in
                let linked = (item.accounts ?? []).compactMap { UUID(uuidString: $0.id).flatMap { byId[$0] } }
                Section {
                    if linked.isEmpty {
                        Text("No accounts cached yet. Sync this bank to populate it.").foregroundStyle(.secondary)
                    }
                    ForEach(linked) { account in
                        accountRow(account).swipeActions(edge: .trailing) {
                            Button { refresh(account: account) } label: {
                                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                            }.tint(.blue)
                        }
                    }
                    Button("Unlink Bank", systemImage: "trash", role: .destructive) {
                        confirmingUnlink = UnlinkTarget(id: item.id, name: item.institution_name ?? "Bank")
                    }
                } header: { bankHeader(item, linked: linked) }
            }

            // 2) Imported (OFX) - grouped by institution; header `+` imports another statement.
            ForEach(importedByInstitution, id: \.name) { group in
                Section {
                    ForEach(group.accounts) { account in importedRow(account) }
                } header: {
                    institutionHeader(name: group.name, domain: group.domain,
                                      systemImage: "doc.text", addLabel: "Import statement") {
                        importingStatement = true
                    }
                }
            }

            // 3) Manual - header `+` adds a transaction.
            if !manual.isEmpty {
                Section {
                    ForEach(manual) { account in deletableRow(account) }
                } header: {
                    institutionHeader(name: "Manual", domain: nil,
                                      systemImage: "banknote", addLabel: "New transaction") {
                        showingManualTxn = true
                    }
                }
            }

            if let statementSummary {
                Section { Text(statementSummary).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if env.serverPlaidConfigured && env.serverPlaidEnabled {
                        Button("Link Bank", systemImage: "building.columns") { linkBank() }
                            .disabled(linking || env.currentUser == nil)
                    }
                    if env.serverSimpleFinEnabled {
                        Button("Connect via SimpleFIN", systemImage: "link") { showingSimpleFin = true }
                            .disabled(env.currentUser == nil)
                    }
                    Button("Import Statement (.ofx)", systemImage: "doc.badge.plus") { importingStatement = true }
                    Button("Find Your Bank", systemImage: "magnifyingglass") { showingSupportedBanks = true }
                    Button("New Manual Account", systemImage: "plus.square") { showingNewAccount = true }
                } label: {
                    Image(systemName: linking ? "ellipsis" : "plus")
                }
            }
        }
        .statementImporter(isPresented: $importingStatement) { statementSummary = $0 }
        .plaidLink(session: $linkSession) { await exchange($0) }
        .sheet(isPresented: $showingSupportedBanks) {
            NavigationStack { SupportedBanksView() }
        }
        .sheet(isPresented: $showingNewAccount) { NewAccountView() }
        .sheet(isPresented: $showingSimpleFin) { NavigationStack { SimpleFinLinkView() } }
        .sheet(isPresented: $showingManualTxn) { ManualTransactionView() }
        .confirmationDialog(
            confirmingUnlink.map { "Unlink \($0.name)?" } ?? "Unlink bank?",
            isPresented: Binding(get: { confirmingUnlink != nil }, set: { if !$0 { confirmingUnlink = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unlink", role: .destructive) { if let t = confirmingUnlink { unlink(t) } }
        } message: {
            Text("Removes this bank, its cached accounts, and their transactions, and revokes access at Plaid.")
        }
        .confirmationDialog(
            confirmingDelete.map { "Delete \($0.displayLabel)?" } ?? "Delete account?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let a = confirmingDelete { delete(a) } }
        } message: {
            Text("Deletes this account and all its transactions. This can't be undone.")
        }
        .task { if items.isEmpty { await loadItems() } }
        .errorAlert($errorText)
    }

    // MARK: Rows

    /// Shared row content: name, kind · mask, last-updated, an optional footnote, and balance. Opens the
    /// account editor on tap.
    @ViewBuilder
    private func accountRow(_ account: Account, footnote: String? = nil) -> some View {
        NavigationLink {
            AccountEditView(account: account)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayLabel)
                    Text(account.kind.label + (account.maskLabel.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    UpdatedAgo(date: account.updatedAt)
                    if let footnote {
                        Label(footnote, systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Text(account.balance.formatted(.currency(code: account.currency)))
                    .foregroundStyle(account.kind.balanceColor)
            }
        }
    }

    /// A manual row with a destructive delete swipe (deletes the account + all its transactions).
    @ViewBuilder
    private func deletableRow(_ account: Account) -> some View {
        accountRow(account).swipeActions(edge: .trailing) {
            Button(role: .destructive) { confirmingDelete = account } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// An imported row: delete swipe + (when it looks like a Plaid duplicate) a "possible duplicate" hint and an
    /// "Exclude from spending" swipe that drops its transactions from spend/cash-flow analytics (reuses the
    /// per-account include flags - non-destructive).
    @ViewBuilder
    private func importedRow(_ account: Account) -> some View {
        let dup = likelyDuplicate(account)
        accountRow(account, footnote: dup ? "Possible duplicate of a linked bank" : nil)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { confirmingDelete = account } label: {
                    Label("Delete", systemImage: "trash")
                }
                if dup {
                    Button { exclude(account) } label: { Label("Exclude", systemImage: "eye.slash") }.tint(.orange)
                }
            }
    }

    // MARK: Headers

    private func bankHeader(_ item: Components.Schemas.PlaidItemResponse, linked: [Account]) -> some View {
        HStack(spacing: 8) {
            bankAvatar(for: item)
            Text(item.institution_name ?? "Bank").textCase(nil)
            Spacer()
            Button { refresh(item: item, linked: linked) } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh \(item.institution_name ?? "bank")")
        }
    }

    private func institutionHeader(name: String, domain: String?, systemImage: String,
                                   addLabel: String, onAdd: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            AvatarView(url: InstitutionBrand.logoURL(domain: domain, name: name),
                       name: name, size: 22, systemImage: systemImage, logo: true)
            Text(name).textCase(nil)
            Spacer()
            Button(action: onAdd) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .accessibilityLabel(addLabel)
        }
    }

    /// The bank's avatar, with a Menu (when a domain resolved) to switch its Icon/Logo style - persisted.
    @ViewBuilder
    private func bankAvatar(for item: Components.Schemas.PlaidItemResponse) -> some View {
        let avatar = AvatarView(url: InstitutionBrand.logoURL(domain: item.institution_domain,
                                                              name: item.institution_name),
                                name: item.institution_name ?? "Bank", size: 22,
                                systemImage: "building.columns", logo: true)
        if let domain = item.institution_domain, !domain.isEmpty {
            Menu {
                Picker("Avatar", selection: Binding(
                    get: { BankLogoPreferences.shared.style(forDomain: domain) },
                    set: { BankLogoPreferences.shared.setStyle($0, forDomain: domain) }
                )) {
                    Label("Icon", systemImage: "app.dashed").tag(BankLogoStyle.icon)
                    Label("Logo", systemImage: "building.columns").tag(BankLogoStyle.logo)
                }
            } label: { avatar }
        } else {
            avatar
        }
    }

    // MARK: Actions

    private func refresh(item: Components.Schemas.PlaidItemResponse, linked: [Account]) {
        Task {
            await env.smartRefresh(source: .bank, freshness: linked.map(\.updatedAt).max(),
                                   plaidItemId: UUID(uuidString: item.id), context: context) {
                try await env.accounts(context).refreshAccounts()
            }
        }
    }

    private func refresh(account: Account) {
        Task {
            await env.smartRefresh(source: account.plaidItemId != nil ? .bank : .none,
                                   freshness: account.updatedAt, plaidItemId: account.plaidItemId,
                                   context: context) {
                try await env.accounts(context).refreshAccounts()
            }
        }
    }

    private func unlink(_ target: UnlinkTarget) {
        guard let id = UUID(uuidString: target.id) else { return }
        confirmingUnlink = nil
        Task {
            do {
                try await env.plaid(context).deleteItem(id: id)
                items.removeAll { $0.id == target.id }
            } catch { errorText = errorMessage(error) }
        }
    }

    private func delete(_ account: Account) {
        let id = account.id
        confirmingDelete = nil
        Task {
            do { try await env.accounts(context).deleteAccount(id: id) }
            catch { errorText = errorMessage(error) }
        }
    }

    private func loadItems() async {
        do { items = try await env.plaid(context).items() }
        catch { /* best-effort; keep the cached items */ }
    }

    private func linkBank() {
        guard let me = env.currentUser?.identifier else { errorText = "Sign in to link a bank."; return }
        linking = true
        Task {
            defer { linking = false }
            do {
                let token: String
                if let cached = PlaidLinkTokenCache.shared.take(for: me) {
                    token = cached
                } else {
                    token = try await env.plaid(context).linkToken(userIdentifier: me)
                }
                PlaidLinkSession.shared.begin(token: token)
                linkSession = LinkSession(token: token)
            } catch { errorText = errorMessage(error) }
        }
    }

    private func exchange(_ publicToken: String) async {
        guard let me = env.currentUser?.identifier else { errorText = "Sign in to link a bank."; return }
        do {
            try await env.plaidSlow(context).exchange(publicToken: publicToken, userIdentifier: me)
            await loadItems()
        } catch { errorText = errorMessage(error) }
    }

    /// Non-destructively drop a duplicate account's transactions from spending/cash-flow (reuses the per-account
    /// include flags).
    private func exclude(_ account: Account) {
        let id = account.id
        Task {
            do { try await env.accounts(context).update(id: id, includeInSpending: false, includeInCashFlow: false) }
            catch { errorText = errorMessage(error) }
        }
    }
}
