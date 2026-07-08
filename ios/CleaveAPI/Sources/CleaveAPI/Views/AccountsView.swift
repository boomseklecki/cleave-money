import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// The finance side: cached accounts (sortable), a sync action, and a link to transactions. Linking
/// and managing banks lives in Settings → Linked Banks.
struct AccountsView: View {
    enum SortMode: String, CaseIterable, Identifiable {
        case balance = "Balance"
        case lastTransaction = "Last transaction"
        case type = "Type"
        case bank = "Bank"
        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var spendCategories: [SpendCategory]

    @AppStorage("accounts.sortMode") private var sortModeRaw = SortMode.balance.rawValue

    @State private var errorText: String?
    @State private var refreshFailed = false
    @State private var showingManual = false
    @State private var scan = ReceiptScanModel()
    @State private var showingReceiptScanner = false
    @State private var receiptPhoto: PhotosPickerItem?
    @State private var importingStatement = false
    @State private var statementSummary: String?
    @State private var linkSession: LinkSession?
    @State private var linking = false
    @State private var showingSimpleFin = false
    /// Latest transaction date per account (account id → date), for the last-transaction sort. Loaded
    /// on demand with a `fetchLimit: 1` query per account.
    @State private var lastTransaction: [UUID: Date] = [:]
    /// Plaid items (bank → its accounts), loaded lazily for the Bank sort only.
    @State private var items: [Components.Schemas.PlaidItemResponse] = []
    /// Partner-owned accounts shared *to* you (live-fetched, never cached so they stay out of analytics).
    @State private var sharedAccounts: [Components.Schemas.AccountResponse] = []

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .balance }

    /// Type sections, in display order. Each renders only when it has accounts.
    private static let typeSections: [(title: String, kind: AccountKind)] = [
        ("Cash-flow", .cashFlow), ("Liabilities", .liability), ("Savings", .holdings),
    ]

    /// An account's signed net-worth contribution: a liability subtracts (its positive balance is debt owed),
    /// everything else adds. Drives the section net-worth totals and the balance sort. Display is unaffected -
    /// each row still shows its own positive balance.
    private func signedBalance(_ account: Account) -> Decimal {
        account.kind == .liability ? -account.balance : account.balance
    }
    /// Net worth of a set of accounts = assets - liabilities.
    private func netWorth(_ list: [Account]) -> Decimal { list.reduce(0) { $0 + signedBalance($1) } }

    private func byBalance(_ list: [Account]) -> [Account] {
        list.sorted { signedBalance($0) > signedBalance($1) }   // signed, so debts sort below assets
    }

