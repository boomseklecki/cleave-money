import Foundation
import SwiftData

/// Caller identity from `GET /me`.
struct MeInfo: Equatable {
    var identifier: String?
    var authenticated: Bool
}

/// The signed-in user's profile (from `GET /me`). Nil means open mode / not signed in.
public struct CurrentUser: Equatable, Sendable {
    public var id: UUID
    public var identifier: String
    public var displayName: String
    public var email: String?
    public var avatarURL: String?
    /// True when a custom (MinIO) avatar is set - drives "add" vs "edit/delete" in Settings.
    public var hasCustomAvatar: Bool = false
    /// The saved pinch/pan transform, for reloading the crop editor (nil when no custom avatar).
    public var avatarCrop: AvatarCrop?
    /// Whether this user is configured as a backend admin (gates admin-only settings/features).
    public var isAdmin: Bool = false
}

/// Reads/writes the people directory (`/users`, `/me`) and reconciles into SwiftData.
@MainActor
struct UserRepository {
    let client: Client
    let context: ModelContext

    func refresh(source: UserSource? = nil, updatedSince: Date? = nil) async throws {
        let output = try await client.list_users_users_get(query: .init(
            source: source.map(Mapping.apiUserSource),
            updated_since: updatedSince
        ))
        let responses = try output.ok.body.json
        try upsert(responses)
        // A full, unfiltered refresh is the authoritative scoped directory (local logins + your
        // friends/partners/co-members): prune any local rows the server no longer returns, so a device that
        // once cached the whole roster drops strangers it's no longer allowed to see. Skip for incremental
        // (`updatedSince`) or `source`-filtered fetches - those are partial views and must not delete.
        if source == nil && updatedSince == nil {
            try reconcile(keeping: responses)
        }
    }

    /// Delete cached `User` rows absent from a full directory response. Safe: `User` is a standalone
    /// directory cache (splits/groups reference the string identifier, not the row), so a dropped name just
    /// falls back to the title-cased identifier - and everyone you share with stays in scope, so is kept.
    private func reconcile(keeping responses: [Components.Schemas.UserResponse]) throws {
        let keep = Set(responses.compactMap { try? Mapping.uuid($0.id, field: "User.id") })
        var changed = false
        for user in try context.fetch(FetchDescriptor<User>()) where !keep.contains(user.id) {
            context.delete(user)
            changed = true
        }
        if changed { try context.save() }
    }

    func me() async throws -> MeInfo {
        let response = try await client.me_me_get().ok.body.json
        return MeInfo(identifier: response.identifier, authenticated: response.authenticated)
    }

    /// The signed-in user's full profile, or nil in open mode / when not signed in. Throws
    /// `BackendError.http(401)` when the token is rejected (so callers can clear a stale session).
    func currentUser() async throws -> CurrentUser? {
        let output = try await client.me_me_get()
        let ok = try output.ok
        let me = try ok.body.json
        guard let user = me.user else { return nil }
        return CurrentUser(
            id: try Mapping.uuid(user.id, field: "User.id"),
            identifier: user.identifier, displayName: user.display_name,
            email: user.email, avatarURL: user.avatar_url,
            hasCustomAvatar: user.has_custom_avatar ?? false,
            avatarCrop: user.avatar_crop.map { AvatarCrop(scale: $0.scale, dx: $0.dx, dy: $0.dy) },
            isAdmin: me.is_admin ?? false
        )
    }

    @discardableResult
    func create(_ draft: UserDraft) async throws -> UUID {
        let output = try await client.create_user_users_post(body: .json(Mapping.userCreate(draft)))
        let created = try output.created
        let response = try created.body.json
        try upsert([response])
        return try Mapping.uuid(response.id, field: "User.id")
    }

    func update(id: UUID, displayName: String? = nil, email: String? = nil) async throws {
        let output = try await client.update_user_users__user_id__patch(
            path: .init(user_id: id.uuidString),
            body: .json(.init(display_name: displayName, email: email))
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    func delete(id: UUID) async throws {
        let output = try await client.delete_user_users__user_id__delete(
            path: .init(user_id: id.uuidString)
        )
        _ = try output.noContent
        if let existing = try context.fetch(
            FetchDescriptor<User>(predicate: #Predicate { $0.id == id })
        ).first {
            context.delete(existing)
            try context.save()
        }
    }

    /// Admin: the server's local accounts (`source == app`), with live enrolled/admin status. Fetched fresh
    /// for the admin Local Users view - not cached into SwiftData (that's the scoped Friends directory).
    func localUsers() async throws -> [Components.Schemas.UserResponse] {
        let output = try await client.list_users_users_get(query: .init(source: Mapping.apiUserSource(.app)))
        return try output.ok.body.json
    }

    /// Admin: revoke a user's access (de-enroll) - reversible; keeps their identity + shared history.
    func revoke(id: UUID) async throws {
        let output = try await client.revoke_user_users__user_id__revoke_post(
            path: .init(user_id: id.uuidString)
        )
        _ = try output.noContent
    }

    func upsert(_ responses: [Components.Schemas.UserResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "User.id")
            if let existing = try context.fetch(
                FetchDescriptor<User>(predicate: #Predicate { $0.id == id })
            ).first {
                existing.identifier = r.identifier
                existing.displayName = r.display_name
                existing.source = Mapping.userSource(r.source)
                existing.splitwiseUserId = r.splitwise_user_id
                existing.email = r.email
                existing.avatarURL = r.avatar_url
                existing.registrationStatus = r.registration_status
                existing.createdAt = r.created_at
                existing.updatedAt = r.updated_at
            } else {
                context.insert(try Mapping.user(r))
            }
        }
        try context.save()
    }
}
