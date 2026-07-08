import Foundation
import SwiftData

/// Backs the review queue: fetches cached data + runs `SuggestionEngine`, runs the on-device AI pass that
/// populates `Transaction.aiSuggestedCategory`, performs accept/dismiss via existing repos, and maintains
/// split templates. Everything is local + existing endpoints - no new backend.
@MainActor
struct SuggestionService {
    let client: Client
    let context: ModelContext
    let me: String?
    /// Shared subscription-analysis memo (injected by `AppEnvironment`); nil in any direct construction.
    var analysisCache: SuggestionAnalysisCache? = nil

    /// Max transactions the AI pass classifies per run (Apple Intelligence inference is not free).
    private static let aiBatch = 25

    // MARK: Read

    /// Suggestions computed **synchronously** from the cached store, given a known partner set. No network - 
    /// the caller supplies `partners` (so the Inbox can paint cached cards instantly, then recompute once the
    /// accepted-connections fetch returns). Friend nudges read the cached `Friend` snapshot.
    func current(partners: Set<String>) throws -> [Suggestion] {
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let expenses = try context.fetch(FetchDescriptor<Expense>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let goals = try context.fetch(FetchDescriptor<Goal>())
        let groupMembers = try context.fetch(FetchDescriptor<GroupMember>())
        let maps = try context.fetch(FetchDescriptor<CategoryMap>())
        let templates = try context.fetch(FetchDescriptor<SplitTemplate>())
        let rules = try context.fetch(FetchDescriptor<SubscriptionRule>())
        let decisions = try context.fetch(FetchDescriptor<SuggestionDecision>())
        let lookup = CategoryMapping.lookup(maps), sources = CategoryMapping.sources(maps)

        let asOf = Date(), linkThreshold = LinkSensitivity.current().threshold

        // The deterministic pass (Link + Subscription + Recurring-split) is the heavy one and depends only on
        // transactions/expenses/templates/rules/linkThreshold - memoize the whole thing (shared via
        // AppEnvironment) so the 3-paints-per-reload + accept/dismiss/AI churn reuse it. Subscriptions feed it
        // via their own (narrower) memo. The volatile categorize pass + nudges recompute each call (cheap).
        func freshSubscriptions() -> [Subscription] {
            analysisCache?.subscriptions(transactions: transactions, expenses: expenses, lookup: lookup,
                                         me: me, rules: rules, asOf: asOf)
                ?? SubscriptionDetector.analyze(transactions: transactions, expenses: expenses,
                                                lookup: lookup, me: me, rules: rules).subscriptions
        }
        func computeDeterministic() -> [Suggestion] {
            SuggestionEngine.generateDeterministic(
                transactions: transactions, expenses: expenses, templates: templates, rules: rules,
                subscriptions: freshSubscriptions(), me: me, asOf: asOf, linkThreshold: linkThreshold)
        }
        let deterministic = analysisCache?.deterministicSuggestions(
            transactions: transactions, expenses: expenses, me: me, rules: rules, templates: templates,
            asOf: asOf, linkThreshold: linkThreshold, compute: computeDeterministic) ?? computeDeterministic()

        // The user's saved MerchantPreferences category rules produce "Your rule" recategorize cards (note-
        // first, amount-scoped), taking priority over the AI opinion for matched rows.
        let prefs = MerchantPreferences.shared
        var result = SuggestionEngine.filterDismissed(
            SuggestionEngine.generateCategorize(
                transactions: transactions, lookup: lookup, sources: sources,
                prefCategory: { prefs.category(note: $0.note, merchant: $0.details, amount: $0.amount) })
                + deterministic,
            decisions: decisions)

        // Read the cached Friend balances (snapshot from the last /friends sync); names from the directory.
        let directory = (try? context.fetch(FetchDescriptor<User>())) ?? []
        let friendNets: [(identifier: String, name: String, net: Decimal)] =
            ((try? context.fetch(FetchDescriptor<Friend>())) ?? []).map { f in
                (f.identifier, directory.displayName(for: f.identifier), f.net)
            }
        result += SuggestionEngine.nudges(
            goals: goals, transactions: transactions, expenses: expenses, accounts: accounts, lookup: lookup,
            groupMembers: groupMembers, partners: partners, friendNets: friendNets, decisions: decisions, me: me)
        // Rank by usefulness + recency and cap - the freshest, most-useful cards surface at the top.
        return SuggestionRanking.ranked(result)
    }

    /// The accepted partner connections (network, best-effort - offline yields an empty set).
    func fetchPartners() async -> Set<String> {
        Set(((try? await ConnectionRepository(client: client).list()) ?? [])
            .filter { $0.status == "accepted" }.map(\.other_identifier))
    }

    /// Convenience one-shot: fetch partners then compute (used where streaming isn't needed, e.g. the badge).
    func current() async throws -> [Suggestion] {
        try current(partners: await fetchPartners())
    }

    // MARK: AI pass

    /// Classifies a bounded batch of not-yet-processed outflow transactions with the on-device model and
    /// stores each opinion in `aiSuggestedCategory` ("" marks "processed, no confident suggestion"). No-op
    /// without Apple Intelligence.
    func refreshAI() async {
        guard CategoryMapper.isAvailable else { return }
        // Fetch only the not-yet-processed rows (incremental - skips everything already classified), newest
        // first; the cheap amount>0 outflow filter stays in-memory (Decimal isn't predicate-friendly).
        var descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { $0.aiSuggestedCategory == nil })
        descriptor.sortBy = [SortDescriptor(\.date, order: .reverse)]
        var pending = ((try? context.fetch(descriptor)) ?? []).filter { $0.amount > 0 }
        guard !pending.isEmpty else { return }

        // Rows a saved MerchantPreferences rule already covers don't need a model call - the "Your rule" card
        // is computed live from the matcher. Mark them processed ("") and drop them from the model batch so we
        // neither spend inference on them nor raise a competing AI card.
        let prefs = MerchantPreferences.shared
        let covered = pending.filter { prefs.category(note: $0.note, merchant: $0.details, amount: $0.amount) != nil }
        if !covered.isEmpty {
            for t in covered { t.aiSuggestedCategory = "" }
            try? context.save()
            let coveredIds = Set(covered.map(\.id))
            pending = pending.filter { !coveredIds.contains($0.id) }
            guard !pending.isEmpty else { return }
        }

        // Suggest from the user's own categories (not just canonical), and classify each unique description
        // ONCE - many imported rows share a merchant, so this covers far more transactions per run and avoids
        // re-classifying identical descriptions.
        let allowed = (try? context.fetch(FetchDescriptor<SpendCategory>()))?.map(\.name) ?? CanonicalCategory.all
        // The model anchors on the current category, so resolve it per merchant (cheap; reuses the label map).
        let maps = (try? context.fetch(FetchDescriptor<CategoryMap>())) ?? []
        let lookup = CategoryMapping.lookup(maps), sources = CategoryMapping.sources(maps)
        // Group by merchant AND note: same-merchant rows with different notes must get their own AI result
        // (the "Apple = Duolingo vs Xcode" case), while note-less same-merchant rows still batch as one.
        var byDescription: [String: [Transaction]] = [:]
        var order: [String] = []
        for t in pending {
            let note = t.note?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let key = t.details.lowercased() + "\u{1}" + note
            if byDescription[key] == nil { order.append(key) }
            byDescription[key, default: []].append(t)
        }
        let batchKeys = order.prefix(Self.aiBatch)
        let items = batchKeys.compactMap { key -> CategoryMapper.Item? in
            byDescription[key]?.first.map { t in
                .init(id: t.id, description: t.details, rawCategory: t.category,
                      current: CategoryMapping.resolve(for: t, lookup: lookup, sources: sources).category,
                      note: t.note)
            }
        }
        let result = await CategoryMapper.refine(items, allowed: allowed)
        for key in batchKeys {
            let suggestion = (byDescription[key]?.first).flatMap { result[$0.id] } ?? ""
            for t in byDescription[key] ?? [] { t.aiSuggestedCategory = suggestion }  // apply to all with this merchant
        }
        try? context.save()
    }

