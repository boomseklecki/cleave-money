import Foundation
import SwiftData

/// Reads groups from the backend and reconciles them into SwiftData (upsert by `id`).
/// The server is authoritative; SwiftData is a cache.
@MainActor
struct GroupRepository {
    let client: Client
    let context: ModelContext

    /// Fetches groups (defaults exclude hidden, matching the API; superseded are always excluded) and upserts.
    func refresh(
        backendType: BackendType? = nil,
        includeHidden: Bool = false,
        updatedSince: Date? = nil
    ) async throws {
        let output = try await client.list_groups_groups_get(query: .init(
            backend_type: backendType.map(Self.apiBackendType),
            include_hidden: includeHidden,
            updated_since: updatedSince
        ))
        try upsert(try output.ok.body.json)
    }

    /// Re-fetch one group (e.g. after its avatar changed) and upsert it.
    func refresh(id: UUID) async throws {
        let output = try await client.get_group_groups__group_id__get(path: .init(group_id: id.uuidString))
        try upsert([try output.ok.body.json])
    }

    // MARK: Writes

    @discardableResult
    func create(name: String, backendType: BackendType = .selfHosted, groupType: String? = nil) async throws -> UUID {
        let output = try await client.create_group_groups_post(body: .json(.init(
            name: name, backend_type: Self.apiBackendType(backendType), group_type: groupType)))
        let created = try output.created
        let response = try created.body.json
        try upsert([response])
        return try Mapping.uuid(response.id, field: "Group.id")
    }

