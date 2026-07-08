import Foundation

/// Single-use enrollment invites (create / list / revoke). Transient API objects - not cached in SwiftData.
@MainActor
struct InviteRepository {
    let client: Client

    @discardableResult
    func create(label: String?, ttlDays: Int? = 14) async throws -> Components.Schemas.InviteResponse {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = try await client.create_invite_invites_post(
            body: .json(.init(label: (trimmed?.isEmpty == false) ? trimmed : nil, ttl_days: ttlDays)))
        let created = try output.created
        return try created.body.json
    }

    func list() async throws -> [Components.Schemas.InviteResponse] {
        try await client.list_invites_invites_get().ok.body.json
    }

    func revoke(id: UUID) async throws {
        let output = try await client.revoke_invite_invites__invite_id__delete(
            path: .init(invite_id: id.uuidString))
        _ = try output.noContent
    }
}
