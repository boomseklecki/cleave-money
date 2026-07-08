import SwiftData
import XCTest
@testable import CleaveAPI

/// The local `Friend` balance cache: upsert/prune of the `/friends` snapshot, and projecting a cached
/// `Friend` into a `FriendRow` (resolving the Splitwise group id to a local group).
@MainActor
final class FriendCacheTests: XCTestCase {
    private func context() throws -> ModelContext {
        ModelContext(try CleaveStore.makeModelContainer(inMemory: true))
    }

    private func balance(_ id: String, _ net: String,
                         groups: [(sw: String, name: String, net: String)] = []) -> Components.Schemas.FriendBalance {
        .init(identifier: id, display_name: id.capitalized, net: net,
              groups: groups.map { .init(splitwise_group_id: $0.sw, name: $0.name, net: $0.net) })
    }

    private func friends(_ ctx: ModelContext) throws -> [Friend] {
        try ctx.fetch(FetchDescriptor<Friend>())
    }

    func testUpsertInsertsUpdatesAndPrunes() throws {
        let ctx = try context()

        // Insert: one friend with a per-group balance.
        try BalanceRepository.upsertFriends([balance("alice", "10", groups: [("SW1", "House", "10")])], into: ctx)
        var rows = try friends(ctx)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.net, 10)
        XCTAssertEqual(rows.first?.groups.first?.splitwiseGroupId, "SW1")

        // Update: same friend, new net.
        try BalanceRepository.upsertFriends([balance("alice", "-5")], into: ctx)
        rows = try friends(ctx)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.net, -5)
        XCTAssertTrue(rows.first?.groups.isEmpty ?? false)

        // Prune: alice absent from the new snapshot → removed; bob inserted.
        try BalanceRepository.upsertFriends([balance("bob", "3")], into: ctx)
        rows = try friends(ctx)
        XCTAssertEqual(rows.map(\.identifier), ["bob"])
    }

    func testFriendRowProjectionResolvesLocalGroup() throws {
        let local = Group(id: UUID(), name: "House", backendType: .splitwise, splitwiseGroupId: "SW1",
                          createdAt: Date(), updatedAt: Date())
        let user = User(id: UUID(), identifier: "alice", displayName: "Alice", source: .splitwise,
                        createdAt: Date(), updatedAt: Date())
        let friend = Friend(identifier: "alice", net: 10, groups: [
            FriendGroupBalanceCache(splitwiseGroupId: "SW1", name: "House (sw)", net: 6),
            FriendGroupBalanceCache(splitwiseGroupId: "SW2", name: "Trip", net: 4),
        ])

        let row = FriendRow(friend: friend, allGroups: [local], users: [user])
        XCTAssertEqual(row.id, "alice")
        XCTAssertEqual(row.name, "Alice")
        // Resolved local group wins (groupId set, local name); unresolved keeps the cached name + nil id.
        let resolved = row.groups.first { $0.net == 6 }
        XCTAssertEqual(resolved?.groupId, local.id)
        XCTAssertEqual(resolved?.name, "House")
        let unresolved = row.groups.first { $0.net == 4 }
        XCTAssertNil(unresolved?.groupId)
        XCTAssertEqual(unresolved?.name, "Trip")
    }
}
