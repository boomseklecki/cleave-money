import Foundation

/// Generates the review-queue suggestions on-device from cached data - pure and synchronous so it's cheap
/// to recompute and easy to test. The costly AI step (populating `Transaction.aiSuggestedCategory`) runs
/// separately in `SuggestionService`; this only reads the cached opinion.
enum SuggestionEngine {
    /// Default confidence floor for a transaction↔expense link suggestion (TransactionMatcher score 0...1).
    /// Overridable per call via `linkThreshold` (the user's `LinkSensitivity` preference).
    static let defaultLinkThreshold = 0.85
    /// How far back a recurring-split template will match an unlinked charge.
    static let recurringWindowDays = 60
    /// Cap on subscription "track this?" cards so a big history doesn't flood the queue.
    static let maxSubscriptionCards = 8
    /// Newest unlinked expenses to consider for a link card - bounds the heavy per-expense match scan on a big
    /// history (the freshest are what `SuggestionRanking` surfaces anyway).
    static let linkScanCap = 200

    /// Produces the candidate cards (each stamped with `sortDate` for recency); the caller ranks + caps them
    /// via `SuggestionRanking`. A thin wrapper over the two split passes + the dismissal filter - kept for
    /// callers/tests. `SuggestionService.current()` instead calls the split passes directly so it can **cache**
    /// the deterministic one and only recompute the volatile categorize pass per render.
    static func generate(transactions: [Transaction], expenses: [Expense], lookup: [String: String],
                         sources: [String: String], templates: [SplitTemplate], rules: [SubscriptionRule],
                         subscriptions: [Subscription], decisions: [SuggestionDecision], me: String?,
                         asOf: Date = Date(), linkThreshold: Double = defaultLinkThreshold,
                         prefCategory: (Transaction) -> String? = { _ in nil }) -> [Suggestion] {
        let out = generateCategorize(transactions: transactions, lookup: lookup, sources: sources,
                                     prefCategory: prefCategory)
            + generateDeterministic(transactions: transactions, expenses: expenses, templates: templates,
                                    rules: rules, subscriptions: subscriptions, me: me, asOf: asOf,
                                    linkThreshold: linkThreshold)
        return filterDismissed(out, decisions: decisions)
    }

    /// Drop anything the user dismissed (by suggestion id or merchant scope). Cheap, per-render.
    static func filterDismissed(_ suggestions: [Suggestion], decisions: [SuggestionDecision]) -> [Suggestion] {
        let blocked = Set(decisions.filter { $0.isActive }.map(\.key))
        return suggestions.filter {
            !blocked.contains($0.id) && !($0.merchantScopeKey.map(blocked.contains) ?? false)
        }
    }

    /// **Volatile** pass - recategorize cards. The suggested category comes from the user's saved
    /// MerchantPreferences rule (`prefCategory`, "Your rule") when one matches, else the on-device AI opinion
    /// (`aiSuggestedCategory`). Depends on the pref matcher + AI opinion + category map, so it's recomputed
    /// every render (cheap O(n) read). The same guard applies to both sources: only rows whose current
    /// category resolves from the built-in map or raw (not already user-set/mapped/AI-refined), and only when
    /// the suggestion differs - so a rule can override a *confident* Plaid category but never nags a row the
    /// user already set. Aggregates by (description, suggested) into one accept-all card; a pref match makes a
    /// row a "Your rule" card and takes priority over its AI opinion.
    static func generateCategorize(transactions: [Transaction], lookup: [String: String],
                                   sources: [String: String],
                                   prefCategory: (Transaction) -> String? = { _ in nil }) -> [Suggestion] {
        let txnsDesc = transactions.sorted { $0.date > $1.date }  // newest-first so the freshest cards surface
        struct CatGroup { let title: String; let suggested: String; let current: String?; let userRule: Bool
                          let sortDate: Date; var ids: [UUID] }
        var catGroups: [String: CatGroup] = [:]
        var catOrder: [String] = []
        for t in txnsDesc {
            // The user's own rule wins over the AI opinion; either can override a confident built-in category.
            let pref = prefCategory(t)
            let suggested = pref ?? t.aiSuggestedCategory ?? ""
            guard !suggested.isEmpty else { continue }
            let userRule = pref != nil
            let res = CategoryMapping.resolve(for: t, lookup: lookup, sources: sources)
            guard res.source == .deterministic || res.source == .raw else { continue }
            guard suggested != res.category else { continue }
            // Namespace pref vs AI cards so their ids/dismissals don't collide for the same merchant.
            let key = "\(userRule ? "pref" : "ai")|\(t.details.lowercased())|\(suggested)"
            if catGroups[key] == nil {
                catGroups[key] = CatGroup(title: t.details, suggested: suggested, current: res.category,
                                          userRule: userRule, sortDate: t.date, ids: [])
                catOrder.append(key)
            }
            catGroups[key]?.ids.append(t.id)
        }
        return catOrder.compactMap { catGroups[$0] }.map { g in
            let suffix = g.ids.count > 1 ? " · \(g.ids.count) transactions" : ""
            return Suggestion(
                id: "\(g.userRule ? "prefcat" : "cat"):\(g.title.lowercased()):\(g.suggested)", kind: .categorize,
                title: g.title, subtitle: "\(g.current ?? "Uncategorized") → \(g.suggested)\(suffix)",
                icon: g.userRule ? "person.crop.circle.badge.checkmark" : "sparkles", acceptLabel: "Categorize",
                transactionId: g.ids.first, transactionIds: g.ids,
                category: g.suggested, currentCategory: g.current,
                merchantKey: MerchantText.key(g.title),  // enables "Never for this merchant"
                sortDate: g.sortDate, userRule: g.userRule)
        }
    }

