import Foundation
import SwiftData

/// Seeds the built-in canonical categories into local storage when they're missing. Categories are
/// local-authoritative (per user, synced to the relational backend via `CategorySync`), so a fresh install
/// needs the built-ins on device; this also forward-fills any built-in added in a newer app version after a
/// restore.
enum CategorySeed {
    @MainActor
    static func ensureBuiltins(_ context: ModelContext) {
        guard let existing = try? context.fetch(FetchDescriptor<SpendCategory>()) else { return }
        let names = Set(existing.map(\.name))
        var position = existing.map(\.position).max() ?? -1
        var added = false
        for name in CanonicalCategory.all where !names.contains(name) {
            position += 1
            context.insert(SpendCategory(id: UUID(), name: name, builtin: true, position: position))
            added = true
        }
        if added {
            try? context.save()
            CategoryCatalog.shared.update((try? context.fetch(FetchDescriptor<SpendCategory>())) ?? [])
        }
    }
}
