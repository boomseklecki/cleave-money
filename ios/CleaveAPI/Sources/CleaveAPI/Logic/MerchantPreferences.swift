import Foundation

/// The user's explicit per-merchant brand/note overrides - deliberately separate from the auto `BrandGuessCache`
/// (which is a performance cache of non-user-chosen model guesses). Matched by `pattern` (substring/glob/regex,
/// via `BrandMatcher`) and an optional amount constraint (`amountMode` + `amount`). Local `UserDefaults` is
/// authoritative and instant; it also syncs to the per-owner preferences blob so choices follow the user across
/// devices (per-user, never household-shared). These are an explicit user choice, so they beat the catalog.
@MainActor
@Observable
final class MerchantPreferences {
    static let shared = MerchantPreferences()

    /// One override: `pattern` (+ optional amount constraint) -> a brand identity (`website` logo and/or `note`
    /// label). `amountMode` = .any ignores the amount; .close matches within `amountsClose`; .equal is exact.
    struct Pref: Codable, Equatable, Identifiable {
        var pattern: String
        var note: String
        var website: String
        var amount: Decimal?
        var amountMode: RelatedTransactions.AmountMatch
        var category: String?   // captured groundwork for a future auto-categorize; not applied yet

        var id: String { MerchantPreferences.identity(self) }

        init(pattern: String, note: String, website: String, amount: Decimal?,
             amountMode: RelatedTransactions.AmountMatch, category: String? = nil) {
            self.pattern = pattern; self.note = note; self.website = website
            self.amount = amount; self.amountMode = amountMode; self.category = category
        }