    /// **Deterministic** pass - Link + Subscription + Recurring-split. Depends only on transactions/expenses/
    /// templates/rules/subscriptions/me/linkThreshold/day (NOT on the AI opinion, category overrides, partners,
    /// or dismissals), so the caller memoizes it (`SuggestionAnalysisCache`). The Link match is the heavy part.
    static func generateDeterministic(transactions: [Transaction], expenses: [Expense],
                                      templates: [SplitTemplate], rules: [SubscriptionRule],
                                      subscriptions: [Subscription], me: String?,
                                      asOf: Date = Date(), linkThreshold: Double = defaultLinkThreshold) -> [Suggestion] {
        let linkedTxnIds = Set(expenses.lazy.compactMap(\.transactionId))
        let txnsDesc = transactions.sorted { $0.date > $1.date }
        var out: [Suggestion] = []

        // 1) Link - newest unlinked expenses (bounded) with a high-confidence matching transaction (de-dupes spend).
        let unlinkedNewest = expenses.filter { $0.transactionId == nil }.sorted { $0.date > $1.date }.prefix(linkScanCap)
        for e in unlinkedNewest {
            if let c = e.category, CanonicalCategory.neutral.contains(c) { continue }
            guard let top = TransactionMatcher.transactionCandidates(
                for: e, transactions: transactions, expenses: expenses, me: me).first,
                  top.score >= linkThreshold else { continue }
            out.append(Suggestion(
                id: "link:\(top.transaction.id.uuidString):\(e.id.uuidString)", kind: .link,
                title: e.details, subtitle: "Looks like “\(top.transaction.details)” — link to de-dupe",
                icon: "link", acceptLabel: "Link",
                transactionId: top.transaction.id, expenseId: e.id, matchScore: top.score, sortDate: e.date))
        }

        // 2) Subscriptions - precomputed recurring charges with no rule yet (`sortDate` = last charge).
        let ruleKeys = Set(rules.map(\.merchantKey))
        for sub in subscriptions where !ruleKeys.contains(sub.id) {
            out.append(Suggestion(
                id: "sub:\(sub.id)", kind: .subscription,
                title: sub.displayName,
                subtitle: "\(sub.cadence.label) · \(sub.latestAmount.formatted(.currency(code: sub.currency)))",
                icon: "repeat", acceptLabel: "Track",
                merchantKey: sub.id, amount: sub.latestAmount, sortDate: sub.lastDate))
            if out.filter({ $0.kind == .subscription }).count >= maxSubscriptionCards { break }
        }

        // 3) Recurring split - newest unlinked recent charge matching a learned template.
        let cutoff = Calendar.current.date(byAdding: .day, value: -recurringWindowDays, to: asOf) ?? asOf
        let templatesByKey = Dictionary(templates.map { ($0.merchantKey, $0) }, uniquingKeysWith: { a, _ in a })
        for t in txnsDesc where t.amount > 0 && !linkedTxnIds.contains(t.id) && t.date >= cutoff {
            guard let tmpl = templatesByKey[MerchantText.key(t.details)] else { continue }
            out.append(Suggestion(
                id: "rsplit:\(t.id.uuidString):\(tmpl.merchantKey)", kind: .recurringSplit,
                title: t.details, subtitle: "Split like last time · \(tmpl.displayName)",
                icon: "arrow.triangle.2.circlepath", acceptLabel: "Split",
                transactionId: t.id, category: tmpl.category, templateMerchantKey: tmpl.merchantKey,
                merchantKey: tmpl.merchantKey, sortDate: t.date))
        }
        return out
    }
}

extension SuggestionEngine {
    static let sharedBudgetFloor: Decimal = 50    // min monthly household spend to suggest a shared budget
    static let settleUpThreshold: Decimal = 5     // min |balance| to nudge a settle-up

