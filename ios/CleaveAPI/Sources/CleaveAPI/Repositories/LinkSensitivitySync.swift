import Foundation

/// Backs the locally-authoritative `LinkSensitivity` (`@AppStorage("linkSensitivity")`) up to the per-owner
/// preferences blob so the choice follows the user across devices. Push on change, apply-if-newer on launch;
/// last-write-wins by the blob's `updated_at` vs a local watermark - mirrors `OrderPreference`/`CategorySync`.
/// The suggestion engine keeps reading `LinkSensitivity.current()` unchanged.
enum LinkSensitivitySync {
    static let key = "linkSensitivity.v1"
    private static let syncedAtKey = "linkSensitivity.syncedAt"

    /// Drops the local choice + sync watermark so the next account starts from its own backup (sign-out /
    /// cache wipe): otherwise the prior owner's link-sensitivity persists and the watermark skips the restore.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: LinkSensitivity.storageKey)
        UserDefaults.standard.removeObject(forKey: syncedAtKey)
    }

    private struct Snapshot: Codable { var version: Int = 1; var value: String }

    /// Back up the current choice to the blob. Best-effort.
    @MainActor
    static func pushBestEffort(client: Client) async {
        let snap = Snapshot(value: LinkSensitivity.current().rawValue)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        if let updatedAt = await Preferences.put(key, String(decoding: data, as: UTF8.self), client: client) {
            UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        }
    }

    /// Restore from a prefetched preferences set when the blob is newer than the local watermark.
    @MainActor
    @discardableResult
    static func applyIfNewer(from rows: [String: (value: String, updatedAt: Date)]) -> Bool {
        guard let row = rows[key], row.updatedAt.timeIntervalSince1970 > UserDefaults.standard.double(
            forKey: syncedAtKey) else { return false }
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: Data(row.value.utf8)),
              LinkSensitivity(rawValue: snap.value) != nil else { return false }
        UserDefaults.standard.set(snap.value, forKey: LinkSensitivity.storageKey)
        UserDefaults.standard.set(row.updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        return true
    }
}
