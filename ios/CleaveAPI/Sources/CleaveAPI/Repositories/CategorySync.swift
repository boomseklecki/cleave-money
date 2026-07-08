import Foundation
import SwiftData

/// A portable snapshot of the per-user category config (taxonomy + raw→canonical map), versioned so the
/// shape can evolve. ids/timestamps are intentionally omitted - they're regenerated on restore.
struct CategorySnapshot: Codable {
    var version: Int = 1
    var categories: [Cat]
    var maps: [Map]

    struct Cat: Codable { var name: String; var icon: String?; var color: String?; var position: Int; var builtin: Bool }
    struct Map: Codable { var rawCategory: String; var canonicalCategory: String; var source: String }
}

/// Syncs the locally-authoritative categories + maps to the per-owner backend **relational** store
/// (`GET/PUT /categories`) and restores them on a new device. Push on edit, pull on launch. Last-write-wins
/// by the server's `updated_at` vs a locally-stored watermark, so a freshly-seeded new install restores the
/// backup instead of clobbering it (pull runs before any push at launch). (The legacy `categories.v1`
/// preferences blob was retired in Phase 5 - the relational store is the only sync path now.)
enum CategorySync {
    private static let syncedAtKey = "categories.syncedAt"

    /// Clears the local sync watermark so the next `applyIfNewer` re-restores categories from the server after
    /// a cache wipe (the SpendCategory/CategoryMap rows are dropped by `CleaveStore.eraseAll`).
    static func reset() { UserDefaults.standard.removeObject(forKey: syncedAtKey) }

    /// When categories were last pushed to / restored from the backend (nil if never).
    @MainActor
    static var lastSyncedAt: Date? {
        let t = UserDefaults.standard.double(forKey: syncedAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Manual "Sync now": restore a newer backup if one exists (e.g. edited on another device), otherwise
    /// back up this device's local categories. Best-effort; never throws.
    @MainActor
    static func syncNow(_ context: ModelContext, client: Client) async {
        let config = try? await client.get_categories_categories_get().ok.body.json
        if applyIfNewer(config: config, context: context) { return }  // newer remote → already in sync
        await pushBestEffort(context, client: client)                 // else back up local
    }

    @MainActor
    static func snapshot(_ context: ModelContext) throws -> CategorySnapshot {
        let cats = try context.fetch(
            FetchDescriptor<SpendCategory>(sortBy: [SortDescriptor(\.position)]))
        let maps = try context.fetch(FetchDescriptor<CategoryMap>())
        return CategorySnapshot(
            categories: cats.map {
                .init(name: $0.name, icon: $0.icon, color: $0.color, position: $0.position, builtin: $0.builtin)
            },
            maps: maps.map {
                .init(rawCategory: $0.rawCategory, canonicalCategory: $0.canonicalCategory, source: $0.source)
            })
    }

    /// Replace-set the caller's categories + maps in the relational store (`PUT /categories`) and record the
    /// server's `updated_at` as the local watermark. Best-effort: an offline failure is swallowed (the next
    /// edit or launch retries).
    @MainActor
    static func pushBestEffort(_ context: ModelContext, client: Client) async {
        guard PreferenceSyncGate.restored else { return }  // never push before this session's restore ran
        guard let snap = try? snapshot(context) else { return }
        // Clobber guard: a just-wiped device re-seeds the builtins and has no watermark yet. Never let that
        // empty/builtin-only set replace-set (`PUT /categories`) over the server's real categories/maps before
        // we've pulled - that destroys another device's data server-side (this is what lost matt's custom
        // categories). Once we've synced at least once, an all-builtin push is a legit "user cleared everything".
        if lastSyncedAt == nil, snap.maps.isEmpty, !snap.categories.contains(where: { !$0.builtin }) {
            return
        }
        let body = Components.Schemas.CategoryConfigUpsert(
            categories: snap.categories.map {
                .init(name: $0.name, icon: $0.icon, color: $0.color, position: $0.position, builtin: $0.builtin)
            },
            maps: snap.maps.map {
                .init(raw_category: $0.rawCategory, canonical_category: $0.canonicalCategory, source: $0.source)
            })
        guard let updatedAt = (try? await client.put_categories_categories_put(body: .json(body)).ok.body.json)?
            .updated_at else { return }
        UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
    }

    /// Restore when the relational store has a newer set than we last applied (e.g. a new phone). No-op when
    /// it's empty or we're already up to date. Returns whether it applied a restore.
    @MainActor
    @discardableResult
    static func applyIfNewer(config: Components.Schemas.CategoryConfig?,
                             context: ModelContext) -> Bool {
        guard let config, !(config.categories ?? []).isEmpty,
              let updatedAt = config.updated_at,
              updatedAt.timeIntervalSince1970 > UserDefaults.standard.double(forKey: syncedAtKey),
              (try? apply(snapshot(from: config), context)) != nil else { return false }
        UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        return true
    }

    /// Convert a server `CategoryConfig` into the local `CategorySnapshot` (reuses `apply`).
    private static func snapshot(from config: Components.Schemas.CategoryConfig) -> CategorySnapshot {
        CategorySnapshot(
            categories: (config.categories ?? []).compactMap { c in
                guard !c.name.isEmpty else { return nil }
                return .init(name: c.name, icon: c.icon, color: c.color, position: c.position ?? 0, builtin: c.builtin ?? false)
            },
            maps: (config.maps ?? []).compactMap { m in
                guard !m.raw_category.isEmpty, !m.canonical_category.isEmpty else { return nil }
                return .init(rawCategory: m.raw_category, canonicalCategory: m.canonical_category,
                             source: m.source ?? "manual")
            })
    }

    /// Replace local categories + maps with the snapshot, then forward-fill any built-in missing from an
    /// older blob and rebuild the icon cache.
    @MainActor
    static func apply(_ snap: CategorySnapshot, _ context: ModelContext) throws {
        for c in try context.fetch(FetchDescriptor<SpendCategory>()) { context.delete(c) }
        for m in try context.fetch(FetchDescriptor<CategoryMap>()) { context.delete(m) }
        for c in snap.categories {
            context.insert(SpendCategory(
                id: UUID(), name: c.name, builtin: c.builtin, position: c.position, icon: c.icon, color: c.color))
        }
        let now = Date()
        for m in snap.maps {
            context.insert(CategoryMap(
                id: UUID(), rawCategory: m.rawCategory, canonicalCategory: m.canonicalCategory,
                source: m.source, createdAt: now, updatedAt: now))
        }
        try context.save()
        CategorySeed.ensureBuiltins(context)
        CategoryCatalog.shared.update(try context.fetch(FetchDescriptor<SpendCategory>()))
    }
}
