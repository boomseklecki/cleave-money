import Foundation
import SwiftData

/// Portable snapshot of the local-only review-queue state (split templates + dismissal decisions +
/// subscription rules), so they follow the user across devices. ids are regenerated on restore.
struct SuggestionSnapshot: Codable {
    var version: Int = 1
    var templates: [Template]
    var decisions: [Decision]
    /// Optional so a legacy blob (no `rules` key) still decodes - a missing key on a non-optional would throw
    /// and break templates/decisions restore too.
    var rules: [Rule]?

    struct Template: Codable {
        var merchantKey: String
        var groupId: UUID
        var category: String?
        var sharesJSON: String
        var source: String
        var displayName: String
    }
    struct Decision: Codable {
        var key: String
        var decision: String
        var snoozedUntil: Date?
    }
    struct Rule: Codable {
        var merchantKey: String
        var amount: Decimal
        var isSubscription: Bool
        var displayName: String
        var createdAt: Date
    }
}

/// Backs up `SplitTemplate` + `SuggestionDecision` to the per-owner preferences blob and restores on a new
/// device. Mirrors `CategorySync`: push on change, pull-if-newer on launch (last-write-wins by the blob's
/// `updated_at` vs a local watermark).
enum SuggestionSync {
    static let key = "suggestions.v1"
    private static let syncedAtKey = "suggestions.syncedAt"

    /// Clears the local sync watermark so the next `applyIfNewer` re-restores from the server blob. Needed on
    /// sign-out / cache wipe: `CleaveStore.eraseAll` drops the SwiftData rows, but without clearing the
    /// watermark `applyIfNewer` would think the device is up to date and skip the restore - silently losing the
    /// subscription rules / split templates / dismissals until a server-side change bumped the blob.
    static func reset() { UserDefaults.standard.removeObject(forKey: syncedAtKey) }

    @MainActor
    static func snapshot(_ context: ModelContext) throws -> SuggestionSnapshot {
        let templates = try context.fetch(FetchDescriptor<SplitTemplate>())
        let decisions = try context.fetch(FetchDescriptor<SuggestionDecision>())
        let rules = try context.fetch(FetchDescriptor<SubscriptionRule>())
        return SuggestionSnapshot(
            templates: templates.map {
                .init(merchantKey: $0.merchantKey, groupId: $0.groupId, category: $0.category,
                      sharesJSON: $0.sharesJSON, source: $0.source, displayName: $0.displayName)
            },
            decisions: decisions.map {
                .init(key: $0.key, decision: $0.decision, snoozedUntil: $0.snoozedUntil)
            },
            rules: rules.map {
                .init(merchantKey: $0.merchantKey, amount: $0.amount, isSubscription: $0.isSubscription,
                      displayName: $0.displayName, createdAt: $0.createdAt)
            })
    }

    @MainActor
    static func pushBestEffort(_ context: ModelContext, client: Client) async {
        guard let snap = try? snapshot(context), let data = try? JSONEncoder().encode(snap) else { return }
        if let updatedAt = await Preferences.put(key, String(decoding: data, as: UTF8.self), client: client) {
            UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        }
    }

    @MainActor
    @discardableResult
    static func applyIfNewer(from rows: [String: (value: String, updatedAt: Date)],
                             context: ModelContext) -> Bool {
        guard let row = rows[key], row.updatedAt.timeIntervalSince1970 > UserDefaults.standard.double(
            forKey: syncedAtKey) else { return false }
        guard let snap = try? JSONDecoder().decode(SuggestionSnapshot.self, from: Data(row.value.utf8)),
              (try? apply(snap, context)) != nil else { return false }
        UserDefaults.standard.set(row.updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        return true
    }

    @MainActor
    static func apply(_ snap: SuggestionSnapshot, _ context: ModelContext) throws {
        for t in try context.fetch(FetchDescriptor<SplitTemplate>()) { context.delete(t) }
        for d in try context.fetch(FetchDescriptor<SuggestionDecision>()) { context.delete(d) }
        for r in try context.fetch(FetchDescriptor<SubscriptionRule>()) { context.delete(r) }
        for t in snap.templates {
            context.insert(SplitTemplate(merchantKey: t.merchantKey, groupId: t.groupId, category: t.category,
                                         sharesJSON: t.sharesJSON, source: t.source, displayName: t.displayName))
        }
        for d in snap.decisions {
            context.insert(SuggestionDecision(key: d.key, decision: d.decision, snoozedUntil: d.snoozedUntil))
        }
        for r in snap.rules ?? [] {
            context.insert(SubscriptionRule(merchantKey: r.merchantKey, amount: r.amount,
                                            isSubscription: r.isSubscription, displayName: r.displayName,
                                            createdAt: r.createdAt))
        }
        try context.save()
    }
}
