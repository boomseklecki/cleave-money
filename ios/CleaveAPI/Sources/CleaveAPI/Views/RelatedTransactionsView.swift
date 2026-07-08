import SwiftUI
import SwiftData

/// Groups bank/manual transactions with a similar merchant description to the one you came from (at a chosen
/// Merchant/Amount filter). Two independent bulk actions: set a note on all the filtered transactions (the
/// header note flow), and save a merchant preference (logo + category) for matching merchants (the Merchant
/// Preferences section). The header mirrors the origin row with a centered, tappable category/favicon avatar.
/// Sibling: `RelatedExpensesView`.
struct RelatedTransactionsView: View {
    let seedDescription: String
    /// Pre-selects the category picker (the category of the row you came from).
    var seedCategory: String? = nil
    /// The amount of the row you came from - the header hero + the Amount match axis.
    var seedAmount: Decimal? = nil
    /// The note on the row you came from - seeds the bulk note.
    var seedNote: String? = nil
    /// The date of the row you came from - shown in the header.
    var seedDate: Date? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var categoryMaps: [CategoryMap]

    @State private var brandModel = BrandModel()
    @State private var showingCategoryPicker = false
    @State private var applying = false
    @State private var errorText: String?
    @State private var noteOverride: String?
    @State private var editingNote = false
    @State private var confirmingNote = false
    @State private var prefDrafts: [MerchantPrefDraft] = []
    @State private var unsavedPrefIDs: Set<UUID> = []
    @State private var loadedPrefs = false
    @State private var seedPattern = ""
    @State private var newRuleCategory: String?
    @AppStorage("relatedTransactions.matchStrictness")
    private var strictnessRaw = RelatedTransactions.MatchStrictness.balanced.rawValue
    @AppStorage("relatedTransactions.amountMatch")
    private var amountRaw = RelatedTransactions.AmountMatch.any.rawValue

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var strictness: RelatedTransactions.MatchStrictness {
        RelatedTransactions.MatchStrictness(rawValue: strictnessRaw) ?? .balanced
    }
    private var amountMatch: RelatedTransactions.AmountMatch {
        RelatedTransactions.AmountMatch(rawValue: amountRaw) ?? .any
    }
    private var mainNote: String { noteOverride ?? seedNote ?? "" }
    /// The resolved brand name, or the cleaned merchant display name - the default label when there's no note.
    private var resolvedBrandName: String {
        let resolved = brandModel.brand(key: MerchantText.key(seedDescription), displayName: seedDescription,
                                        amount: seedAmount)
        return resolved.domain != nil ? resolved.name : RelatedTransactions.displayName(for: seedDescription)
    }
    /// The default name for a new rule: the note when set, else the resolved brand / display name.
    private var effectiveLabel: String { mainNote.isEmpty ? resolvedBrandName : mainNote }

