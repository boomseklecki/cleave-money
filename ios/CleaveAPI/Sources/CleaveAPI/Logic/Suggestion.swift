import Foundation

/// One review-queue card: a recommended action over cached data, with a stable `id` so a dismissal sticks.
/// Pure value type produced by `SuggestionEngine`; `SuggestionService` performs the accept/dismiss.
struct Suggestion: Identifiable, Equatable {
    enum Kind: String {
        case categorize, link, subscription, recurringSplit          // actionable (accept mutates)
        case sharedBudgetCandidate, settleUp, overspend, nearingBudget  // nudges (accept navigates/prefills)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: String
    let acceptLabel: String

    // Targets - set per kind.
    var transactionId: UUID? = nil
    var transactionIds: [UUID] = []        // categorize → all merchant-matched transactions the accept applies to
    var expenseId: UUID? = nil
    var goalId: UUID? = nil                // overspend → GoalDetailView
    var friendIdentifier: String? = nil    // settleUp → FriendDetailView
    var category: String? = nil            // suggested category (categorize) / template / budget candidate
    var currentCategory: String? = nil     // categorize → the resolved category being replaced (for the confirm)
    var templateMerchantKey: String? = nil
    var merchantKey: String? = nil         // subscription / recurring - basis for "never for this merchant"
    var amount: Decimal? = nil             // subscription amount / suggested budget target
    var matchScore: Double? = nil          // link → TransactionMatcher confidence 0...1 (drives the confirm sheet)
    var sortDate: Date? = nil              // the underlying txn/expense date - drives recency in `SuggestionRanking`
    /// A categorize card whose category comes from the user's own saved MerchantPreferences rule (not the AI
    /// opinion). Drives the "Your rule" card affordance and an override ("You") write on accept, vs the AI
    /// card's `sparkles` + refined ("AI") write. Default false keeps every existing card unchanged.
    var userRule: Bool = false

    /// Nudge kinds navigate (or open a prefilled editor) instead of mutating on accept.
    var navigates: Bool {
        switch kind {
        case .sharedBudgetCandidate, .settleUp, .overspend, .nearingBudget: return true
        default: return false
        }
    }

    /// The "never for this merchant" decision key, when the suggestion is merchant-scoped. Kind-namespaced so
    /// silencing recategorize for a merchant doesn't also silence its subscription / recurring-split cards.
    var merchantScopeKey: String? {
        merchantKey.map { kind == .categorize ? "recat:\($0)" : "merchant:\($0)" }
    }
}
