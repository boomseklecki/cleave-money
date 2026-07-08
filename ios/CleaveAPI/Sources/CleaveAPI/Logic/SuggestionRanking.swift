import Foundation

/// Ranks the review-queue cards so the most useful + freshest float to the top, then caps the list. A
/// recency-weighted blend with a type-usefulness order (Link ≈ RecurringSplit > Categorize > nudges >
/// Subscription) - so a fresh, confident lower-type card can edge a stale higher-type one, but type still
/// dominates broadly. Pure + deterministic (ties break on `id`) so it's testable and stable across renders.
enum SuggestionRanking {
    /// Most cards the Inbox shows at once (the newest/most-useful slice of a big history).
    static let maxCards = 28
    // Recency can swing a full tier (so a very stale higher-type card can be edged by a fresh lower-type one),
    // but at comparable recency the integer type tier still decides - "type dominates broadly".
    static let recencyWeight = 1.0
    static let confidenceWeight = 0.5
    /// Recency decays with a ~30-day half-life: today ≈ 1, a month ago ≈ 0.37.
    static let recencyHalfLifeDays = 30.0

    /// Coarse usefulness tier by kind (integer steps so type is the primary sort key).
    static func typeWeight(_ kind: Suggestion.Kind) -> Double {
        switch kind {
        case .link, .recurringSplit: return 4            // dedupe / shared-expense actions - most useful
        case .categorize: return 3                        // makes budgets/goals/trends meaningful
        case .overspend, .nearingBudget, .settleUp, .sharedBudgetCandidate: return 2   // budget + settle-up nudges
        case .subscription: return 1                      // least useful (informational)
        }
    }

    /// 0...1 from the underlying date; dateless nudges get a neutral mid value so they interleave by type.
    static func recency(_ date: Date?, now: Date) -> Double {
        guard let date else { return 0.5 }
        let ageDays = max(0, now.timeIntervalSince(date) / 86_400)
        return exp(-ageDays / recencyHalfLifeDays)
    }

    /// 0...1 confidence per kind (link uses its match score; categorize scales with coverage; etc.).
    static func confidence(_ s: Suggestion) -> Double {
        switch s.kind {
        case .link: return s.matchScore ?? 0.85
        case .recurringSplit: return 1.0                  // template-taught - high signal
        case .categorize: return min(Double(max(s.transactionIds.count, 1)) / 10.0, 1.0)
        case .subscription: return 0.5
        case .overspend, .nearingBudget, .settleUp, .sharedBudgetCandidate: return 0.6
        }
    }

    static func score(_ s: Suggestion, now: Date) -> Double {
        typeWeight(s.kind) + recencyWeight * recency(s.sortDate, now: now) + confidenceWeight * confidence(s)
    }

    /// Sort by score desc (ties → `id` for determinism) and cap at `maxCards`.
    static func ranked(_ suggestions: [Suggestion], now: Date = Date()) -> [Suggestion] {
        suggestions
            .map { (suggestion: $0, score: score($0, now: now)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.suggestion.id < $1.suggestion.id }
            .prefix(maxCards)
            .map(\.suggestion)
    }
}