    func update(
        id: UUID, name: String? = nil, hidden: Bool? = nil,
        includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil
    ) async throws {
        let output = try await client.update_group_groups__group_id__patch(
            path: .init(group_id: id.uuidString),
            body: .json(.init(
                name: name, hidden: hidden,
                include_in_spending: includeInSpending, include_in_cash_flow: includeInCashFlow
            ))
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    /// Permanently deletes a self-hosted group (and its expenses); the backend 409s for Splitwise groups.
    func delete(id: UUID) async throws {
        let output = try await client.delete_group_groups__group_id__delete(
            path: .init(group_id: id.uuidString)
        )
        _ = try output.noContent
        for local in try context.fetch(
            FetchDescriptor<Group>(predicate: #Predicate { $0.id == id })
        ) { context.delete(local) }
        try context.save()
    }

    // MARK: Members

    func refreshMembers(groupId: UUID) async throws {
        let output = try await client.list_members_groups__group_id__members_get(
            path: .init(group_id: groupId.uuidString)
        )
        try upsertMembers(groupId: groupId, try output.ok.body.json)
    }

    func addMember(
        groupId: UUID, userIdentifier: String? = nil,
        email: String? = nil, firstName: String? = nil, lastName: String? = nil
    ) async throws {
        let output = try await client.add_member_groups__group_id__members_post(
            path: .init(group_id: groupId.uuidString),
            body: .json(.init(
                user_identifier: userIdentifier, email: email,
                first_name: firstName, last_name: lastName))
        )
        _ = try output.created
        try await refreshMembers(groupId: groupId)
    }

    func removeMember(groupId: UUID, userIdentifier: String) async throws {
        let output = try await client.remove_member_groups__group_id__members__user_identifier__delete(
            path: .init(group_id: groupId.uuidString, user_identifier: userIdentifier)
        )
        _ = try output.noContent
        try await refreshMembers(groupId: groupId)
    }

    /// Removes several members concurrently, then refreshes the member list ONCE (vs N delete + N refetch via
    /// `removeMember`). A 404 is treated as already-removed (silent skip). Surfaces the first real error after
    /// the refresh, so a partial failure still leaves the list reconciled.
    func removeMembers(groupId: UUID, identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        let client = self.client
        let firstError = await withTaskGroup(of: Error?.self) { group in
            for identifier in identifiers {
                group.addTask {
                    do {
                        _ = try await client
                            .remove_member_groups__group_id__members__user_identifier__delete(
                                path: .init(group_id: groupId.uuidString, user_identifier: identifier)).noContent
                        return nil
                    } catch BackendError.notFound {
                        return nil   // already removed - skip
                    } catch { return error }
                }
            }
            var first: Error?
            for await e in group { if let e, first == nil { first = e } }
            return first
        }
        try await refreshMembers(groupId: groupId)
        if let firstError { throw firstError }
    }

    /// Clones an already-imported Splitwise group into a new self-hosted group (archives the source).
    /// Returns the new local group's id. Caller should refresh groups + expenses afterward.
    @discardableResult
    func importLocal(groupId: UUID, name: String? = nil) async throws -> UUID {
        let output = try await client.import_group_local_splitwise_groups__group_id__import_local_post(
            path: .init(group_id: groupId.uuidString),
            body: .json(.init(name: name))
        )
        let ok = try output.ok
        let result = try ok.body.json
        try upsert([result.group])
        return try Mapping.uuid(result.group.id, field: "Group.id")
    }

    /// Splitwise groups the caller is a member of that were deleted through the app (restorable), newest first.
    func deletedGroups() async throws -> [Components.Schemas.GroupResponse] {
        let output = try await client.list_deleted_groups_groups_deleted_get()
        let ok = try output.ok
        return try ok.body.json
    }

    /// Restores a deleted Splitwise group (undelete on Splitwise + its expenses, clear the flag, re-sync).
    /// Any member can call this. Upserts the restored group locally.
    func restore(groupId: UUID) async throws {
        let output = try await client.restore_group_groups__group_id__restore_post(
            path: .init(group_id: groupId.uuidString)
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    private func upsertMembers(groupId: UUID, _ responses: [Components.Schemas.GroupMemberResponse]) throws {
        let existing = try context.fetch(
            FetchDescriptor<GroupMember>(predicate: #Predicate { $0.groupId == groupId })
        )
        for member in existing { context.delete(member) }
        for r in responses { context.insert(try Mapping.groupMember(r)) }
        try context.save()
    }

    /// Full fetch (incl. archived + hidden) that also deletes local groups the server no longer has.
    /// `updated_since` only reports creates/updates, so this is how cached deletes are reconciled.
    func reconcileAll() async throws {
        let responses = try await client.list_groups_groups_get(query: .init(
            include_hidden: true
        )).ok.body.json
        try upsert(responses)
        let keep = Set(try responses.map { try Mapping.uuid($0.id, field: "Group.id") })
        for local in try context.fetch(FetchDescriptor<Group>()) where !keep.contains(local.id) {
            context.delete(local)
        }
        try context.save()
    }

    /// Upserts a batch of group responses by `id`.
    func upsert(_ responses: [Components.Schemas.GroupResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Group.id")
            if let existing = try context.fetch(
                FetchDescriptor<Group>(predicate: #Predicate { $0.id == id })
            ).first {
                existing.name = r.name
                existing.backendType = Mapping.backendType(r.backend_type)
                existing.splitwiseGroupId = r.splitwise_group_id
                existing.groupType = r.group_type
                existing.avatarURL = r.avatar_url
                existing.coverPhotoURL = r.cover_photo_url
                existing.hasCustomAvatar = r.has_custom_avatar ?? false
                existing.avatarCropScale = r.avatar_crop?.scale
                existing.avatarCropDx = r.avatar_crop?.dx
                existing.avatarCropDy = r.avatar_crop?.dy
                existing.hidden = r.hidden
                existing.includeInSpending = r.include_in_spending
                existing.includeInCashFlow = r.include_in_cash_flow
                existing.supersededAt = r.superseded_at
                existing.createdAt = r.created_at
                existing.updatedAt = r.updated_at
            } else {
                context.insert(try Mapping.group(r))
            }
        }
        try context.save()
    }

    private static func apiBackendType(_ value: BackendType) -> Components.Schemas.BackendType {
        switch value {
        case .selfHosted: return .self_hosted
        case .splitwise: return .splitwise
        }
    }
}
