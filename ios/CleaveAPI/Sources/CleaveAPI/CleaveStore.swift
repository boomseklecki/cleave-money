import Foundation
import SwiftData

/// Public entry point for the SwiftData cache. The app builds its `ModelContainer` through here so
/// it never names the internal `@Model` types directly (which also avoids the `Group`/`Transaction`
/// collisions with SwiftUI's same-named types).
public enum CleaveStore {
    /// All cached entities mirroring the server's source-of-truth tables.
    public static var schema: Schema {
        Schema([
            Group.self,
            Account.self,
            Transaction.self,
            TransactionItem.self,
            Expense.self,
            ExpenseItem.self,
            Split.self,
            Receipt.self,
            User.self,
            GroupMember.self,
            SyncCursor.self,
            Goal.self,
            CategoryMap.self,
            SpendCategory.self,
            GroupBalance.self,
            SubscriptionRule.self,
            SplitTemplate.self,
            SuggestionDecision.self,
            Friend.self
        ])
    }

    /// Builds the shared container. Pass `inMemory: true` for tests/previews.
    ///
    /// The store is only a cache (the server is source of truth), so if an existing on-disk store is
    /// incompatible with the current schema - e.g. after adding a model/field - discard it and rebuild
    /// rather than crashing on launch. The data simply re-syncs.
    public static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            guard !inMemory else { throw error }
            destroyStore(configuration)
            return try ModelContainer(for: schema, configurations: configuration)
        }
    }

    /// Deletes every cached row (all entities) from the live store, e.g. before switching backends so a
    /// production cache can't bleed into a development one. The store is only a cache, so it re-syncs on the
    /// next refresh. Mirrors `schema` - keep in sync when adding a model.
    public static func eraseAll(_ context: ModelContext) throws {
        try context.delete(model: Group.self)
        try context.delete(model: Account.self)
        try context.delete(model: Transaction.self)
        try context.delete(model: TransactionItem.self)
        try context.delete(model: Expense.self)
        try context.delete(model: ExpenseItem.self)
        try context.delete(model: Split.self)
        try context.delete(model: Receipt.self)
        try context.delete(model: User.self)
        try context.delete(model: GroupMember.self)
        try context.delete(model: SyncCursor.self)
        try context.delete(model: Goal.self)
        try context.delete(model: CategoryMap.self)
        try context.delete(model: SpendCategory.self)
        try context.delete(model: GroupBalance.self)
        try context.delete(model: SubscriptionRule.self)
        try context.delete(model: SplitTemplate.self)
        try context.delete(model: SuggestionDecision.self)
        try context.delete(model: Friend.self)
        try context.save()
    }

    /// Removes the SQLite store and its `-wal`/`-shm` sidecars so the next container build starts clean.
    private static func destroyStore(_ configuration: ModelConfiguration) {
        let store = configuration.url
        let sidecars = [store,
                        URL(fileURLWithPath: store.path + "-wal"),
                        URL(fileURLWithPath: store.path + "-shm")]
        for url in sidecars { try? FileManager.default.removeItem(at: url) }
    }
}
