import Foundation
import SwiftData

/// A person in the household directory. Mirrors the server `users` table.
/// `identifier` is the join key to `Split.userIdentifier` (a directory, not a hard FK).
@Model
final class User {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var identifier: String
    var displayName: String
    var source: UserSource
    var splitwiseUserId: String?
    var email: String?
    var avatarURL: String?
    /// Splitwise registration_status: "confirmed" | "invited" | "dummy" (nil for non-Splitwise users).
    var registrationStatus: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        identifier: String,
        displayName: String,
        source: UserSource,
        splitwiseUserId: String? = nil,
        email: String? = nil,
        avatarURL: String? = nil,
        registrationStatus: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.identifier = identifier
        self.displayName = displayName
        self.source = source
        self.splitwiseUserId = splitwiseUserId
        self.email = email
        self.avatarURL = avatarURL
        self.registrationStatus = registrationStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
