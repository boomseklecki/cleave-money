import Foundation
import SwiftData

/// A learned "how this merchant is split" template, applied by the review queue when a matching charge
/// lands ("split like last time"). Local-only and per-device (like `SubscriptionRule`); keyed by the
/// normalized merchant so it upserts. `source` is "auto" (derived from history) or "explicit" (the user
/// tapped "Remember this split").
@Model
final class SplitTemplate {
    @Attribute(.unique) var merchantKey: String
    var groupId: UUID
    var category: String?
    /// JSON `[userIdentifier: fraction]` of the owed split (fractions sum to ~1).
    var sharesJSON: String
    var source: String
    var displayName: String
    var createdAt: Date
    var updatedAt: Date

    init(merchantKey: String, groupId: UUID, category: String?, sharesJSON: String,
         source: String, displayName: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.merchantKey = merchantKey
        self.groupId = groupId
        self.category = category
        self.sharesJSON = sharesJSON
        self.source = source
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The decoded owed-split fractions by user identifier.
    var shares: [String: Double] {
        (try? JSONDecoder().decode([String: Double].self, from: Data(sharesJSON.utf8))) ?? [:]
    }

    /// Encodes fractions to the stored JSON string.
    static func encode(_ shares: [String: Double]) -> String {
        (try? JSONEncoder().encode(shares)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
