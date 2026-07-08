import Foundation

/// Per-user, cross-device cache of on-device brand guesses (merchant key -> resolved brand; a nil domain is a
/// remembered "no logo" so we stop re-running the model on the same miss). Shared by every per-view
/// `BrandModel`, so a merchant is guessed once per user rather than once per view and once per launch.
///
/// Local `UserDefaults` is authoritative and instant/offline. It also backs up to the per-owner preferences
/// blob (`applyIfNewer` on launch, `pushBestEffort` on background) so guesses follow the user to a new device.
/// It stays per-user, never household-shared, so a private transaction's merchant string does not leak between
/// members. `@Observable` so a row reading a guess through `BrandModel.logoURL` repaints when one is recorded.
@MainActor
@Observable
final class BrandGuessCache {
    static let shared = BrandGuessCache()

    struct Entry: Codable { var name: String; var domain: String? }

    private(set) var entries: [String: Entry]
    private var dirty = false

    private static let storeKey = "brandCache"          // local UserDefaults blob
    private static let blobKey = "brandCache.v1"        // per-owner preferences blob
    private static let syncedAtKey = "brandCache.syncedAt"
    private static let cap = 4000                            // bound the blob; merchants per user are far fewer

    private init() { entries = BrandGuessCache.loadLocal() }

    /// Clears the in-memory + on-disk cache and its sync watermark so the prior owner's brand guesses don't
    /// carry into the next account, and the next launch re-restores that account's own blob (sign-out / wipe).
    func reset() {
        entries = [:]
        dirty = false
        UserDefaults.standard.removeObject(forKey: BrandGuessCache.storeKey)
        UserDefaults.standard.removeObject(forKey: BrandGuessCache.syncedAtKey)
    }

    // MARK: Read / write (used by BrandModel)

    /// The cached guess for `key`, if one was recorded (may carry a nil domain = a remembered "no logo").
    func brand(forKey key: String) -> Brand? {
        guard let e = entries[key] else { return nil }
        return Brand(name: e.name, domain: e.domain)
    }

    /// Whether a guess (positive or negative) was already recorded, so `resolve` can skip re-running the model.
    func contains(_ key: String) -> Bool { entries[key] != nil }

    /// Remember a model result (positive or negative) and persist locally right away.
    func record(_ key: String, _ brand: Brand) {
        if entries[key] == nil, entries.count >= BrandGuessCache.cap, let drop = entries.keys.first {
            entries.removeValue(forKey: drop)  // safety valve; effectively never hit
        }
        entries[key] = Entry(name: brand.name, domain: brand.domain)
        dirty = true
        saveLocal()
    }

    // MARK: Local persistence

    private static func loadLocal() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return map
    }

    private func saveLocal() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: BrandGuessCache.storeKey)
    }

    // MARK: Cross-device sync (mirrors LinkSensitivitySync)

    private struct Snapshot: Codable { var version: Int = 1; var guesses: [String: Entry] }

    /// Merge a newer server blob into the local cache (union; local entries are kept on conflict).
    func applyIfNewer(from rows: [String: (value: String, updatedAt: Date)]) {
        guard let row = rows[BrandGuessCache.blobKey],
              row.updatedAt.timeIntervalSince1970 > UserDefaults.standard.double(forKey: BrandGuessCache.syncedAtKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(row.value.utf8)) else { return }
        for (k, v) in snap.guesses where entries[k] == nil { entries[k] = v }
        saveLocal()
        UserDefaults.standard.set(row.updatedAt.timeIntervalSince1970, forKey: BrandGuessCache.syncedAtKey)
    }

    /// Best-effort push of the guess map to the per-owner blob. Dirty-gated; called at infrequent checkpoints
    /// (launch bootstrap, app background), so no extra throttle is needed.
    func pushBestEffort(client: Client) async {
        guard dirty else { return }
        guard let data = try? JSONEncoder().encode(Snapshot(guesses: entries)) else { return }
        if let updatedAt = await Preferences.put(
            BrandGuessCache.blobKey, String(decoding: data, as: UTF8.self), client: client) {
            dirty = false
            UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: BrandGuessCache.syncedAtKey)
        }
    }
}