    // MARK: Accept / dismiss

    func accept(_ s: Suggestion) async throws {
        switch s.kind {
        case .categorize:
            guard let category = s.category else { return }
            let ids = s.transactionIds.isEmpty ? [s.transactionId].compactMap { $0 } : s.transactionIds
            let repo = AccountRepository(client: client, context: context)
            if s.userRule {
                // The user's own merchant rule is "You" provenance - write a top-rank override (→ "You" badge)
                // so it durably beats even a confident built-in category.
                try await repo.setCategoryOverride(ids: ids, category: category)
            } else {
                // An accepted AI suggestion is AI-provenance: write `refinedCategory` (→ "AI" badge), which now
                // outranks the built-in map so the accepted category wins on the card's deterministic/raw rows.
                try await repo.setRefinedCategory(ids.map { (id: $0, refined: category) })
            }
        case .link:
            guard let expenseId = s.expenseId, let txnId = s.transactionId else { return }
            try await ExpenseRepository(client: client, context: context)
                .linkTransaction(expenseId: expenseId, transactionId: txnId)
        case .subscription:
            guard let key = s.merchantKey else { return }
            context.insert(SubscriptionRule(merchantKey: key, amount: s.amount ?? 0,
                                            isSubscription: true, displayName: s.title))
            try context.save()
            pushSync()
        case .recurringSplit:
            try await acceptRecurringSplit(s)
        case .sharedBudgetCandidate, .settleUp, .overspend, .nearingBudget:
            break  // navigate-only - the inbox view handles these
        }
    }

