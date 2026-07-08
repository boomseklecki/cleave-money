import Foundation

/// How often a subscription recurs. `periodsPerYear` drives the estimated annual cost.
enum SubscriptionCadence: CaseIterable {
    case weekly, biweekly, monthly, quarterly, yearly

    var periodsPerYear: Decimal {
        switch self {
        case .weekly: return 52
        case .biweekly: return 26
        case .monthly: return 12
        case .quarterly: return 4
        case .yearly: return 1
        }
    }
    var days: Int {
        switch self {
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        case .quarterly: return 91
        case .yearly: return 365
        }
    }
    var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        }
    }
    /// Compact amount suffix, e.g. "$15.99/mo".
    var unit: String {
        switch self {
        case .weekly: return "wk"
        case .biweekly: return "2wk"
        case .monthly: return "mo"
        case .quarterly: return "qtr"
        case .yearly: return "yr"
        }
    }

    /// Maps a median inter-charge interval (in days) to a cadence band, or nil if it's not regular.
    static func classify(medianDays: Double) -> SubscriptionCadence? {
        switch medianDays {
        case 5...9: return .weekly
        case 11...17: return .biweekly
        case 24...37: return .monthly
        case 80...100: return .quarterly
        case 330...400: return .yearly
        default: return nil
        }
    }
}

/// One charge behind a detected subscription, for the history list (drills into the txn/expense).
struct SubscriptionCharge: Identifiable {
    let id: String
    let source: EventSource
    let date: Date
    let amount: Decimal
}

/// A recurring charge detected on-device: its cadence, latest/prior amount, predicted next date, and the
/// charges behind it. `amount` is the gross transaction or, for a shared expense, your owed share.
struct Subscription: Identifiable {
    let id: String           // normalized merchant key (stable grouping id)
    let displayName: String  // cleaned merchant; the brand model refines this for display
    let cadence: SubscriptionCadence
    let latestAmount: Decimal
    let priorAmount: Decimal?
    let currency: String
    let nextDate: Date
    let lastDate: Date
    let isShared: Bool
    let charges: [SubscriptionCharge]  // most-recent first

    var increased: Bool { priorAmount.map { latestAmount > $0 } ?? false }
    var increaseFrom: Decimal? { increased ? priorAmount : nil }
    var annualCost: Decimal { latestAmount * cadence.periodsPerYear }
    /// Amount normalized to a monthly figure (for the "per month" total).
    var monthlyEquivalent: Decimal { annualCost / 12 }
}

/// A near-miss recurring merchant the auto-detector skipped (regular-ish dates but it didn't meet the
/// strict bar). Surfaced in the "Possible" list so the user can promote it with one tap.
struct SubscriptionCandidate: Identifiable {
    let id: String           // normalized merchant key
    let displayName: String
    let amount: Decimal      // representative (median) amount
    let cadence: SubscriptionCadence?
    let occurrences: Int
    let isShared: Bool
}

/// Pure, on-device recurring-charge detection across all categories. No model required (the brand/logo
/// step is separate); deterministic and unit-tested.
enum SubscriptionDetector {
    private struct Event {
        let date: Date
        let amount: Decimal
        let currency: String
        let source: EventSource
        let shared: Bool
    }

    /// Auto-detected subscriptions only (no manual rules). Thin wrapper over `analyze`.
    static func detect(transactions: [Transaction], expenses: [Expense],
                       lookup: [String: String], me: String?, asOf: Date = Date()) -> [Subscription] {
        analyze(transactions: transactions, expenses: expenses, lookup: lookup, me: me,
                rules: [], asOf: asOf).subscriptions
    }

    /// Subscriptions + near-miss candidates, honoring the user's manual rules. An exclude rule drops a
    /// merchant's matching charges; an include rule force-builds a subscription from them.
    static func analyze(transactions: [Transaction], expenses: [Expense], lookup: [String: String],
                        me: String?, rules: [SubscriptionRule], asOf: Date = Date())
        -> (subscriptions: [Subscription], candidates: [SubscriptionCandidate]) {
        // A shared subscription is represented by its expense share, so skip the linked gross transaction
        // (mirrors SpendingAnalytics' dedupe).
        let linkedTxnIds = Set(expenses.lazy.compactMap(\.transactionId))
        var byKey: [String: [Event]] = [:]

        for t in transactions where t.source == .plaid || t.source == .manual || t.source == .simplefin {
            guard t.amount > 0, !linkedTxnIds.contains(t.id) else { continue }
            let cat = CategoryMapping.effectiveCategory(for: t, lookup: lookup)
            if let cat, CanonicalCategory.excludedFromSpend.contains(cat) { continue }  // transfer/income
            let key = MerchantText.key(t.details)
            guard !key.isEmpty else { continue }
            byKey[key, default: []].append(
                Event(date: t.date, amount: t.amount, currency: t.currency,
                      source: .transaction(t), shared: false))
        }

        if let me {
            for e in expenses {
                guard let cat = e.category.flatMap({ CategoryMapping.canonical($0, lookup: lookup) }),
                      !CanonicalCategory.neutral.contains(cat),
                      !CanonicalCategory.incomeLike.contains(cat) else { continue }
                let share = e.splits.first { $0.userIdentifier == me }?.owedShare ?? 0
                guard share > 0 else { continue }
                let key = MerchantText.key(e.details)
                guard !key.isEmpty else { continue }
                byKey[key, default: []].append(
                    Event(date: e.date, amount: share, currency: e.currency,
                          source: .expense(e), shared: true))
            }
        }

        let rulesByKey = Dictionary(grouping: rules, by: \.merchantKey)
        var subs: [Subscription] = []
        var cands: [SubscriptionCandidate] = []
        for (key, allEvents) in byKey {
            let keyRules = rulesByKey[key] ?? []
            let kept = allEvents.filter { e in
                !keyRules.contains { !$0.isSubscription && matches(amount: e.amount, rule: $0) }
            }
            guard !kept.isEmpty else { continue }
            let forced = kept.filter { e in
                keyRules.contains { $0.isSubscription && matches(amount: e.amount, rule: $0) }
            }
            if !forced.isEmpty {
                if let s = forcedSubscription(key: key, events: forced, asOf: asOf) { subs.append(s) }
                continue  // one outcome per merchant
            }
            switch classify(key: key, events: kept, asOf: asOf) {
            case let .subscription(s): subs.append(s)
            case let .candidate(c): cands.append(c)
            case .none: break
            }
        }
        return (subs.sorted { $0.annualCost > $1.annualCost }, cands.sorted { $0.amount > $1.amount })
    }

