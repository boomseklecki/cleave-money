import Foundation

/// Anything the related-grouping matcher can work over - a description, an amount, and a date. Both
/// `Transaction` and `Expense` conform, so the same "find related & bulk recategorize" flow serves both.
protocol RelatedItem {
    var details: String { get }
    var amount: Decimal { get }
    var date: Date { get }
}

/// Conservative, seed-relative grouping of transactions by merchant description, for batch recategorization.
/// A transaction is "related" when its significant words overlap the *exact* description you tapped (single
/// pass, no transitive chaining), with a user-chosen strictness on how much overlap is required - so a single
/// shared generic word ("...JOE'S CRAB SHACK" vs "TRADER JOE'S") need not pull in unrelated merchants. Pure
/// and unit-tested.
enum RelatedTransactions {
    /// How tightly a candidate's merchant/description must match the seed's. Independent of the amount axis.
    enum MatchStrictness: String, CaseIterable, Identifiable {
        case fuzzy     // any shared significant word (broadest)
        case balanced  // most words match (overlap coefficient > 0.5)
        case strict    // one description's significant words fully contain the other's
        case exact     // exactly the same merchant: identical normalized merchant key (no generic-word leaks)
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fuzzy: return "Fuzzy"
            case .balanced: return "Balanced"
            case .strict: return "Strict"
            case .exact: return "Exact"
            }
        }
    }

    /// Optional amount constraint, applied independently of the merchant match (no-op without a seed amount).
    enum AmountMatch: String, CaseIterable, Identifiable, Codable {
        case any     // ignore amount
        case close   // within a small tolerance (fluctuating charge)
        case equal   // exactly the same amount (identical recurring charge)
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "Any"
            case .close: return "Close"
            case .equal: return "Equal"
            }
        }
    }

    /// Items (transactions or expenses) related to the seed at the given merchant `strictness` and `amount`
    /// constraint, most recent first. Returns `[]` when the seed has no significant words.
    static func group<Item: RelatedItem>(
        seedDescription: String, seedAmount: Decimal? = nil, in items: [Item],
        strictness: MatchStrictness = .balanced, amount: AmountMatch = .any
    ) -> [Item] {
        let seedTokens = MerchantText.tokens(seedDescription)
        guard !seedTokens.isEmpty else { return [] }
        let seedKey = MerchantText.key(seedDescription)
        return items
            .filter { item in
                matchesMerchant(item.details, seedTokens: seedTokens, seedKey: seedKey, strictness)
                    && matchesAmount(item.amount, seedAmount, amount)
            }
            .sorted { $0.date > $1.date }
    }

    /// The significant tokens shared by *every* item in a group - the basis for a suggested brand/note pattern
    /// on the find-related screen. As the Merchant/Amount filter tightens the group, the shared set grows (a
    /// more specific pattern); as it loosens, it shrinks. Empty when the group shares no significant token.
    static func commonTokens<Item: RelatedItem>(of items: [Item]) -> [String] {
        guard let first = items.first else { return [] }
        var common = MerchantText.tokens(first.details)
        for item in items.dropFirst() { common.formIntersection(MerchantText.tokens(item.details)) }
        return common.sorted()
    }

    /// Whether candidate `details` matches the seed at `strictness`. `exact` uses the normalized merchant key
    /// (so a shared generic word like "store" can't leak in a different merchant); the looser levels use
    /// significant-word set overlap.
    private static func matchesMerchant(_ details: String, seedTokens: Set<String>, seedKey: String,
                                        _ strictness: MatchStrictness) -> Bool {
        if strictness == .exact {
            return !seedKey.isEmpty && MerchantText.key(details) == seedKey
        }
        let c = MerchantText.tokens(details)
        switch strictness {
        case .fuzzy:
            return !c.isDisjoint(with: seedTokens)
        case .balanced:
            return !c.isEmpty && Double(c.intersection(seedTokens).count) / Double(min(c.count, seedTokens.count)) > 0.5
        case .strict:
            return !c.isEmpty && (seedTokens.isSubset(of: c) || c.isSubset(of: seedTokens))
        case .exact:
            return false  // handled above
        }
    }

    /// Whether a candidate amount satisfies the amount constraint (no-op when the seed amount is unknown).
    private static func matchesAmount(_ a: Decimal, _ seed: Decimal?, _ mode: AmountMatch) -> Bool {
        guard mode != .any, let seed else { return true }
        return mode == .equal ? a == seed : amountsClose(a, seed)
    }

    /// "Close" amounts: within $1 (handles small/cents differences) or within 25% (fluctuating charges).
    static func amountsClose(_ a: Decimal, _ b: Decimal) -> Bool {
        let hi = max(a, b), lo = min(a, b)
        return hi - lo <= 1 || hi * 4 <= lo * 5
    }

    /// A human title for the group: de-noise the merchant (strip a processor prefix + trailing store/ref
    /// numbers via `MerchantParse.cleaned`, which keeps short brand words like "GO"), take the first few words,
    /// and title-case them (e.g. "GET GO #1234" -> "Get Go", "ANTHROPIC CLAUDE SUB" -> "Anthropic Claude Sub").
    /// Uses `cleaned` rather than `MerchantText.words` so 2-letter words are not dropped as noise.
    static func displayName(for seedDescription: String) -> String {
        let words = MerchantParse.cleaned(seedDescription).split(separator: " ").prefix(3)
        guard !words.isEmpty else { return seedDescription }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}

// Both models already expose `details`, `amount`, and `date`.
extension Transaction: RelatedItem {}
extension Expense: RelatedItem {}
