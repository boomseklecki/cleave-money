import Foundation
import SwiftData

/// Tracks the last successful sync time per collection so list refreshes can pass `updated_since`
/// and pull only changes. A full refresh (no cursor) is used periodically to reconcile deletes,
/// which `updated_since` does not report.
@Model
final class SyncCursor {
    @Attribute(.unique) var collection: String
    var lastSyncedAt: Date

    init(collection: String, lastSyncedAt: Date) {
        self.collection = collection
        self.lastSyncedAt = lastSyncedAt
    }
}
