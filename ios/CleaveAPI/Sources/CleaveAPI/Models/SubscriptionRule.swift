import Foundation
import SwiftData

/// A user override for subscription detection, keyed by normalized merchant + a reference amount.
/// `isSubscription` true force-includes a recurring charge the detector skipped (e.g. "Claude AI");
/// false excludes a false positive (e.g. a recurring split expense). The amount carries a buffer so a
/// streaming price increase keeps matching (see `SubscriptionDetector.matches`). Local-only (the whole
/// subscriptions feature is on-device).
@Model
final class SubscriptionRule {
    var merchantKey: String
    var amount: Decimal
    var isSubscription: Bool
    var displayName: String
    var createdAt: Date

    init(merchantKey: String, amount: Decimal, isSubscription: Bool, displayName: String,
         createdAt: Date = Date()) {
        self.merchantKey = merchantKey
        self.amount = amount
        self.isSubscription = isSubscription
        self.displayName = displayName
        self.createdAt = createdAt
    }
}