    /// Creates the shared expense for a recurring-split suggestion from its template, linked to the charge.
    private func acceptRecurringSplit(_ s: Suggestion) async throws {
        guard let me, let txnId = s.transactionId, let key = s.templateMerchantKey,
              let txn = try context.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == txnId })).first,
              let tmpl = try context.fetch(
                FetchDescriptor<SplitTemplate>(predicate: #Predicate { $0.merchantKey == key })).first
        else { return }
        let owed = Self.distribute(txn.amount, fractions: tmpl.shares)
        let splits = owed.map { uid, share in
            SplitDraft(userIdentifier: uid, paidShare: uid == me ? txn.amount : 0, owedShare: share)
        }
        let draft = ExpenseDraft(
            groupId: tmpl.groupId, details: txn.details, amount: txn.amount, currency: txn.currency,
            date: txn.date, category: tmpl.category, createdBy: me, transactionId: txn.id, splits: splits)
        // Idempotent on the suggestion id: retrying this same acceptance dedups to one expense server-side
        // rather than creating a duplicate shared expense for the charge.
        try await ExpenseRepository(client: client, context: context).create(draft, idempotencyKey: s.id)
    }

    func dismiss(_ s: Suggestion, forMerchant: Bool = false) throws {
        let key = forMerchant ? (s.merchantScopeKey ?? s.id) : s.id
        context.insert(SuggestionDecision(key: key, decision: "dismissed"))
        if forMerchant, let merchant = s.merchantKey {
            if s.kind == .recurringSplit {
                for t in try context.fetch(FetchDescriptor<SplitTemplate>(
                    predicate: #Predicate { $0.merchantKey == merchant })) { context.delete(t) }
            } else if s.kind == .subscription {
                context.insert(SubscriptionRule(merchantKey: merchant, amount: s.amount ?? 0,
                                                isSubscription: false, displayName: s.title))
            }
        }
        try context.save()
        pushSync()
    }

    // MARK: Templates

    /// Auto-derives templates from history and upserts them (an explicit template is never overwritten).
    func learnTemplates() throws {
        let expenses = try context.fetch(FetchDescriptor<Expense>())
        let existing = Dictionary(
            try context.fetch(FetchDescriptor<SplitTemplate>()).map { ($0.merchantKey, $0) },
            uniquingKeysWith: { a, _ in a })
        for t in SplitTemplateLearning.derive(expenses: expenses) {
            if let current = existing[t.merchantKey] {
                guard current.source == "auto" else { continue }  // don't clobber an explicit one
                current.groupId = t.groupId
                current.category = t.category
                current.sharesJSON = t.sharesJSON
                current.displayName = t.displayName
                current.updatedAt = Date()
            } else {
                context.insert(t)
            }
        }
        try context.save()
        pushSync()
    }

    /// "Remember this split": pins an explicit template from a shared, transaction-linked expense.
    func rememberSplit(_ expense: Expense) throws {
        let key = MerchantText.key(expense.details)
        guard !key.isEmpty else { return }
        let total = expense.splits.reduce(Decimal(0)) { $0 + max($1.owedShare, 0) }
        guard total > 0 else { return }
        var fractions: [String: Double] = [:]
        for split in expense.splits where split.owedShare > 0 {
            fractions[split.userIdentifier] = NSDecimalNumber(decimal: split.owedShare / total).doubleValue
        }
        let json = SplitTemplate.encode(fractions)
        if let current = try context.fetch(FetchDescriptor<SplitTemplate>(
            predicate: #Predicate { $0.merchantKey == key })).first {
            current.groupId = expense.groupId
            current.category = expense.category
            current.sharesJSON = json
            current.source = "explicit"
            current.displayName = expense.details
            current.updatedAt = Date()
        } else {
            context.insert(SplitTemplate(merchantKey: key, groupId: expense.groupId,
                                         category: expense.category, sharesJSON: json,
                                         source: "explicit", displayName: expense.details))
        }
        try context.save()
        pushSync()
    }

    /// Splits `amount` by `fractions`, rounding to cents and giving any remainder to the largest share so
    /// the parts sum exactly to `amount`.
    /// Best-effort cross-device backup of templates + decisions after a local change.
    private func pushSync() { Task { await SuggestionSync.pushBestEffort(context, client: client) } }

    nonisolated static func distribute(_ amount: Decimal, fractions: [String: Double]) -> [(String, Decimal)] {
        let totalFraction = fractions.values.reduce(0, +)
        guard totalFraction > 0 else { return [] }
        var result: [(String, Decimal)] = []
        var allocated: Decimal = 0
        let sorted = fractions.sorted { $0.value > $1.value }
        for (i, entry) in sorted.enumerated() {
            if i == sorted.count - 1 {
                result.append((entry.key, amount - allocated))  // remainder → largest is first, last is smallest
            } else {
                let share = round2(amount * Decimal(entry.value / totalFraction))
                allocated += share
                result.append((entry.key, share))
            }
        }
        return result
    }

    nonisolated private static func round2(_ d: Decimal) -> Decimal {
        var v = d, r = Decimal()
        NSDecimalRound(&r, &v, 2, .plain)
        return r
    }
}
