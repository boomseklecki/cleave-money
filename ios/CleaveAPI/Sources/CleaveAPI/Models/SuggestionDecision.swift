import Foundation
import SwiftData

/// A user's decision on a review-queue suggestion, so we don't re-nag. Accepted suggestions self-resolve
/// via their underlying mutation (a category override, a link, ...); this records dismissals and snoozes.
/// `key` is the suggestion's stable id, or a `merchant:<key>` scope for "never for this merchant".
/// Local-only and per-device.
@Model
final class SuggestionDecision {
    @Attribute(.unique) var key: String
    var decision: String   // "dismissed" | "snoozed"
    var snoozedUntil: Date?
    var createdAt: Date

    init(key: String, decision: String, snoozedUntil: Date? = nil, createdAt: Date = Date()) {
        self.key = key
        self.decision = decision
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
    }

    /// Whether this decision currently suppresses its suggestion (dismissed forever, or snoozed and not yet
    /// past the snooze time).
    var isActive: Bool {
        if decision == "snoozed", let until = snoozedUntil { return until > Date() }
        return decision == "dismissed"
    }
}