    var body: some View {
        let group = RelatedTransactions.group(
            seedDescription: seedDescription, seedAmount: seedAmount, in: transactions,
            strictness: strictness, amount: amountMatch)
        let name = RelatedTransactions.displayName(for: seedDescription)
        let code = group.first?.currency ?? "USD"
        let total = group.reduce(Decimal(0)) { $0 + $1.amount }
        let average = group.isEmpty ? 0 : total / Decimal(group.count)
        let current = currentCategory(in: group)
        let commonPattern = RelatedTransactions.commonTokens(of: group).joined(separator: " ")
        let headerLogo = brandModel.logoURL(note: mainNote.isEmpty ? nil : mainNote, merchant: seedDescription,
                                            amount: seedAmount)

        return List {
            originHeader(current: current, code: code, headerLogo: headerLogo)

            RelatedMatchFilters(strictnessRaw: $strictnessRaw, amountRaw: $amountRaw,
                                showAmount: seedAmount != nil)

            Section {
                ForEach(group) { t in
                    NavigationLink {
                        LazyView(TransactionDetailView(transaction: t))
                    } label: {
                        TransactionRow(transaction: t, lookup: lookup, brandModel: brandModel)
                    }
                }
                if group.isEmpty {
                    Text("No related transactions.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Related Transactions")
            } footer: {
                if !group.isEmpty {
                    TotalsFooter(metrics: [
                        .count(group.count, label: "Transactions"),
                        .total(total, code: code, label: "Total spend"),
                        .average(average, code: code, label: "Average spend"),
                    ])
                }
            }

            merchantPrefsSection()
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .unsavedChangesGuard(dirty: !unsavedPrefIDs.isEmpty, showsSaveButton: false) { await saveAllPrefs() }
        .onChange(of: commonPattern, initial: true) { _, p in seedPattern = p; loadPrefsIfNeeded() }
        .onChange(of: current, initial: true) { _, c in newRuleCategory = c }
        .task(id: group.map(\.id)) {
            let lookup = self.lookup
            await brandModel.resolve(merchantTexts: group.flatMap { t in
                let c = CategoryMapping.effectiveCategory(for: t, lookup: lookup)
                return [(text: t.note, category: c), (text: t.details, category: c)]
            })
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: current, subject: name) { apply($0, to: group) }
        }
        .sheet(isPresented: $editingNote) {
            NoteEditorSheet(initial: mainNote) { noteOverride = $0; confirmingNote = true }
        }
        .confirmationDialog("Apply note to \(group.count) transaction\(group.count == 1 ? "" : "s")?",
                            isPresented: $confirmingNote, titleVisibility: .visible) {
            Button("Apply") { applyNote(to: group) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sets this note on all \(group.count) transactions currently shown.")
        }
        .errorAlert($errorText)
    }

    /// Header card mirroring the origin row: centered tappable avatar, amount hero, description, note, date,
    /// with the note button in the top-right corner (matching the detail screens).
    @ViewBuilder
    private func originHeader(current: String?, code: String, headerLogo: String?) -> some View {
        Section {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    Button { showingCategoryPicker = true } label: {
                        CategoryAvatar(category: current, logoURL: headerLogo)
                    }
                    .buttonStyle(.plain)
                    .disabled(applying)
                    if let seedAmount {
                        Text(currency(seedAmount, code)).font(.title2).fontWeight(.semibold)
                    }
                    Text(seedDescription).font(.body).multilineTextAlignment(.center)
                    if !mainNote.isEmpty {
                        Text(mainNote).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let seedDate {
                        Text(seedDate.dateOnly()).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                NoteButton(hasNote: !mainNote.isEmpty) { editingNote = true }
            }
            .padding(.vertical, 4)
        }
    }

    /// Rules that apply to this merchant: every existing `MerchantPreferences` rule that matches, plus a seeded
    /// new-rule card. Each row is a collapsible `MerchantPrefCard` that saves on its own. Independent of the
    /// header note flow above.
    @ViewBuilder
    private func merchantPrefsSection() -> some View {
        Section {
            ForEach($prefDrafts) { $draft in
                MerchantPrefCard(draft: $draft, onSave: { savePrefRow(id: draft.id) },
                                 onDirtyChange: { setPrefDirty(draft.id, $0) })
            }
            Button { addSeededRule() } label: {
                Label("Add rule", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Merchant Preferences")
        } footer: {
            Text("Rules that apply to this merchant - a pattern (and optional amount) maps it to a logo, name, "
                 + "and category. Each row saves on its own.")
        }
    }

    private func setPrefDirty(_ id: UUID, _ dirty: Bool) {
        if dirty { unsavedPrefIDs.insert(id) } else { unsavedPrefIDs.remove(id) }
    }

    /// Persist one rule (drop the old on an identity change, then upsert with the specific-first default) + push.
    private func savePrefRow(id: UUID) {
        guard let i = prefDrafts.firstIndex(where: { $0.id == id }), let pref = prefDrafts[i].toPref() else { return }
        let newIdentity = MerchantPreferences.identity(pref)
        if let old = prefDrafts[i].originalIdentity, old != newIdentity {
            MerchantPreferences.shared.removePreference(identity: old)
        }
        MerchantPreferences.shared.setPreference(
            pattern: pref.pattern, note: pref.note, website: pref.website, amount: pref.amount,
            amountMode: pref.amountMode, category: pref.category, prioritize: true)
        prefDrafts[i].originalIdentity = newIdentity
        unsavedPrefIDs.remove(id)
        Task { await env.pushMerchantPreferences() }
    }

    private func saveAllPrefs() async -> Bool {
        for id in Array(unsavedPrefIDs) { savePrefRow(id: id) }
        return true
    }

    /// Load the rules that already match this merchant (once). New rules are seeded on demand via "Add rule".
    private func loadPrefsIfNeeded() {
        guard !loadedPrefs else { return }
        loadedPrefs = true
        prefDrafts = MerchantPreferences.shared.matchingPrefs(
            note: mainNote.isEmpty ? nil : mainNote, merchant: seedDescription).map(MerchantPrefDraft.init)
    }

    /// Append a new rule seeded from the current context: name (note -> resolved brand -> cleaned merchant),
    /// website (from that brand), category (the group's), and pattern (the group's common tokens).
    private func addSeededRule() {
        let brand = brandModel.brand(key: MerchantText.key(effectiveLabel), displayName: effectiveLabel,
                                     amount: seedAmount)
        let draft = MerchantPrefDraft(pattern: seedPattern, note: effectiveLabel, website: brand.domain ?? "",
                                      amountMode: .any, amountStr: "", category: newRuleCategory)
        unsavedPrefIDs.insert(draft.id)
        prefDrafts.append(draft)
    }

    private func currency(_ value: Decimal, _ code: String) -> String { value.currency(code) }

    /// The seed's category, else the most common effective category across the group.
    private func currentCategory(in group: [Transaction]) -> String? {
        if let seedCategory { return seedCategory }
        let counts = group.reduce(into: [String: Int]()) { tally, t in
            if let c = CategoryMapping.effectiveCategory(for: t, lookup: lookup) { tally[c, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Apply the picked category to every transaction in the group (concurrent batch, one cache write).
    private func apply(_ category: String, to group: [Transaction]) {
        let ids = group.map(\.id)
        Task {
            applying = true
            defer { applying = false }
            do {
                try await env.accounts(context).setCategoryOverride(ids: ids, category: category)
            } catch {
                errorText = errorMessage(error)
            }
        }
    }

    /// Bulk-write the current note to every transaction in the filtered group. The upserted rows repaint, so
    /// the notes populate in the list. Independent of the brand preference.
    private func applyNote(to group: [Transaction]) {
        let ids = group.map(\.id)
        let note = mainNote.trimmingCharacters(in: .whitespaces)
        Task {
            applying = true
            defer { applying = false }
            do { try await env.accounts(context).setTransactionNotes(ids: ids, note: note) }
            catch { errorText = errorMessage(error) }
        }
    }

}
