import Foundation
import SwiftData

/// A cached friend (person) with your overall pairwise balance and the per-group breakdown - the snapshot
/// the server returns from `/friends` (Splitwise `getFriends()`, the source of truth). Persisted so the
/// Friends list, friend detail, and the Inbox settle-up card render balances instantly and can navigate by
/// identifier, instead of each view re-fetching live. Refreshed on sync; we cache Splitwise's numbers (never
/// re-derive them locally - that was the old stale-balance bug). Identity (name/avatar) is resolved from the
/// `User` directory; this holds only the balance snapshot.
@Model
final class Friend {
    var identifier: String          // the person's identifier (matches a User / split user_identifier)
    var net: Decimal                // overall: net > 0 => they owe you
    var groups: [FriendGroupBalanceCache]
    var updatedAt: Date

    init(identifier: String, net: Decimal, groups: [FriendGroupBalanceCache], updatedAt: Date = Date()) {
        self.identifier = identifier
        self.net = net
        self.groups = groups
        self.updatedAt = updatedAt
    }
}

/// Your balance with a friend in one shared Splitwise group. Stored by `splitwise_group_id` (not the local
/// UUID) so the cache stays valid independent of local group sync; resolved to a local `ExpenseGroup` at read.
struct FriendGroupBalanceCache: Codable, Hashable {
    var splitwiseGroupId: String
    var name: String
    var net: Decimal                // net > 0 => they owe you in this group
}