        // Backward-compatible: older blobs had no `amountMode` (treated a present amount as "close") or `category`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pattern = try c.decode(String.self, forKey: .pattern)
            note = (try? c.decode(String.self, forKey: .note)) ?? ""
            website = (try? c.decode(String.self, forKey: .website)) ?? ""
            amount = try? c.decode(Decimal.self, forKey: .amount)
            amountMode = (try? c.decode(RelatedTransactions.AmountMatch.self, forKey: .amountMode))
                ?? (amount == nil ? .any : .close)
            category = try? c.decode(String.self, forKey: .category)
        }
    }

    private(set) var prefs: [Pref]
    private var compiled: [(matches: (String) -> Bool, pref: Pref)] = []
    private var dirty = false

    private static let storeKey = "merchantPrefs"          // local UserDefaults blob
    private static let blobKey = "merchantPrefs.v1"        // per-owner preferences blob
    private static let syncedAtKey = "merchantPrefs.syncedAt"

    private init() { prefs = MerchantPreferences.load(); recompile() }

    /// Clears the in-memory + on-disk overrides and sync watermark so the prior owner's merchant rules don't
    /// carry into the next account, and the next launch re-restores that account's own blob (sign-out / wipe).
    func reset() {
        prefs = []
        recompile()
        dirty = false
        UserDefaults.standard.removeObject(forKey: MerchantPreferences.storeKey)
        UserDefaults.standard.removeObject(forKey: MerchantPreferences.syncedAtKey)
    }

    /// The override for a merchant `text` at `amount`, if a preference pattern matches and its amount constraint
    /// is satisfied. Among matches the first in the user's priority order wins (drag-to-reorder in the manager);
    /// amount gating already stops an exact/close rule from firing at the wrong amount, so order only decides
    /// between rules that match the same charge. A `website` pref uses it as the favicon; a note-only pref
    /// resolves its `note` through `resolveNote` (the normal pipeline, injected to avoid a dependency cycle).
    /// Reads `prefs` up front so a view resolving through here repaints when the set changes.
    func override(forText text: String, amount: Decimal?, resolveNote: @MainActor (String) -> Brand?) -> Brand? {
        guard !prefs.isEmpty else { return nil }
        let t = text.lowercased()
        for c in compiled where c.matches(t) {   // compiled is in the user's priority order
            switch c.pref.amountMode {
            case .any: break
            case .close:
                guard let have = amount, let want = c.pref.amount,
                      RelatedTransactions.amountsClose(have, want) else { continue }
            case .equal:
                guard let have = amount, let want = c.pref.amount, have == want else { continue }
            }
            if !c.pref.website.isEmpty {
                return Brand(name: c.pref.note.isEmpty ? c.pref.pattern : c.pref.note, domain: c.pref.website)
            }
            if !c.pref.note.isEmpty, let resolved = resolveNote(c.pref.note), resolved.domain != nil {
                return Brand(name: c.pref.note, domain: resolved.domain)  // keep the user's note as the label
            }
        }
        return nil
    }

    /// The category a matching preference assigns to a merchant `text` at `amount`, if any pref matches, its
    /// amount constraint holds, and it carries a non-empty category. Mirrors `override(forText:)`'s match loop
    /// (first matching rule in the user's priority order wins). Logo-only prefs (no category) return nil, so
    /// they never drive a category card.
    func matchedCategory(forText text: String, amount: Decimal?) -> String? {
        guard !prefs.isEmpty else { return nil }
        let t = text.lowercased()
        for c in compiled where c.matches(t) {   // compiled is in the user's priority order
            switch c.pref.amountMode {
            case .any: break
            case .close:
                guard let have = amount, let want = c.pref.amount,
                      RelatedTransactions.amountsClose(have, want) else { continue }
            case .equal:
                guard let have = amount, let want = c.pref.amount, have == want else { continue }
            }
            if let cat = c.pref.category, !cat.isEmpty { return cat }
        }
        return nil
    }

    /// Note-first category lookup (mirrors the note-first favicon): the user's note identity wins over the raw
    /// merchant string, so an "APPLE.COM/BILL" charge noted "Duolingo" picks up a Duolingo -> Education rule.
    func category(note: String?, merchant: String, amount: Decimal?) -> String? {
        if let note, !note.isEmpty, let c = matchedCategory(forText: note, amount: amount) { return c }
        return matchedCategory(forText: merchant, amount: amount)
    }

    /// Upsert a preference, deduped by (pattern, mode, amount). Re-saving the same identity updates it in place
    /// (position preserved). `prioritize` sorts same-merchant rules most-specific-first - on for the
    /// find-related quick-add default, off for the manager where manual drag-order is authoritative. Persists +
    /// marks dirty for the next push.
    func setPreference(pattern: String, note: String, website: String, amount: Decimal?,
                       amountMode: RelatedTransactions.AmountMatch, category: String? = nil,
                       prioritize: Bool = true) {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        let pref = Pref(pattern: p, note: note.trimmingCharacters(in: .whitespaces),
                        website: website.trimmingCharacters(in: .whitespaces),
                        amount: amountMode == .any ? nil : amount, amountMode: amountMode,
                        category: category?.isEmpty == false ? category : nil)
        if let idx = prefs.firstIndex(where: { MerchantPreferences.identity($0) == MerchantPreferences.identity(pref) }) {
            prefs[idx] = pref                              // update in place, keep position
        } else {
            prefs.append(pref)
        }
        if prioritize { prefs = MerchantPreferences.prioritized(prefs) }  // same-merchant rules: most specific first
        recompile(); dirty = true; save()
    }

    /// Prefs whose pattern matches the note or merchant text (amount ignored), in priority order. Lets the
    /// find-related screen surface every rule that already applies to the merchant you drilled in from.
    func matchingPrefs(note: String?, merchant: String) -> [Pref] {
        let texts = [note, merchant].compactMap { t -> String? in
            guard let t, !t.isEmpty else { return nil }
            return t.lowercased()
        }
        guard !texts.isEmpty else { return [] }
        return prefs.filter { pref in
            let matches = BrandMatcher.compile(pref.pattern)
            return texts.contains { matches($0) }
        }
    }

    /// Reorder the stored rules to match this identity order (any not listed keep their tail position). Drives
    /// the manager's Edit-mode drag reorder with per-row saves. Persists + marks dirty.
    func setOrder(_ identities: [String]) {
        let position = Dictionary(identities.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        prefs.sort {
            (position[MerchantPreferences.identity($0)] ?? Int.max) < (position[MerchantPreferences.identity($1)] ?? Int.max)
        }
        recompile(); dirty = true; save()
    }

    /// Replace the whole set (the brand-preferences manager edits a local copy and saves it back).
    func replaceAll(_ newPrefs: [Pref]) {
        prefs = newPrefs
        recompile(); dirty = true; save()
    }

    /// Delete the rule with this identity (from a swipe-to-delete). Persists + marks dirty so the deletion
    /// propagates on the next push (the sync is last-write-wins, so it won't resurrect).
    func removePreference(identity: String) {
        prefs.removeAll { MerchantPreferences.identity($0) == identity }
        recompile(); dirty = true; save()
    }

    /// Order same-pattern rules most-specific-first (equal > close > any) while keeping different patterns in
    /// their existing relative order. A smart default used only when a rule is added from the find-related
    /// screens, so a newly-saved exact/close-amount rule sorts above a broader one for the same merchant
    /// instead of landing at the bottom. The manager's manual drag-order goes through `replaceAll`, not here,
    /// so it stays authoritative.
    private static func prioritized(_ prefs: [Pref]) -> [Pref] {
        var firstIndex: [String: Int] = [:]
        for (i, p) in prefs.enumerated() where firstIndex[p.pattern.lowercased()] == nil {
            firstIndex[p.pattern.lowercased()] = i
        }
        return prefs.enumerated().sorted { a, b in
            let ka = firstIndex[a.element.pattern.lowercased()] ?? a.offset
            let kb = firstIndex[b.element.pattern.lowercased()] ?? b.offset
            if ka != kb { return ka < kb }                 // keep group order (by first appearance)
            let ra = rank(a.element.amountMode), rb = rank(b.element.amountMode)
            if ra != rb { return ra > rb }                 // most specific first within a same-pattern group
            return a.offset < b.offset                       // stable within the same rank
        }.map(\.element)
    }

    private static func rank(_ mode: RelatedTransactions.AmountMatch) -> Int {
        switch mode { case .equal: return 2; case .close: return 1; case .any: return 0 }
    }

    /// Identity for dedupe: pattern (case-insensitive) + amount mode + amount.
    nonisolated static func identity(_ p: Pref) -> String {
        let amt = p.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        return "\(p.pattern.lowercased())|\(p.amountMode.rawValue)|\(amt)"
    }

    private func recompile() {
        // Preserve the user's list order - first matching rule wins (drag-to-reorder in the manager = priority).
        compiled = prefs.map { (BrandMatcher.compile($0.pattern), $0) }
    }

    // MARK: Local persistence

    private static func load() -> [Pref] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let v = try? JSONDecoder().decode([Pref].self, from: data) else { return [] }
        return v
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        UserDefaults.standard.set(data, forKey: MerchantPreferences.storeKey)
    }

    // MARK: Cross-device sync (last-write-wins, mirrors SuggestionSync)

    private struct Snapshot: Codable { var version: Int = 1; var prefs: [Pref] }

    /// Adopt a newer server blob wholesale (last-write-wins by the blob's `updated_at` vs the local watermark),
    /// so a rule deleted on another device stays deleted here instead of resurrecting under a merge. Matches
    /// how `SuggestionSync` restores its set blob.
    func applyIfNewer(from rows: [String: (value: String, updatedAt: Date)]) {
        guard let row = rows[MerchantPreferences.blobKey],
              row.updatedAt.timeIntervalSince1970 > UserDefaults.standard.double(forKey: MerchantPreferences.syncedAtKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(row.value.utf8)) else { return }
        prefs = snap.prefs
        recompile()
        save()
        UserDefaults.standard.set(row.updatedAt.timeIntervalSince1970, forKey: MerchantPreferences.syncedAtKey)
    }

    /// Best-effort push to the per-owner blob. Dirty-gated; called at infrequent checkpoints.
    func pushBestEffort(client: Client) async {
        guard dirty else { return }
        guard let data = try? JSONEncoder().encode(Snapshot(prefs: prefs)) else { return }
        if let updatedAt = await Preferences.put(
            MerchantPreferences.blobKey, String(decoding: data, as: UTF8.self), client: client) {
            dirty = false
            UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: MerchantPreferences.syncedAtKey)
        }
    }
}
