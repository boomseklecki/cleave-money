import XCTest
@testable import CleaveAPI

/// Deep-link target parsing from a notification's `(entity_type, entity_id)` or a push payload.
final class NotificationTargetTests: XCTestCase {
    private let uuid = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!

    func testValidUUIDTypes() {
        XCTAssertEqual(NotificationTarget(type: "expense", id: uuid.uuidString), .expense(uuid))
        XCTAssertEqual(NotificationTarget(type: "transaction", id: uuid.uuidString), .transaction(uuid))
        XCTAssertEqual(NotificationTarget(type: "account", id: uuid.uuidString), .account(uuid))
        XCTAssertEqual(NotificationTarget(type: "goal", id: uuid.uuidString), .goal(uuid))
        XCTAssertEqual(NotificationTarget(type: "group", id: uuid.uuidString), .group(uuid))
    }

    func testFriendIsAStringIdentifier() {
        XCTAssertEqual(NotificationTarget(type: "friend", id: "alice"), .friend("alice"))
    }

    func testRejectsBadInput() {
        XCTAssertNil(NotificationTarget(type: "expense", id: "not-a-uuid"))   // expense needs a UUID
        XCTAssertNil(NotificationTarget(type: "unknown", id: uuid.uuidString))
        XCTAssertNil(NotificationTarget(type: "expense", id: ""))
        XCTAssertNil(NotificationTarget(type: "expense", id: nil))
        XCTAssertNil(NotificationTarget(type: nil, id: uuid.uuidString))
    }

    func testIdRoundTrip() {
        XCTAssertEqual(NotificationTarget.expense(uuid).id, "expense:\(uuid)")
        XCTAssertEqual(NotificationTarget.friend("alice").id, "friend:alice")
    }
}
