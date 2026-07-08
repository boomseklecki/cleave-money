import Foundation
import SwiftData

/// Unambiguous alias for the `Group` model, for use in view files that also import SwiftUI
/// (where bare `Group` would resolve to SwiftUI's layout container). Defined here, where only
/// SwiftData is imported, so it binds to the model.
typealias ExpenseGroup = Group

/// A self-hosted or Splitwise-backed expense group. Mirrors the server `groups` table.
@Model
final class Group {
    @Attribute(.unique) var id: UUID
    var name: String
    var backendType: BackendType
    var splitwiseGroupId: String?
    /// Splitwise group metadata (nil for self-hosted): type (apartment/trip/...), avatar + cover image URLs.
    var groupType: String?
    var avatarURL: String?
    var coverPhotoURL: String?
    /// True when a custom (MinIO) group avatar is set - drives "add" vs "edit/delete" in GroupDetailView.
    var hasCustomAvatar: Bool = false
    /// The saved pinch/pan transform for the custom group avatar (nil when none), for reloading the editor.
    var avatarCropScale: Double?
    var avatarCropDx: Double?
    var avatarCropDy: Double?
    var hidden: Bool
    /// The caller's per-user budget overrides (from `group_overrides`); nil = the default (included).
    var includeInSpending: Bool?
    var includeInCashFlow: Bool?
    /// Internal "superseded by a local import" marker (nil = active); such groups are hidden everywhere.
    var supersededAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        backendType: BackendType,
        splitwiseGroupId: String? = nil,
        groupType: String? = nil,
        avatarURL: String? = nil,
        coverPhotoURL: String? = nil,
        hidden: Bool = false,
        includeInSpending: Bool? = nil,
        includeInCashFlow: Bool? = nil,
        supersededAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.backendType = backendType
        self.splitwiseGroupId = splitwiseGroupId
        self.groupType = groupType
        self.avatarURL = avatarURL
        self.coverPhotoURL = coverPhotoURL
        self.hidden = hidden
        self.includeInSpending = includeInSpending
        self.includeInCashFlow = includeInCashFlow
        self.supersededAt = supersededAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The saved group-avatar crop assembled from its stored components (nil when no custom avatar).
    var avatarCrop: AvatarCrop? {
        guard hasCustomAvatar, let s = avatarCropScale, let x = avatarCropDx, let y = avatarCropDy else { return nil }
        return AvatarCrop(scale: s, dx: x, dy: y)
    }
}