    /// Accounts grouped by their Plaid institution for the Bank sort: one `(bank, accounts)` group per
    /// item (alphabetical, balance-desc within), plus a trailing "Other" group for accounts not covered
    /// by any item (manual, or before `items` has loaded). Empty groups are dropped.
    private var bankGroups: [(title: String, domain: String?, accounts: [Account])] {
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var covered = Set<UUID>()
        var groups: [(title: String, domain: String?, accounts: [Account])] = []
        let sortedItems = items.sorted {
            ($0.institution_name ?? "Bank").localizedCaseInsensitiveCompare($1.institution_name ?? "Bank")
                == .orderedAscending
        }
        for item in sortedItems {
            let linked = (item.accounts ?? []).compactMap { UUID(uuidString: $0.id).flatMap { byId[$0] } }
            linked.forEach { covered.insert($0.id) }
            if !linked.isEmpty {
                groups.append((item.institution_name ?? "Bank", item.institution_domain, byBalance(linked)))
            }
        }
        let other = accounts.filter { !covered.contains($0.id) }
        if !other.isEmpty { groups.append(("Other", nil, byBalance(other))) }
        return groups
    }
    private func byLastTransaction(_ list: [Account]) -> [Account] {
        list.sorted { (lastTransaction[$0.id] ?? .distantPast) > (lastTransaction[$1.id] ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if refreshFailed { Section { StaleNotice() } }
                if accounts.isEmpty {
                    Section("Accounts") {
                        Text("No accounts yet. Link a bank in Settings.").foregroundStyle(.secondary)
                    }
                } else if sortMode == .type {
                    ForEach(Self.typeSections, id: \.title) { section in
                        let items = byBalance(accounts.filter { $0.kind == section.kind })
                        if !items.isEmpty {
                            Section {
                                ForEach(items) { accountRow($0, byType: true) }
                            } header: {
                                netWorthHeader(section.title, accounts: items)
                            }
                        }
                    }
                } else if sortMode == .bank {
                    ForEach(bankGroups, id: \.title) { group in
                        Section {
                            ForEach(group.accounts) { accountRow($0, inBank: true) }
                        } header: {
                            netWorthHeader(group.title, accounts: group.accounts,
                                           logoDomain: group.domain, showLogo: true)
                        }
                    }
                } else {
                    Section {
                        let sorted = sortMode == .balance ? byBalance(accounts) : byLastTransaction(accounts)
                        ForEach(sorted) { accountRow($0) }
                    } header: {
                        netWorthHeader("Accounts", accounts: accounts)
                    }
                }

                if !sharedAccounts.isEmpty {
                    Section("Shared with you") {
                        ForEach(sharedAccounts, id: \.id) { sharedRow($0) }
                    }
                }

                Section {
                    NavigationLink("All Transactions") { TransactionsView() }
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort by", selection: $sortModeRaw) {
                            ForEach(SortMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Blank Transaction", systemImage: "square.and.pencil") { showingManual = true }
                        Button("Scan Receipt", systemImage: "doc.viewfinder") { showingReceiptScanner = true }
                        PhotosPicker(selection: $receiptPhoto, matching: .images) {
                            Label("Receipt from Photo", systemImage: "photo")
                        }
                        Divider()
                        Button("Import Statement (.ofx)", systemImage: "doc.badge.plus") { importingStatement = true }
                        if env.serverPlaidConfigured && env.serverPlaidEnabled {
                            Button("Link Bank", systemImage: "building.columns") { linkBank() }
                                .disabled(linking || env.currentUser == nil)
                        }
                        if env.serverSimpleFinEnabled {
                            Button("Connect via SimpleFIN", systemImage: "link") { showingSimpleFin = true }
                                .disabled(env.currentUser == nil)
                        }
                    } label: {
                        Image(systemName: linking ? "ellipsis" : "plus")
                    }
                }
            }
            .sheet(isPresented: $showingManual) { ManualTransactionView() }
            .sheet(isPresented: $showingSimpleFin) { NavigationStack { SimpleFinLinkView() } }
            .receiptScanEntry(scan: scan, categories: spendCategories.map(\.name),
                              showingScanner: $showingReceiptScanner, photo: $receiptPhoto) { prefill, image in
                ManualTransactionView(prefill: prefill, attachImageData: image)
            }
            .statementImporter(isPresented: $importingStatement) { statementSummary = $0 }
            .alert("Statement Imported",
                   isPresented: Binding(get: { statementSummary != nil }, set: { if !$0 { statementSummary = nil } })) {
                Button("OK") {}
            } message: {
                Text(statementSummary ?? "")
            }
            .plaidLink(session: $linkSession) { await exchange($0) }
            .refreshable { await reload() }
            .task {
                env.prewarmPlaidLinkToken(context)  // background; + menu's "Link Bank" opens without the wait
                await reload()
            }
            .onChange(of: sortModeRaw) { _, new in
                if new == SortMode.bank.rawValue && items.isEmpty { Task { await loadItems() } }
            }
            .errorAlert($errorText)
        }
    }

    /// A section header with the section's net worth as right-aligned hero text (assets - liabilities). Used
    /// for every account grouping - bank, type, or the flat "Accounts" list.
    @ViewBuilder
    private func netWorthHeader(_ title: String, accounts list: [Account],
                                logoDomain: String? = nil, showLogo: Bool = false) -> some View {
        HStack(spacing: 8) {
            if showLogo {
                AvatarView(url: InstitutionBrand.logoURL(domain: logoDomain, name: title),
                           name: title, size: 22, systemImage: "building.columns", logo: true)
            }
            Text(title).textCase(nil)
            Spacer()
            Text(netWorth(list).formatted(.currency(code: list.first?.currency ?? "USD")))
                .font(.title3).fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(.primary).textCase(nil)
        }
    }

