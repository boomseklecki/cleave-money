import Foundation
import SwiftData

/// A financial account (Plaid-linked or manual). Mirrors the server `accounts` table.
@Model
final class Account {
    @Attribute(.unique) var id: UUID
    var name: String
    /// User-set display name overriding the Plaid `name`; nil = show `name`. Survives Plaid re-sync.
    var displayName: String?
    var type: String?
    /// User-set classification override ("cash_flow" | "liability" | "savings"); nil = derive from `type`.
    var kindOverride: String?
    /// The account number's last few digits (Plaid `mask`), shown on the account row; nil for manual.
    var mask: String?
    var plaidAccountId: String?
    /// Present server-side but not returned by `GET /accounts`; left nil when mapped from the API.
    var plaidItemId: UUID?
    var balance: Decimal
    /// Available balance / credit (Plaid `balances.available`; OFX `<AVAILBAL>`). nil when unknown.
    var availableBalance: Decimal?
    var currency: String
    /// Goals-analytics inclusion overrides; nil = derive from the account's classification (subtype).
    var includeInSpending: Bool?
    var includeInCashFlow: Bool?
    /// Institution branding (denormalized from the account's bank): name, logo domain, brand hex color, and
    /// Plaid connection status. nil for manual accounts (or Plaid accounts not yet re-synced).
    var institutionName: String?
    var institutionDomain: String?
    var institutionColor: String?
    var institutionStatus: String?
    /// Zeta-style outbound sharing toward partners (owner-set): "private" | "balances" | "full". On the
    /// local cache this is always the caller's own setting - shared-in (partner-owned) accounts are never
    /// persisted, so the analytics/net-worth queries stay owner-pure.
    var shareLevel: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        displayName: String? = nil,
        type: String? = nil,
        kindOverride: String? = nil,
        mask: String? = nil,
        plaidAccountId: String? = nil,
        plaidItemId: UUID? = nil,
        balance: Decimal,
        availableBalance: Decimal? = nil,
        currency: String,
        includeInSpending: Bool? = nil,
        includeInCashFlow: Bool? = nil,
        institutionName: String? = nil,
        institutionDomain: String? = nil,
        institutionColor: String? = nil,
        institutionStatus: String? = nil,
        shareLevel: String = "private",
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.type = type
        self.kindOverride = kindOverride
        self.mask = mask
        self.plaidAccountId = plaidAccountId
        self.plaidItemId = plaidItemId
        self.balance = balance
        self.availableBalance = availableBalance
        self.currency = currency
        self.includeInSpending = includeInSpending
        self.includeInCashFlow = includeInCashFlow
        self.institutionName = institutionName
        self.institutionDomain = institutionDomain
        self.institutionColor = institutionColor
        self.institutionStatus = institutionStatus
        self.shareLevel = shareLevel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// How much of an account an owner exposes to a connected partner (Zeta-style). Backed by `share_level`.
enum AccountShareLevel: String, CaseIterable, Identifiable {
    case _private = "private"   // owner only - partner sees nothing
    case balances               // partner sees the balance, not transactions
    case full                   // partner sees balance + transactions

    var id: String { rawValue }

    var label: String {
        switch self {
        case ._private: return "Private"
        case .balances: return "Balances only"
        case .full: return "Full access"
        }
    }
}

extension Account {
    var shareLevelValue: AccountShareLevel { AccountShareLevel(rawValue: shareLevel) ?? ._private }
}
