import Foundation
import SwiftData

/// The editable canonical category taxonomy. Categories are local-authoritative (per user) and sync to the
/// per-owner relational backend (`/categories`) via `CategorySync`, so mutations write SwiftData and then push
/// a best-effort sync. After any change it refreshes `CategoryCatalog` so `categorySymbol` honors custom
/// icons. (Built-ins are seeded by `CategorySeed`; restore happens via `CategorySync.applyIfNewer`.)
@MainActor
struct CategoryRepository {
    let client: Client
    let context: ModelContext

    @discardableResult
    func create(name: String, icon: String?, color: String? = nil) async throws -> UUID {
        let position = (try context.fetch(FetchDescriptor<SpendCategory>()).map(\.position).max() ?? -1) + 1
        let category = SpendCategory(id: UUID(), name: name, builtin: false, position: position,
                                     icon: icon, color: color)
        context.insert(category)
        try save()
        await CategorySync.pushBestEffort(context, client: client)
        return category.id
    }

    /// Rename and/or set the icon/color. `name`/`icon` nil = unchanged. `color` is a double-optional: omit it
    /// (`.none`) to leave it, pass `.some(nil)` to clear back to the deterministic palette, or `.some(hex)` to set.
    func update(id: UUID, name: String? = nil, icon: String? = nil, color: String?? = .none) async throws {
        guard let category = try context.fetch(
            FetchDescriptor<SpendCategory>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        if let name { category.name = name }
        if let icon { category.icon = icon }
        if let color { category.color = color }  // .some(nil) clears to Auto; .none leaves unchanged
        try save()
        await CategorySync.pushBestEffort(context, client: client)
    }

    func delete(id: UUID) async throws {
        guard let category = try context.fetch(
            FetchDescriptor<SpendCategory>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        context.delete(category)
        try save()
        await CategorySync.pushBestEffort(context, client: client)
    }

    /// Persist and rebuild the icon cache `categorySymbol` reads.
    private func save() throws {
        try context.save()
        CategoryCatalog.shared.update(try context.fetch(FetchDescriptor<SpendCategory>()))
    }
}