    @ViewBuilder
    private func accountRow(_ account: Account, inBank: Bool = false, byType: Bool = false) -> some View {
        // Bank sections show type + mask; Type sections already convey the type, so show bank + mask there
        // (not the type again); other sorts show bank + type.
        let caption: String = inBank
            ? account.kind.label + (account.maskLabel.map { " · \($0)" } ?? "")
            : byType
                ? [account.institutionName, account.maskLabel].compactMap { $0 }.joined(separator: " · ")
                : [account.institutionName, account.kind.label].compactMap { $0 }.joined(separator: " · ")
        NavigationLink {
            TransactionsView(account: account)
        } label: {
            HStack(spacing: 12) {
                if !inBank {
                    AvatarView(url: account.institutionLogoURL,
                               name: account.institutionName ?? account.displayLabel, size: 32,
                               systemImage: "building.columns", logo: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayLabel)
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(account.balance.formatted(.currency(code: account.currency)))
                    .foregroundStyle(account.kind.balanceColor)
            }
        }
    }

    /// A partner-shared account row. A `full` account drills into a read-only, live-fetched transaction
    /// list; a `balances` account shows the balance only (no drill-in). Never enters the local cache.
    @ViewBuilder
    private func sharedRow(_ r: Components.Schemas.AccountResponse) -> some View {
        let balance = (try? Mapping.decimal(r.balance, field: "Account.balance")) ?? 0
        let label = HStack(spacing: 12) {
            AvatarView(url: InstitutionBrand.logoURL(domain: r.institution_domain, name: r.institution_name),
                       name: r.institution_name ?? r.name, size: 32,
                       systemImage: "building.columns", logo: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.display_name ?? r.name)
                Text("Shared by \(r.shared_by ?? "partner")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(balance.formatted(.currency(code: r.currency)))
        }
        if r.share_level == "full" {
            NavigationLink {
                SharedAccountTransactionsView(account: r)
            } label: { label }
        } else {
            label
        }
    }

    /// Pull-to-refresh / on-appear: refresh cached accounts from the backend, then recompute the
    /// last-transaction dates. The Sync button does the heavier Plaid round-trip.
    private func reload() async {
        refreshFailed = false
        await env.smartRefresh(source: .bank,
                               freshness: accounts.map(\.updatedAt).max(), context: context) {
            try await env.accounts(context).refreshAccounts()
        }
        loadLastTransactions()
        // Keep the cached list on failure (don't collapse offline), but flag it so the UI shows a quiet notice.
        do { sharedAccounts = try await env.accounts(context).sharedInAccounts() }
        catch { refreshFailed = true }
        if sortMode == .bank { await loadItems() }
    }

    /// Fetches the Plaid items (bank → accounts) used by the Bank sort. Best-effort; keeps the prior list
    /// on failure so the grouping doesn't collapse offline (flags a quiet stale notice).
    private func loadItems() async {
        do { items = try await env.plaid(context).items() }
        catch { refreshFailed = true }
    }

    /// Loads each account's most-recent transaction date with a single-row fetch per account, for the
    /// last-transaction sort. Reads the local cache, so it reflects the last sync.
    private func loadLastTransactions() {
        var result: [UUID: Date] = [:]
        for account in accounts {
            let aid = account.id
            var descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.accountId == aid },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            if let latest = try? context.fetch(descriptor).first {
                result[account.id] = latest.date
            }
        }
        lastTransaction = result
    }

    /// Start Plaid Link to add a bank (the global bank Sync now lives in Settings → Linked Banks).
    private func linkBank() {
        guard let me = env.currentUser?.identifier else {
            errorText = "Sign in to link a bank."
            return
        }
        linking = true
        Task {
            defer { linking = false }
            do {
                // Use the pre-warmed token when ready (instant), else fetch on demand.
                let token: String
                if let cached = PlaidLinkTokenCache.shared.take(for: me) {
                    token = cached
                } else {
                    token = try await env.plaid(context).linkToken(userIdentifier: me)
                }
                PlaidLinkSession.shared.begin(token: token)  // persist so a terminated OAuth can resume
                linkSession = LinkSession(token: token)
            } catch { errorText = errorMessage(error) }
        }
    }

    private func exchange(_ publicToken: String) async {
        guard let me = env.currentUser?.identifier else { return }
        do {
            // Slow client: exchange auto-syncs the new bank, which can backfill ~24 months.
            try await env.plaidSlow(context).exchange(publicToken: publicToken, userIdentifier: me)
            await reload()
        } catch { errorText = errorMessage(error) }
    }
}
