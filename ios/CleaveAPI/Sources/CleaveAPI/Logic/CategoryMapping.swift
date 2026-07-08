import Foundation

/// Which layer of the precedence chain produced a category - surfaced as provenance (badge + inspector) so
/// the otherwise-invisible on-device AI (and AI-written map entries) become legible.
enum CategoryOrigin: Equatable {
    case override        // explicit per-transaction override (you)
    case mappedByYou     // local map entry, source "manual"
    case mappedByAI      // local map entry, source "ondevice" (Apple Intelligence)
    case deterministic   // built-in Plaid/Splitwise taxonomy table
    case aiRefined       // per-transaction on-device refinement (Apple Intelligence)
    case explicit        // the stored value is already a canonical category, set directly
    case raw             // unmapped passthrough of the raw label
}

/// A resolved category plus how it was derived. `category` is nil only when there's nothing to show.
struct CategoryResolution: Equatable {
    let category: String?
    let source: CategoryOrigin
    let raw: String?
}

/// Resolves a transaction's raw Plaid category to a canonical one using the local category map.
enum CategoryMapping {
    /// Builds a fast raw→canonical lookup from the cached map rows.
    static func lookup(_ maps: [CategoryMap]) -> [String: String] {
        Dictionary(maps.map { ($0.rawCategory, $0.canonicalCategory) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Builds a raw→source map ("manual"/"ondevice") parallel to `lookup`, so provenance can tell a
    /// hand-mapped entry apart from one the on-device AI wrote.
    static func sources(_ maps: [CategoryMap]) -> [String: String] {
        Dictionary(maps.map { ($0.rawCategory, $0.source) }, uniquingKeysWith: { first, _ in first })
    }

    /// The canonical category for a transaction (just the string - see `resolve(for:)` for provenance).
    static func effectiveCategory(for transaction: Transaction, lookup: [String: String]) -> String? {
        resolve(for: transaction, lookup: lookup).category
    }

    /// The canonical category for a raw expense/label string (just the string - see
    /// `resolve(expenseCategory:)` for provenance).
    static func canonical(_ raw: String, lookup: [String: String]) -> String? {
        resolve(expenseCategory: raw, lookup: lookup).category
    }

    /// A transaction's category **with provenance**. Precedence: an explicit per-transaction override →
    /// a user/on-device entry in the local label map → the per-transaction on-device AI refinement → a
    /// built-in Plaid mapping → the raw string. Pass `sources` (raw→"manual"/"ondevice") to tell a hand-mapped
    /// entry from an AI-written one. `refinedCategory` outranks the built-in map because it's only ever written
    /// when the on-device model was *confident it's clearly more accurate* than the current category
    /// (`CategoryMapper.refine`'s anchored `changeIsClear` gate) - from the manual button, an accepted Inbox
    /// card, or the vague-row pass. So a refined value already represents a high-confidence, description-aware
    /// decision, not a blind override of Plaid's coarse label.
    static func resolve(for transaction: Transaction, lookup: [String: String],
                        sources: [String: String] = [:]) -> CategoryResolution {
        if let override = transaction.categoryOverride, !override.isEmpty {
            return CategoryResolution(category: override, source: .override, raw: transaction.category)
        }
        let refined = transaction.refinedCategory.flatMap { $0.isEmpty ? nil : $0 }
        guard let raw = transaction.category, !raw.isEmpty else {
            // Plaid never labeled it: an AI refinement is the only per-row signal that can categorize it.
            if let refined {
                return CategoryResolution(category: refined, source: .aiRefined, raw: transaction.category)
            }
            return CategoryResolution(category: nil, source: .raw, raw: transaction.category)
        }
        if let mapped = lookup[raw] {
            return CategoryResolution(category: mapped, source: mappedSource(raw, sources), raw: raw)
        }
        if let refined {
            return CategoryResolution(category: refined, source: .aiRefined, raw: raw)
        }
        if let builtin = PlaidCategory.canonical(raw) {
            return CategoryResolution(category: builtin, source: .deterministic, raw: raw)
        }
        return CategoryResolution(category: raw, source: passthroughSource(raw), raw: raw)
    }

    /// A raw expense/label category **with provenance**: local map → built-in Plaid map → Splitwise
    /// taxonomy map → the raw string. The Splitwise map folds imported labels (e.g. "Dining out") into
    /// canonical buckets so they don't fragment analytics - and so display can show the clean name.
    static func resolve(expenseCategory raw: String?, lookup: [String: String],
                        sources: [String: String] = [:]) -> CategoryResolution {
        guard let raw, !raw.isEmpty else {
            return CategoryResolution(category: nil, source: .raw, raw: raw)
        }
        if let mapped = lookup[raw] {
            return CategoryResolution(category: mapped, source: mappedSource(raw, sources), raw: raw)
        }
        if let builtin = PlaidCategory.canonical(raw) {
            return CategoryResolution(category: builtin, source: .deterministic, raw: raw)
        }
        if let sw = SplitwiseCategory.canonical(raw) {
            return CategoryResolution(category: sw, source: .deterministic, raw: raw)
        }
        return CategoryResolution(category: raw, source: passthroughSource(raw), raw: raw)
    }

    private static func mappedSource(_ raw: String, _ sources: [String: String]) -> CategoryOrigin {
        sources[raw] == "ondevice" ? .mappedByAI : .mappedByYou
    }

    /// A passthrough value is `explicit` when it's already a known canonical category (set directly), else `raw`.
    private static func passthroughSource(_ value: String) -> CategoryOrigin {
        CanonicalCategory.all.contains(value) ? .explicit : .raw
    }

    /// Whether a transaction's category is vague enough to benefit from a description-based refinement:
    /// no explicit override and the built-in map yields "Other" or nothing.
    static func needsRefinement(_ transaction: Transaction, lookup: [String: String]) -> Bool {
        guard transaction.categoryOverride == nil,
              transaction.source == .plaid, let raw = transaction.category, !raw.isEmpty,
              lookup[raw] == nil else { return false }
        let builtin = PlaidCategory.canonical(raw)
        return builtin == nil || builtin == "Other"
    }
}

/// Canonical categories that are internal transfers / income - excluded from spend totals and
/// (for Transfer) from net income, so card payments and account-to-account moves don't distort it.
/// Mirrors `backend/app/categories.py`.
enum CanonicalCategory {
    /// Never counted toward spend (donut/budgets).
    static let excludedFromSpend: Set<String> = ["Transfer", "Income", "Settle-up", "Reimbursement"]
    /// No economic event - money just moving between people/accounts (settle-ups, transfers, card
    /// payments). Excluded from both spend and net income.
    static let neutral: Set<String> = ["Transfer", "Settle-up"]
    /// Money coming in - counts as a net-income inflow (your share), excluded from spend.
    static let incomeLike: Set<String> = ["Income", "Reimbursement"]
    static let transfer = "Transfer"

    /// The app's canonical taxonomy (kept in sync with the backend list). Used by the on-device mapper
    /// to constrain its output and by the category palette.
    static let all: [String] = [
        "Groceries", "Dining", "Alcohol", "Transport", "Fuel", "Utilities", "Rent", "Mortgage",
        "Entertainment", "Travel", "Health", "Insurance", "Shopping", "Household", "Services",
        "Subscriptions", "Education", "Gifts", "Personal Care", "Pets", "Fees",
        "Income", "Transfer", "Settle-up", "Other",
    ]
}