    /// Whether a charge amount falls within a rule's ~2× band (so a price increase keeps matching).
    static func matches(amount: Decimal, rule: SubscriptionRule) -> Bool {
        let a = nsDouble(amount), b = nsDouble(rule.amount)
        guard a > 0, b > 0 else { return false }
        return max(a, b) / min(a, b) <= 2.0
    }

    private enum Outcome { case subscription(Subscription), candidate(SubscriptionCandidate), none }

    /// Auto classification of a merchant group: a subscription if it meets the strict bar, a candidate if
    /// it's a plausible near-miss (regular-ish dates), else nothing.
    private static func classify(key: String, events rawEvents: [Event], asOf: Date) -> Outcome {
        let events = rawEvents.sorted { $0.date < $1.date }
        guard events.count >= 2 else { return .none }
        let ivals = intervals(events)
        guard !ivals.isEmpty, let cadence = SubscriptionCadence.classify(medianDays: median(ivals))
        else { return .none }
        let band = Double(cadence.days)
        let regularity = Double(ivals.filter { abs($0 - band) <= band * 0.4 }.count) / Double(ivals.count)
        let medAmount = median(events.map(\.amount))
        let amountClusters = medAmount > 0 && events.allSatisfy { let r = $0.amount / medAmount; return r >= 0.5 && r <= 1.8 }
        let enough = events.count >= (cadence == .yearly ? 2 : 3)
        if enough && regularity >= 0.6 && amountClusters {
            return .subscription(makeSubscription(key: key, events: events, cadence: cadence))
        }
        if events.count >= 3 && regularity >= 0.5 {
            return .candidate(SubscriptionCandidate(
                id: key, displayName: displayName(key), amount: medAmount, cadence: cadence,
                occurrences: events.count, isShared: events.contains { $0.shared }))
        }
        return .none
    }

    /// Build a subscription for an include-ruled merchant, bypassing the strict guards (cadence from the
    /// median interval, defaulting to monthly when it can't be classified).
    private static func forcedSubscription(key: String, events rawEvents: [Event], asOf: Date) -> Subscription? {
        let events = rawEvents.sorted { $0.date < $1.date }
        guard events.count >= 2 else { return nil }
        let ivals = intervals(events)
        let cadence = (ivals.isEmpty ? nil : SubscriptionCadence.classify(medianDays: median(ivals))) ?? .monthly
        return makeSubscription(key: key, events: events, cadence: cadence)
    }

    /// Assemble a `Subscription` from sorted events (count ≥ 2) and a cadence.
    private static func makeSubscription(key: String, events: [Event], cadence: SubscriptionCadence) -> Subscription {
        let cal = Calendar.current
        let latest = events[events.count - 1]
        let prior = events[events.count - 2].amount
        let nextDate = cal.date(byAdding: .day, value: cadence.days, to: latest.date) ?? latest.date
        let charges = events.reversed().enumerated().map { idx, e in
            SubscriptionCharge(id: "\(key)-\(idx)", source: e.source, date: e.date, amount: e.amount)
        }
        return Subscription(
            id: key, displayName: displayName(key), cadence: cadence,
            latestAmount: latest.amount, priorAmount: prior, currency: latest.currency,
            nextDate: nextDate, lastDate: latest.date,
            isShared: events.contains { $0.shared }, charges: charges)
    }

    /// Day gaps between consecutive (sorted) events, dropping same-day duplicates.
    private static func intervals(_ events: [Event]) -> [Double] {
        let cal = Calendar.current
        var result: [Double] = []
        for i in 1..<events.count {
            let d = cal.dateComponents([.day], from: cal.startOfDay(for: events[i - 1].date),
                                       to: cal.startOfDay(for: events[i].date)).day ?? 0
            if d > 0 { result.append(Double(d)) }
        }
        return result
    }

    private static func nsDouble(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    // MARK: Helpers

    private static func displayName(_ key: String) -> String {
        key.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        let mid = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    private static func median(_ values: [Decimal]) -> Decimal {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        let mid = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}
