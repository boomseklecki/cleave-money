import Foundation

/// Versioned snapshot of a reordering, for the preferences blob.
struct OrderSnapshot: Codable {
    var version: Int = 1
    var order: [String]
}

/// Backs up a locally-authoritative reordering (`@AppStorage(storageKey)`) of a `ReorderableSection` to the
/// per-owner preferences blob and restores it on a new device. Push on reorder, apply-if-newer on launch;
/// last-write-wins by the blob's `updated_at` vs a local watermark. One generic store serves tabs, Goals
/// sections, and any future reorderable list - see the `tabs` / `goals` instances below.
struct OrderPreference<Item: ReorderableSection> {
    let prefKey: String      // preferences blob key, e.g. "tabOrder.v1"
    let storageKey: String   // the @AppStorage / UserDefaults key the UI reads, e.g. "tabOrder"
    private var syncedAtKey: String { "\(storageKey).syncedAt" }

    /// The current order from local storage (tolerates missing/extra ids).
    @MainActor
    func current() -> [Item] {
        Item.parse(UserDefaults.standard.string(forKey: storageKey) ?? "")
    }

    /// Drops the local order + sync watermark so the next account starts from its own backup (sign-out / cache
    /// wipe): otherwise the prior owner's tab/goal order persists and the watermark skips the restore.
    @MainActor
    func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: syncedAtKey)
    }

    /// Persist a new order locally (the UI re-renders) - call before pushing.
    @MainActor
    func write(_ order: [Item]) {
        UserDefaults.standard.set(Item.serialize(order), forKey: storageKey)
    }

    /// Back up the current local order to the blob. Best-effort.
    @MainActor
    func pushBestEffort(client: Client) async {
        let snap = OrderSnapshot(order: current().map(\.rawValue))
        guard let data = try? JSONEncoder().encode(snap) else { return }
        if let updatedAt = await Preferences.put(prefKey, String(decoding: data, as: UTF8.self), client: client) {
            UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        }
    }

    /// Apply the backed-up order from a prefetched preferences set when it's newer than the local watermark.
    @MainActor
    @discardableResult
    func applyIfNewer(from rows: [String: (value: String, updatedAt: Date)]) -> Bool {
        guard let row = rows[prefKey], row.updatedAt.timeIntervalSince1970 > UserDefaults.standard.double(
            forKey: syncedAtKey) else { return false }
        guard let snap = try? JSONDecoder().decode(OrderSnapshot.self, from: Data(row.value.utf8)) else {
            return false
        }
        UserDefaults.standard.set(Item.serialize(Item.parse(snap.order.joined(separator: ","))),
                                  forKey: storageKey)
        UserDefaults.standard.set(row.updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        return true
    }
}

extension OrderPreference where Item == MainTab {
    static var tabs: OrderPreference<MainTab> { .init(prefKey: "tabOrder.v1", storageKey: "tabOrder") }
}

extension OrderPreference where Item == GoalSection {
    static var goals: OrderPreference<GoalSection> { .init(prefKey: "goalsOrder.v1", storageKey: "goalsOrder") }
}
