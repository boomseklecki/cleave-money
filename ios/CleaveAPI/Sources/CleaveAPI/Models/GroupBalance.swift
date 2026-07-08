import Foundation
import SwiftData

/// A cached per-member balance for a group - the server-authoritative `net = paid − owed` over the
/// group's active expenses. Persisted so the Splits list and the group detail render balances instantly
/// from the last sync and update in the background, instead of waiting on a network round-trip.
@Model
final class GroupBalance {
    var groupId: UUID
    var userIdentifier: String
    var paidTotal: Decimal
    var owedTotal: Decimal
    var net: Decimal
    var updatedAt: Date

    init(groupId: UUID, userIdentifier: String, paidTotal: Decimal, owedTotal: Decimal,
         net: Decimal, updatedAt: Date) {
        self.groupId = groupId
        self.userIdentifier = userIdentifier
        self.paidTotal = paidTotal
        self.owedTotal = owedTotal
        self.net = net
        self.updatedAt = updatedAt
    }
}
