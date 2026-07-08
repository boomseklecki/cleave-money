import Foundation

/// Memoizes the pure-but-O(n) `SubscriptionDetector.analyze` so the Inbox doesn't re-run cadence detection on
/// every `current()` call (reload paints 3×, plus the badge path). Keyed on a *precise* content signature of
/// only the inputs that change the result - so partner / category-override / dismissal churn is a cache hit.
/// Lives once on `AppEnvironment` and is shared by every `SuggestionService` it builds.
@MainActor
final class SuggestionAnalysisCache {
    private var key: Int?
    private var subscriptions: [Subscription] = []
    private var detKey: Int?
    private var deterministic: [Suggestion] = []

    /// Returns the cached subscriptions when the inputs are unchanged, else recomputes + stores.
    func subscriptions(transactions: [Transaction], expenses: [Expense], lookup: [String: String],
                       me: String?, rules: [SubscriptionRule], asOf: Date) -> [Subscription] {
        let signature = Self.signature(transactions: transactions, expenses: expenses, me: me,
                                       rules: rules, asOf: asOf)
        if signature == key { return subscriptions }
        let result = SubscriptionDetector.analyze(
            transactions: transactions, expenses: expenses, lookup: lookup, me: me, rules: rules, asOf: asOf)
        key = signature
        subscriptions = result.subscriptions
        return subscriptions
    }

    /// Memoizes the heavy **deterministic** suggestion pass (Link + Subscription + Recurring-split) so the
    /// Inbox's 3-paints-per-reload - and accept/dismiss/AI-refresh that don't touch transactions/expenses - 
    /// reuse it instead of re-running the O(expenses × transactions) link match. Keyed on the subscription
    /// signature **plus** templates + linkThreshold (the extra inputs Link/recurring-split depend on); still
    /// excludes `aiSuggestedCategory`/overrides/partners/dismissals so those stay cache hits.
    func deterministicSuggestions(transactions: [Transaction], expenses: [Expense], me: String?,
                                  rules: [SubscriptionRule], templates: [SplitTemplate], asOf: Date,
                                  linkThreshold: Double, compute: () -> [Suggestion]) -> [Suggestion] {
        var h = Hasher()
        h.combine(Self.signature(transactions: transactions, expenses: expenses, me: me, rules: rules, asOf: asOf))
        for t in templates { h.combine(t.merchantKey) }
        h.combine(linkThreshold)
        let signature = h.finalize()
        if signature == detKey { return deterministic }
        deterministic = compute()
        detKey = signature
        return deterministic
    }

    /// Hash of only what `analyze` actually depends on: each txn's (id, amount, date), each expense's
    /// (id, linked-txn, amount, date), the rules, `me`, and the day. Deliberately excludes `aiSuggestedCategory`/
    /// `categoryOverride`/partners/decisions so an accept/dismiss elsewhere doesn't invalidate it. `lookup` only
    /// filters by category name, which doesn't affect cadence, so it's omitted too.
    private static func signature(transactions: [Transaction], expenses: [Expense], me: String?,
                                  rules: [SubscriptionRule], asOf: Date) -> Int {
        var h = Hasher()
        h.combine(transactions.count)
        for t in transactions {
            h.combine(t.id); h.combine(t.amount); h.combine(t.date)
        }
        h.combine(expenses.count)
        for e in expenses {
            h.combine(e.id); h.combine(e.transactionId); h.combine(e.amount); h.combine(e.date)
        }
        for r in rules { h.combine(r.merchantKey); h.combine(r.amount); h.combine(r.isSubscription) }
        h.combine(me)
        h.combine(Calendar.current.startOfDay(for: asOf))
        return h.finalize()
    }
}
