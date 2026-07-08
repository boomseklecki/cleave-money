import XCTest
import CleaveAPI
@testable import CleaveAPI

/// Phase 2 additions: user/member/balance forward mappers, reverse (draft → request) mappers,
/// and the new `archivedAt` field.
final class MappingPhase2Tests: XCTestCase {
    private let uuidA = "11111111-1111-1111-1111-111111111111"
    private let uuidB = "22222222-2222-2222-2222-222222222222"
    private let epoch = Date(timeIntervalSince1970: 0)

    func testUserMapping() throws {
        let response = Components.Schemas.UserResponse(
            id: uuidA, identifier: "alice", display_name: "Alice", source: .app,
            splitwise_user_id: "sw-1", email: "m@x.com", enrolled: true, is_admin: false,
            created_at: epoch, updated_at: epoch
        )
        let user = try Mapping.user(response)
        XCTAssertEqual(user.identifier, "alice")
        XCTAssertEqual(user.displayName, "Alice")
        XCTAssertEqual(user.source, .app)
        XCTAssertEqual(user.splitwiseUserId, "sw-1")
        XCTAssertEqual(user.email, "m@x.com")
    }

    func testGroupMemberMapping() throws {
        let response = Components.Schemas.GroupMemberResponse(
            id: uuidA, group_id: uuidB, user_identifier: "bob", created_at: epoch
        )
        let member = try Mapping.groupMember(response)
        XCTAssertEqual(member.groupId, UUID(uuidString: uuidB))
        XCTAssertEqual(member.userIdentifier, "bob")
    }

    func testBalanceMapping() throws {
        let entry = Components.Schemas.BalanceEntry(
            identifier: "alice", display_name: "Alice",
            paid_total: "100.00", owed_total: "60.00", net: "40.00"
        )
        let balance = try Mapping.balance(entry)
        XCTAssertEqual(balance.net, Decimal(string: "40.00"))
        XCTAssertEqual(balance.paidTotal, Decimal(string: "100.00"))
    }

    // MARK: Reverse mappers

    func testExpenseCreateUsesStringMoneyAndUUIDs() {
        let groupId = UUID(uuidString: uuidB)!
        let draft = ExpenseDraft(
            groupId: groupId, details: "Groceries", amount: Decimal(string: "12.34")!,
            date: Mapping.dateOnlyFormatter.date(from: "2026-06-19")!, category: "food",
            splits: [SplitDraft(userIdentifier: "alice", paidShare: Decimal(string: "12.34")!, owedShare: Decimal(string: "6.17")!)]
        )
        let create = Mapping.expenseCreate(draft)
        XCTAssertEqual(create.amount, "12.34")
        XCTAssertEqual(create.group_id, groupId.uuidString)
        XCTAssertEqual(create.date, "2026-06-19")
        XCTAssertEqual(create.category, "food")
        XCTAssertEqual(create.splits?.count, 1)
        XCTAssertEqual(create.splits?.first?.paid_share, "12.34")
        XCTAssertEqual(create.splits?.first?.owed_share, "6.17")
    }

    func testUserCreateMapping() {
        let create = Mapping.userCreate(UserDraft(displayName: "Bob", source: .manual))
        XCTAssertEqual(create.display_name, "Bob")
        XCTAssertEqual(create.source, .manual)
        XCTAssertNil(create.identifier)
    }
}
