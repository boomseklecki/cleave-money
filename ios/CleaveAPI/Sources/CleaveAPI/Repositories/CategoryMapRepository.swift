import Foundation
import SwiftData

/// The raw-Plaid → canonical category map. Local-authoritative (per user): the map is computed on-device
/// (see `CategoryMapper`) or chosen manually, written to SwiftData, then synced to the per-owner relational
/// backend (`/categories`) via `CategorySync`.
@MainActor
struct CategoryMapRepository {
    let client: Client
    let context: ModelContext

    /// Upserts one mapping by raw label (`source` is "manual" or "ondevice") and pushes a best-effort backup.
    func set(raw: String, canonical: String, source: String) async throws {
        let now = Date()
        if let existing = try context.fetch(
            FetchDescriptor<CategoryMap>(predicate: #Predicate { $0.rawCategory == raw })
        ).first {
            existing.canonicalCategory = canonical
            existing.source = source
            existing.updatedAt = now
        } else {
            context.insert(CategoryMap(
                id: UUID(), rawCategory: raw, canonicalCategory: canonical, source: source,
                createdAt: now, updatedAt: now))
        }
        try context.save()
        await CategorySync.pushBestEffort(context, client: client)
    }

    /// Upserts many mappings by raw label in a single save + one best-effort backup (vs N of each via `set`).
    /// Used by the on-device bulk categorize; the single `set` stays for the manual per-row picker.
    func setMany(_ mappings: [(raw: String, canonical: String)], source: String) async throws {
        guard !mappings.isEmpty else { return }
        let now = Date()
        var byRaw = Dictionary(
            try context.fetch(FetchDescriptor<CategoryMap>()).map { ($0.rawCategory, $0) },
            uniquingKeysWith: { a, _ in a })
        for (raw, canonical) in mappings {
            if let row = byRaw[raw] {
                row.canonicalCategory = canonical
                row.source = source
                row.updatedAt = now
            } else {
                let m = CategoryMap(id: UUID(), rawCategory: raw, canonicalCategory: canonical,
                                    source: source, createdAt: now, updatedAt: now)
                context.insert(m)
                byRaw[raw] = m
            }
        }
        try context.save()
        await CategorySync.pushBestEffort(context, client: client)
    }
}
