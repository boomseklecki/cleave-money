import SwiftUI
import SwiftData

/// The expense sibling of `RelatedTransactionsView`: groups expenses with a similar merchant description. Two
/// independent bulk actions: set a note on all the filtered expenses (the header note flow), and save a
/// merchant preference (logo + category) for matching merchants (the Merchant Preferences section). Reached
/// from "Find Related Expenses".
struct RelatedExpensesView: View {
    let seedDescription: String
    /// Pre-selects the category picker (the category of the expense you came from).
    var seedCategory: String? = nil
    /// The amount of the expense you came from - the header hero + the Amount match axis.
    var seedAmount: Decimal? = nil
    /// The note on the expense you came from - seeds the bulk note.
    var seedNote: String? = nil
    /// The date of the expense you came from - shown in the header.
    var seedDate: Date? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
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
            seedDescription: seedDescription, seedAmount: seedAmount, in: expenses,
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
                ForEach(group) { e in
                    NavigationLink {
                        LazyView(ExpenseDetailView(expense: e))
                    } label: {
                        let cat = e.category.flatMap { CategoryMapping.canonical($0, lookup: lookup) }
                        HStack(spacing: 12) {
                            MerchantAvatar(merchant: e.details, note: e.note, category: cat, size: 30,
                                           amount: e.amount, brandModel: brandModel)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.details).lineLimit(1)
                                if let note = e.note, !note.isEmpty {
                                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                HStack(spacing: 4) {
                                    Text(e.date.dateOnly())
                                    if let cat { Text("· \(cat)") }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(currency(e.amount, e.currency))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                if group.isEmpty {
                    Text("No related expenses.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Related Expenses")
            } footer: {
                if !group.isEmpty {
                    TotalsFooter(metrics: [
                        .count(group.count, label: "Expenses"),
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
            await brandModel.resolve(merchantTexts: group.flatMap { e in
                [(text: e.note, category: e.category), (text: e.details, category: e.category)]
            })
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: current, subject: name) { apply($0, to: group) }
        }
        .sheet(isPresented: $editingNote) {
            NoteEditorSheet(initial: mainNote) { noteOverride = $0; confirmingNote = true }
        }
        .confirmationDialog("Apply note to \(group.count) expense\(group.count == 1 ? "" : "s")?",
                            isPresented: $confirmingNote, titleVisibility: .visible) {
            Button("Apply") { applyNote(to: group) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sets this note on all \(group.count) expenses currently shown.")
        }
        .errorAlert($errorText)
    }

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

    /// The seed's (canonicalized) category, else the most common canonical category across the group.
    private func currentCategory(in group: [Expense]) -> String? {
        if let seedCategory, let c = CategoryMapping.canonical(seedCategory, lookup: lookup) { return c }
        let counts = group.reduce(into: [String: Int]()) { tally, e in
            if let raw = e.category, let c = CategoryMapping.canonical(raw, lookup: lookup) {
                tally[c, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Apply the picked category to every expense in the group (concurrent batch, one cache write).
    private func apply(_ category: String, to group: [Expense]) {
        let ids = group.map(\.id)
        let me = env.currentUser?.identifier
        Task {
            applying = true
            defer { applying = false }
            do {
                try await env.expenses(context).updateCategory(ids: ids, category: category, updatedBy: me)
            } catch {
                errorText = errorMessage(error)
            }
        }
    }

    /// Bulk-write the current note to every expense in the filtered group; the upserted rows repaint so the
    /// notes populate. Independent of the brand preference.
    private func applyNote(to group: [Expense]) {
        let ids = group.map(\.id)
        let note = mainNote.trimmingCharacters(in: .whitespaces)
        Task {
            applying = true
            defer { applying = false }
            do { try await env.expenses(context).setNotes(ids: ids, note: note) }
            catch { errorText = errorMessage(error) }
        }
    }

}
