import SwiftUI

/// An editable draft of a `MerchantPreferences.Pref`, shared by the manager and the find-related screens so
/// both build the same rows. `originalIdentity` remembers the stored rule this came from (nil = new/unsaved)
/// and is refreshed on save; it and `id` are excluded from equality so dirty detection tracks only edits.
struct MerchantPrefDraft: Identifiable, Equatable {
    let id = UUID()
    var pattern: String
    var note: String
    var website: String
    var amountModeRaw: String
    var amountStr: String
    var category: String?
    var originalIdentity: String?

    init(_ p: MerchantPreferences.Pref) {
        pattern = p.pattern; note = p.note; website = p.website
        amountModeRaw = p.amountMode.rawValue
        amountStr = p.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        category = p.category
        originalIdentity = MerchantPreferences.identity(p)
    }

    init(pattern: String = "", note: String = "", website: String = "",
         amountMode: RelatedTransactions.AmountMatch = .any, amountStr: String = "", category: String? = nil) {
        self.pattern = pattern; self.note = note; self.website = website
        amountModeRaw = amountMode.rawValue; self.amountStr = amountStr; self.category = category
        originalIdentity = nil
    }

    static func == (a: MerchantPrefDraft, b: MerchantPrefDraft) -> Bool {
        a.pattern == b.pattern && a.note == b.note && a.website == b.website
            && a.amountModeRaw == b.amountModeRaw && a.amountStr == b.amountStr && a.category == b.category
    }

    var trimmedPattern: String { pattern.trimmingCharacters(in: .whitespaces) }
    var amountMode: RelatedTransactions.AmountMatch {
        RelatedTransactions.AmountMatch(rawValue: amountModeRaw) ?? .any
    }

    func toPref() -> MerchantPreferences.Pref? {
        let pat = trimmedPattern
        guard !pat.isEmpty else { return nil }
        let amount = amountMode == .any ? nil : Decimal(string: amountStr.trimmingCharacters(in: .whitespaces))
        return MerchantPreferences.Pref(pattern: pat, note: note.trimmingCharacters(in: .whitespaces),
                                        website: website.trimmingCharacters(in: .whitespaces),
                                        amount: amount, amountMode: amountMode, category: category)
    }
}

/// A collapsible merchant-preference row: collapsed to an avatar + name + "category / amount" summary; expands
/// to the shared `MerchantPrefEditor` with its own dirty-gated Save. In a List's edit mode it stays collapsed
/// (so the drag handle/delete take over); otherwise it expands to edit. Used by the manager and the
/// find-related Merchant Preferences section.
struct MerchantPrefCard: View {
    @Binding var draft: MerchantPrefDraft
    /// Persist this row - the parent decides upsert vs prioritize + push; called from the inline Save.
    var onSave: () -> Void
    /// Report this row's unsaved state so the screen's leave-guard knows.
    var onDirtyChange: (Bool) -> Void = { _ in }

    @Environment(\.editMode) private var editMode
    @State private var baseline: MerchantPrefDraft
    @State private var expanded: Bool
    @State private var picking = false

    init(draft: Binding<MerchantPrefDraft>, initiallyExpanded: Bool = false,
         onSave: @escaping () -> Void, onDirtyChange: @escaping (Bool) -> Void = { _ in }) {
        _draft = draft
        self.onSave = onSave
        self.onDirtyChange = onDirtyChange
        _baseline = State(initialValue: draft.wrappedValue)
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var isDirty: Bool { draft != baseline }
    /// A never-saved row is savable even when it still matches its seed (so you can accept the defaults).
    private var isNew: Bool { draft.originalIdentity == nil }
    private var hasUnsaved: Bool { isNew || isDirty }
    private var editing: Bool { editMode?.wrappedValue.isEditing == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editing {
                summaryRow                              // reorder/delete take over in edit mode
            } else {
                Button { withAnimation { expanded.toggle() } } label: {
                    HStack(spacing: 12) {
                        if expanded {
                            Text(title).font(.headline).lineLimit(1)   // compact header (the editor has the avatar)
                        } else {
                            summaryRow
                        }
                        Spacer(minLength: 8)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    MerchantPrefEditor(
                        name: $draft.note, website: $draft.website, pattern: $draft.pattern,
                        amountModeRaw: $draft.amountModeRaw, amountStr: $draft.amountStr,
                        category: draft.category, onPickCategory: { picking = true })
                    Button {
                        onSave()
                        baseline = draft
                        onDirtyChange(hasUnsaved)   // false once saved (identity set -> no longer new)
                        withAnimation { expanded = false }
                    } label: {
                        Label(hasUnsaved ? "Save" : "Saved",
                              systemImage: hasUnsaved ? "square.and.arrow.down" : "checkmark.circle.fill")
                    }
                    .disabled(!hasUnsaved || draft.trimmedPattern.isEmpty)
                }
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $picking) {
            CategoryPickerView(current: draft.category, onReset: { draft.category = nil }) { draft.category = $0 }
        }
        .onChange(of: draft) { onDirtyChange(hasUnsaved) }
    }

    private var title: String {
        if !draft.note.isEmpty { return draft.note }
        let pat = draft.trimmedPattern
        return pat.isEmpty ? "New rule" : pat
    }

    /// "category / amount" (amount: Close -> "~$10", Equal -> "$10", Any -> omitted); falls back to the pattern.
    private var subtitle: String? {
        let cat = (draft.category?.isEmpty == false) ? draft.category : nil
        let amount: String? = {
            guard draft.amountMode != .any,
                  let d = Decimal(string: draft.amountStr.trimmingCharacters(in: .whitespaces)) else { return nil }
            return (draft.amountMode == .close ? "~" : "") + d.currency("USD")
        }()
        let parts = [cat, amount].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        let pat = draft.trimmedPattern
        return pat.isEmpty ? nil : pat
    }

    private var summaryRow: some View {
        let hasCategory = !(draft.category ?? "").isEmpty
        let catSymbol = hasCategory ? categorySymbol(draft.category) : nil
        let site = draft.website.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 12) {
            AvatarView(url: site.isEmpty ? nil : Brand(name: "", domain: site).logoURL,
                       name: title, size: 30, systemImage: catSymbol, logo: true,
                       badgeSystemImage: catSymbol, badgeColor: categoryColor(draft.category))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}
