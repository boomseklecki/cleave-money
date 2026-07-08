import Foundation
import SwiftData

/// A budgeting goal, derived from Plaid data. Mirrors the server `goals` table. Two kinds:
/// - `.spend`: a Mint-style monthly budget capping spend in `category` at `targetAmount`.
/// - `.save`: grow `accountId`'s balance; `saveTargetType` is reach-a-balance or save-an-amount,
///   measured from the `startingBalance`/`startingDate` snapshot taken at creation.
/// Progress is computed client-side (see `GoalProgress`) - never stored.
@Model
final class Goal {
    @Attribute(.unique) var id: UUID
    var kind: String
    var name: String
    var category: String?
    var accountId: UUID?
    var targetAmount: Decimal
    var saveTargetType: String?
    var startingBalance: Decimal?
    var startingDate: Date?
    var period: String
    var currency: String
    var archivedAt: Date?
    /// Owner's flag: this goal is visible read-only to connected partners. On the local cache this is the
    /// caller's own setting - shared-in (partner-owned) goals are never persisted (live-fetched for display).
    var shared: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        kind: String,
        name: String,
        category: String? = nil,
        accountId: UUID? = nil,
        targetAmount: Decimal,
        saveTargetType: String? = nil,
        startingBalance: Decimal? = nil,
        startingDate: Date? = nil,
        period: String = "monthly",
        currency: String,
        archivedAt: Date? = nil,
        shared: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.category = category
        self.accountId = accountId
        self.targetAmount = targetAmount
        self.saveTargetType = saveTargetType
        self.startingBalance = startingBalance
        self.startingDate = startingDate
        self.period = period
        self.currency = currency
        self.archivedAt = archivedAt
        self.shared = shared
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var goalKind: GoalKind { GoalKind(rawValue: kind) ?? .spend }
    var saveTarget: SaveTargetType? { saveTargetType.flatMap(SaveTargetType.init(rawValue:)) }
}

/// What a goal tracks.
enum GoalKind: String, CaseIterable {
    case spend  // a monthly category budget
    case save   // grow an account's balance
}

/// How a savings goal's target is interpreted.
enum SaveTargetType: String, CaseIterable {
    case balance  // reach an absolute balance
    case amount   // add this much from the starting snapshot
}
