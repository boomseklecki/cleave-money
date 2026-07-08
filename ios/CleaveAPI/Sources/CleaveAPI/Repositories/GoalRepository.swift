import Foundation
import SwiftData

/// Reads/writes budgeting goals and reconciles them into SwiftData. Goals are small and fully
/// owned by the app, so `refresh` mirrors the active set exactly (archived/deleted ones vanish).
@MainActor
struct GoalRepository {
    let client: Client
    let context: ModelContext

    /// Reconciles the active goals: upsert those returned, drop locals the server no longer lists.
    /// Only the caller's OWN goals are cached; partner-shared goals (`shared_by_identifier != nil`) are never
    /// persisted (live-fetched read-only via `sharedInGoals()`), so they stay out of budgets/analytics.
    func refresh() async throws {
        let responses = try await client.list_goals_goals_get(query: .init(include_archived: false))
            .ok.body.json
        let own = responses.filter { $0.shared_by_identifier == nil }
        try upsert(own)
        let keep = Set(try own.map { try Mapping.uuid($0.id, field: "Goal.id") })
        for local in try context.fetch(FetchDescriptor<Goal>()) where !keep.contains(local.id) {
            context.delete(local)
        }
        try context.save()
    }

    /// Goals a partner has marked shared with the caller (read-only). Transient - never cached.
    func sharedInGoals() async throws -> [Components.Schemas.GoalResponse] {
        let responses = try await client.list_goals_goals_get(query: .init(include_archived: false))
            .ok.body.json
        return responses.filter { $0.shared_by_identifier != nil }
    }

    @discardableResult
    func create(_ draft: GoalDraft) async throws -> UUID {
        let output = try await client.create_goal_goals_post(body: .json(Mapping.goalCreate(draft)))
        let created = try output.created
        let response = try created.body.json
        try upsert([response])
        return try Mapping.uuid(response.id, field: "Goal.id")
    }

    func update(id: UUID, _ draft: GoalDraft) async throws {
        let output = try await client.update_goal_goals__goal_id__patch(
            path: .init(goal_id: id.uuidString), body: .json(Mapping.goalUpdate(draft))
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    func delete(id: UUID) async throws {
        let output = try await client.delete_goal_goals__goal_id__delete(
            path: .init(goal_id: id.uuidString)
        )
        _ = try output.noContent
        if let existing = try context.fetch(
            FetchDescriptor<Goal>(predicate: #Predicate { $0.id == id })
        ).first {
            context.delete(existing)
            try context.save()
        }
    }

    func upsert(_ responses: [Components.Schemas.GoalResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Goal.id")
            let mapped = try Mapping.goal(r)
            guard let existing = try context.fetch(
                FetchDescriptor<Goal>(predicate: #Predicate { $0.id == id })
            ).first else {
                context.insert(mapped)
                continue
            }
            existing.kind = mapped.kind
            existing.name = mapped.name
            existing.category = mapped.category
            existing.accountId = mapped.accountId
            existing.targetAmount = mapped.targetAmount
            existing.saveTargetType = mapped.saveTargetType
            existing.startingBalance = mapped.startingBalance
            existing.startingDate = mapped.startingDate
            existing.period = mapped.period
            existing.currency = mapped.currency
            existing.archivedAt = mapped.archivedAt
            existing.shared = mapped.shared
            existing.createdAt = mapped.createdAt
            existing.updatedAt = mapped.updatedAt
        }
        try context.save()
    }
}