    /// The "broad" nudge cards - they navigate/prefill rather than mutate. Computed from goals, household
    /// spend, and friend balances; filtered by the same dismissal decisions.
    static func nudges(
        goals: [Goal], transactions: [Transaction], expenses: [Expense], accounts: [Account],
        lookup: [String: String], groupMembers: [GroupMember], partners: Set<String>,
        friendNets: [(identifier: String, name: String, net: Decimal)],
        decisions: [SuggestionDecision], me: String?, asOf: Date = Date()) -> [Suggestion] {
        let blocked = Set(decisions.filter { $0.isActive }.map(\.key))
        let month = SpendingAnalytics.monthStart(asOf)
        let spendGoals = goals.filter { $0.goalKind == .spend }
        let sharedGroupIds = me.map {
            HouseholdBudget.sharedGroupIds(viewer: $0, partners: partners,
                                           membersByGroup: HouseholdBudget.membership(groupMembers))
        } ?? []
        var out: [Suggestion] = []

        // Shared-budget candidate - the household spends in a category but has no shared budget for it.
        if let me, !partners.isEmpty {
            let existing = Set(spendGoals.filter { $0.shared }.compactMap { $0.category })
            let combined = HouseholdBudget.combinedByCategory(
                month: month, expenses: expenses, sharedGroupIds: sharedGroupIds, viewer: me, partners: partners)
            for (category, spend) in combined
            where spend.combined >= sharedBudgetFloor && !existing.contains(category) {
                out.append(Suggestion(
                    id: "sharedbudget:\(category)", kind: .sharedBudgetCandidate,
                    title: "\(category) household budget",
                    subtitle: "You + partner spent \(spend.combined.formatted(.currency(code: "USD"))) — set a shared budget?",
                    icon: "person.2", acceptLabel: "Create",
                    category: category, amount: roundedTarget(spend.combined)))
            }
        }

        // Budget nudges - a spend goal nearing (≥85%) or over its limit this month (own via GoalProgress,
        // shared via household). Ids are month-scoped so a dismissal only silences this month's card.
        let monthKey = Self.monthKey(month)
        for goal in spendGoals {
            guard let category = goal.category else { continue }
            let spent: Decimal = (goal.shared && me != nil)
                ? HouseholdBudget.combined(category: category, month: month, expenses: expenses,
                                           sharedGroupIds: sharedGroupIds, viewer: me!, partners: partners).combined
                : GoalProgress.spent(for: category, in: month, transactions: transactions,
                                     accounts: accounts, lookup: lookup, expenses: expenses, me: me)
            let amounts = "\(spent.formatted(.currency(code: "USD"))) of \(goal.targetAmount.formatted(.currency(code: "USD")))"
            switch GoalProgress.budgetStatus(spent: spent, target: goal.targetAmount) {
            case .over:
                out.append(Suggestion(
                    id: "overspend:\(goal.id.uuidString):\(monthKey)", kind: .overspend, title: goal.name,
                    subtitle: "Over budget: \(amounts)",
                    icon: "exclamationmark.triangle", acceptLabel: "View", goalId: goal.id))
            case .nearing:
                let pct = goal.targetAmount > 0
                    ? Int((NSDecimalNumber(decimal: spent / goal.targetAmount).doubleValue * 100).rounded()) : 0
                out.append(Suggestion(
                    id: "nearing:\(goal.id.uuidString):\(monthKey)", kind: .nearingBudget, title: goal.name,
                    subtitle: "At \(pct)% of budget: \(amounts)",
                    icon: "gauge.medium", acceptLabel: "View", goalId: goal.id))
            case .under:
                break
            }
        }

        // Settle up - a friend balance past the threshold.
        for fn in friendNets where abs(fn.net) >= settleUpThreshold {
            out.append(Suggestion(
                id: "settleup:\(fn.identifier)", kind: .settleUp, title: fn.name,
                subtitle: fn.net > 0 ? "Owes you \(fn.net.formatted(.currency(code: "USD")))"
                                     : "You owe \((-fn.net).formatted(.currency(code: "USD")))",
                icon: "arrow.left.arrow.right", acceptLabel: "Settle",
                friendIdentifier: fn.identifier, amount: fn.net))
        }

        return out.filter { !blocked.contains($0.id) }
    }

    /// Rounds a spend figure up to a tidy budget target (nearest 10).
    private static func roundedTarget(_ amount: Decimal) -> Decimal {
        Decimal((NSDecimalNumber(decimal: amount).doubleValue / 10).rounded(.up) * 10)
    }

    /// A stable per-month key ("YYYY-MM") for month-scoped budget-nudge dismissals.
    private static func monthKey(_ month: Date) -> String {
        let c = SpendingAnalytics.spendCalendar.dateComponents([.year, .month], from: month)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
