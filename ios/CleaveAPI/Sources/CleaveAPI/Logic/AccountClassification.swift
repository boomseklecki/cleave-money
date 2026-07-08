import Foundation

/// How an account is summarized in its detail header. Derived from the Plaid subtype string stored in
/// `Account.type` - the backend exposes no explicit asset/liability flag, so we classify by subtype
/// and default anything unrecognized to a transactional cash-flow account.
enum AccountKind: CaseIterable {
    /// Transactional deposit accounts (checking, savings, money market, cash management).
    case cashFlow
    /// Credit cards and loans - balance is money owed.
    case liability
    /// Investment / retirement / locked savings vehicles with few or no transactions. Shown to the user
    /// as "Savings" (money parked, not part of spending or cash flow).
    case holdings

    /// Canonical override string persisted on `Account.kind` / the backend.
    var canonical: String {
        switch self {
        case .cashFlow: return "cash_flow"
        case .liability: return "liability"
        case .holdings: return "savings"
        }
    }

    init?(canonical: String) {
        switch canonical {
        case "cash_flow": self = .cashFlow
        case "liability": self = .liability
        case "savings", "holdings": self = .holdings
        default: return nil
        }
    }

    /// User-facing name (the third bucket reads "Savings" rather than "Holdings").
    var label: String {
        switch self {
        case .cashFlow: return "Cash flow"
        case .liability: return "Liability"
        case .holdings: return "Savings"
        }
    }

    /// Plaid subtypes (lowercased) treated as liabilities. Includes the top-level `credit`/`loan`
    /// fallbacks for accounts that report no subtype.
    private static let liabilitySubtypes: Set<String> = [
        "credit card", "credit", "loan",
        "auto", "business", "commercial", "construction", "consumer",
        "home equity", "line of credit", "mortgage", "overdraft", "student",
    ]
    /// Plaid subtypes (lowercased) treated as holdings.
    private static let holdingsSubtypes: Set<String> = [
        "investment", "brokerage", "cd",
        "hsa", "ira", "roth", "roth ira", "sep ira", "simple ira",
        "401k", "401a", "403b", "457b", "529", "roth 401k",
        "mutual fund", "stock plan", "pension", "retirement", "keogh",
        "thrift savings plan", "tfsa", "rrsp", "rrif", "lira", "resp", "trust",
    ]

    static func classify(_ type: String?) -> AccountKind {
        let key = (type ?? "").lowercased()
        if liabilitySubtypes.contains(key) { return .liability }
        if holdingsSubtypes.contains(key) { return .holdings }
        return .cashFlow
    }

    /// A Plaid subtype string that classifies back to this kind - used when creating a manual account (the
    /// create endpoint takes `type`, and `kind` is derived from it).
    var representativeSubtype: String {
        switch self {
        case .cashFlow: return "checking"
        case .liability: return "credit"
        case .holdings: return "investment"
        }
    }
}

extension Account {
    /// Source of this account, for grouping in the Accounts screen. (The iOS model has no `externalAccountId`,
    /// so an imported (OFX) account is told apart from a manual one by having institution metadata.)
    var isPlaid: Bool { plaidAccountId != nil }
    var isImported: Bool { !isPlaid && (institutionName.map { !$0.isEmpty } ?? false) }
    var isManual: Bool { !isPlaid && !isImported }

    /// The account's classification - a user override (`kindOverride`) wins, otherwise it's derived from
    /// the Plaid subtype.
    var kind: AccountKind {
        kindOverride.flatMap(AccountKind.init(canonical:)) ?? AccountKind.classify(type)
    }

    /// What to show as the account's name: the user's display name, or the Plaid `name` when unset.
    var displayLabel: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty { return displayName }
        return name
    }

    /// The account number's last few digits, formatted for display (e.g. "•••• 1234"); nil when unknown.
    var maskLabel: String? {
        guard let mask, !mask.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "•••• \(mask)"
    }

    /// The bank's logo URL (favicon proxy), preferring the backend-resolved domain and falling back to the
    /// on-device catalog by name; nil for manual/unknown institutions.
    @MainActor var institutionLogoURL: String? {
        InstitutionBrand.logoURL(domain: institutionDomain, name: institutionName)
    }

    /// Whether this account's outflows count toward budgets/spending. Defaults to cash-flow + credit
    /// (true spend wherever it happens); the user can override per account.
    var countsInSpending: Bool {
        includeInSpending ?? (kind == .cashFlow || kind == .liability)
    }

    /// Whether this account counts in the net-income / cash-flow view. Defaults to cash-flow accounts
    /// only (so a card payment from checking isn't double-counted); the user can override.
    var countsInCashFlow: Bool {
        includeInCashFlow ?? (kind == .cashFlow)
    }
}
