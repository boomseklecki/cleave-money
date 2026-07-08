import Foundation
import SwiftData

/// Fetches server-computed balances (`/groups/{id}/balances`) and caches them as `GroupBalance` rows, so
/// the Splits list and group detail render from the cache instantly and update in the background. Balances
/// are authoritative server values (`net = paid − owed` over active expenses) - not recomputed locally,
/// which would drift when the local expense cache is incomplete.
@MainActor
struct BalanceRepository {
    let client: Client
    let context: ModelContext

    /// Fetch one group's balances and replace its cached rows.
    func refreshGroup(_ groupId: UUID) async throws {
        let entries = try await client.group_balances_groups__group_id__balances_get(
            path: .init(group_id: groupId.uuidString)
        ).ok.body.json.map(Mapping.balance)
        try replace(groupId: groupId, with: entries)
    }

    /// Refresh every group's balances (best-effort per group). Background work behind the cached display.
    func refreshAll(_ groupIds: [UUID]) async {
        for id in groupIds { try? await refreshGroup(id) }
    }

    /// The caller's Splitwise-style pairwise balance with each person, combined across all groups
    /// (server-computed - the local expense cache is incomplete for large groups). net > 0 ⇒ they owe you.
    func friends() async throws -> [Components.Schemas.FriendBalance] {
        try await client.friends_friends_get().ok.body.json
    }

    /// Fetch the pairwise friend balances and cache them as `Friend` rows so the Friends list, friend detail,
    /// and the Inbox settle-up card render + navigate from the cache (a snapshot of Splitwise's numbers).
    func refreshFriends() async throws {
        try BalanceRepository.upsertFriends(try await friends(), into: context)
    }

    /// Upsert the friend-balance snapshot into the `Friend` cache, pruning friends no longer returned. Pure
    /// DB work (static, no client) so it's unit-testable on an in-memory context.
    static func upsertFriends(_ balances: [Components.Schemas.FriendBalance], into context: ModelContext) throws {
        let keep = Set(balances.map(\.identifier))
        for stale in try context.fetch(FetchDescriptor<Friend>()) where !keep.contains(stale.identifier) {
            context.delete(stale)
        }
        let now = Date()
        for fb in balances {
            guard let net = try? Mapping.decimal(fb.net, field: "FriendBalance.net") else { continue }
            let groups: [FriendGroupBalanceCache] = (fb.groups ?? []).compactMap { g in
                guard let gnet = try? Mapping.decimal(g.net, field: "FriendGroupBalance.net") else { return nil }
                return FriendGroupBalanceCache(splitwiseGroupId: g.splitwise_group_id,
                                               name: g.name ?? "Group", net: gnet)
            }
            let id = fb.identifier
            if let existing = try context.fetch(
                FetchDescriptor<Friend>(predicate: #Predicate { $0.identifier == id })
            ).first {
                existing.net = net
                existing.groups = groups
                existing.updatedAt = now
            } else {
                context.insert(Friend(identifier: id, net: net, groups: groups, updatedAt: now))
            }
        }
        try context.save()
    }

    private func replace(groupId: UUID, with balances: [Balance]) throws {
        for stale in try context.fetch(
            FetchDescriptor<GroupBalance>(predicate: #Predicate { $0.groupId == groupId })
        ) {
            context.delete(stale)
        }
        let now = Date()
        for b in balances {
            context.insert(GroupBalance(
                groupId: groupId, userIdentifier: b.identifier, paidTotal: b.paidTotal,
                owedTotal: b.owedTotal, net: b.net, updatedAt: now))
        }
        try context.save()
    }
}
