import SwiftUI
import SwiftData

/// Per-user manager for your merchant brand/note overrides (`MerchantPreferences`) - the private counterpart to
/// the admin `BrandCatalogView`. Each row is a favicon preview + brand name (note), website, match pattern, an
/// Any/Close/Equal amount constraint, and an optional category (captured groundwork for a future auto-categorize).
/// Edits a local copy and saves the whole set back; the store syncs to your other devices on its own.
struct MerchantPreferencesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var drafts: [MerchantPrefDraft] = []
    @State private var unsavedIDs: Set<UUID> = []
    @State private var newlyAddedID: UUID?
    @State private var loaded = false
    @State private var syncing = false

    var body: some View {
        Form {
            Section {
                ForEach($drafts) { $draft in
                    MerchantPrefCard(draft: $draft, initiallyExpanded: draft.id == newlyAddedID,
                                     onSave: { saveRow(id: draft.id) },
                                     onDirtyChange: { setDirty(draft.id, $0) })
                }
                .onDelete(perform: deleteRows)
                .onMove(perform: moveRows)

                Button { addRow() } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Merchant rules")
            } footer: {
                Text("A pattern (and optional amount) maps a merchant to a logo, name, and category. "
                     + "Any = any amount, Close = near the amount, Equal = exact. When more than one rule matches "
                     + "a charge, the first one wins - tap Edit and drag to set priority. Each row saves on its "
                     + "own; these are private to you and sync to your devices.")
            }

            Section {
                Button(action: syncNow) {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if syncing { ProgressView() }
                    }
                }
                .disabled(syncing || !loaded)
            } footer: {
                Text("These preferences sync to your account. Sync now to pull in rules you made on another device.")
            }
        }
        .navigationTitle("Merchant Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .unsavedChangesGuard(dirty: !unsavedIDs.isEmpty, showsSaveButton: false) { await saveAll() }
        .task {
            if !loaded { drafts = MerchantPreferences.shared.prefs.map(MerchantPrefDraft.init); loaded = true }
        }
    }

    private func setDirty(_ id: UUID, _ dirty: Bool) {
        if dirty { unsavedIDs.insert(id) } else { unsavedIDs.remove(id) }
    }

    private func addRow() {
        let draft = MerchantPrefDraft()
        newlyAddedID = draft.id
        withAnimation { drafts.append(draft) }
    }

    /// Persist one row: drop the old rule if its identity changed, upsert (manual order kept - no reprioritize),
    /// then restore the manager's visual order and push.
    private func saveRow(id: UUID) {
        guard let i = drafts.firstIndex(where: { $0.id == id }), let pref = drafts[i].toPref() else { return }
        let newIdentity = MerchantPreferences.identity(pref)
        if let old = drafts[i].originalIdentity, old != newIdentity {
            MerchantPreferences.shared.removePreference(identity: old)
        }
        MerchantPreferences.shared.setPreference(
            pattern: pref.pattern, note: pref.note, website: pref.website, amount: pref.amount,
            amountMode: pref.amountMode, category: pref.category, prioritize: false)
        drafts[i].originalIdentity = newIdentity
        MerchantPreferences.shared.setOrder(drafts.compactMap(\.originalIdentity))
        unsavedIDs.remove(id)
        Task { await env.pushMerchantPreferences() }
    }

    private func saveAll() async -> Bool {
        for id in Array(unsavedIDs) { saveRow(id: id) }
        return true
    }

    private func moveRows(_ offsets: IndexSet, _ destination: Int) {
        drafts.move(fromOffsets: offsets, toOffset: destination)
        MerchantPreferences.shared.setOrder(drafts.compactMap(\.originalIdentity))
        Task { await env.pushMerchantPreferences() }
    }

    /// Delete rows and immediately remove their stored rules (persisted, no Save needed), then push.
    private func deleteRows(_ offsets: IndexSet) {
        let removed = offsets.map { drafts[$0] }
        unsavedIDs.subtract(removed.map(\.id))
        drafts.remove(atOffsets: offsets)
        let identities = removed.compactMap(\.originalIdentity)
        guard !identities.isEmpty else { return }   // unsaved new rows: nothing stored to delete
        for identity in identities { MerchantPreferences.shared.removePreference(identity: identity) }
        Task { await env.pushMerchantPreferences() }
    }

    /// Pull a newer backup (merging in rules made on another device), push local, then reload from the merged
    /// set. Unsaved edits in the list are replaced by the synced set.
    private func syncNow() {
        syncing = true
        Task {
            await env.syncMerchantPreferencesNow()
            drafts = MerchantPreferences.shared.prefs.map(MerchantPrefDraft.init)
            unsavedIDs.removeAll()
            syncing = false
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { MerchantPreferencesView() }
        .previewEnvironment()
}
#endif
