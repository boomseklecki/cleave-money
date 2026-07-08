import Foundation
import SwiftData

/// A person's membership in a group. Mirrors the server `group_members` table.
/// `userIdentifier` joins to `User.identifier`; unique per group.
@Model
final class GroupMember {
    @Attribute(.unique) var id: UUID
    var groupId: UUID
    var userIdentifier: String
    var createdAt: Date

    init(id: UUID, groupId: UUID, userIdentifier: String, createdAt: Date) {
        self.id = id
        self.groupId = groupId
        self.userIdentifier = userIdentifier
        self.createdAt = createdAt
    }
}
