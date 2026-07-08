import Foundation
import SwiftData

/// Reads expenses (with splits/items/receipts) from the backend and reconciles them into SwiftData.
/// Because the server replaces splits/items wholesale, an existing expense is deleted (cascading its
/// children) and re-inserted from the fresh response, keeping the cache an exact mirror.
@MainActor
struct ExpenseRepository {
    let client: Client
    let context: ModelContext

    func refresh(
        groupId: UUID? = nil,
        since: Date? = nil,
        until: Date? = nil,
        updatedSince: Date? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) async throws {
        let output = try await client.list_expenses_expenses_get(query: .init(
            group_id: groupId?.uuidString,
            since: since.map(Mapping.dateOnlyFormatter.string(from:)),
            until: until.map(Mapping.dateOnlyFormatter.string(from:)),
            updated_since: updatedSince,
            limit: limit,
            offset: offset
        ))
        try upsert(try output.ok.body.json)
    }

    // MARK: Writes

    /// Creates an expense. For a Splitwise group the backend pushes to Splitwise first (push-first),
    /// so a 422/409/502 here means the upstream push failed and nothing was stored.
    ///
    /// `idempotencyKey` (a UUID the view mints once per create form) is sent as the `Idempotency-Key` header
    /// so a retry of the same create - double-tap, or a retry after a lost response where the server actually
    /// committed - returns the original expense instead of a duplicate (and no second Splitwise push). See
    /// `IdempotencyMiddleware`.
    @discardableResult
    func create(_ draft: ExpenseDraft, idempotencyKey: String? = nil) async throws -> UUID {
        let output = try await IdempotencyContext.$key.withValue(idempotencyKey) {
            try await client.create_expense_expenses_post(
                body: .json(Mapping.expenseCreate(draft))
            )
        }
        let created = try output.created
        let response = try created.body.json
        try upsert([response])
        return try Mapping.uuid(response.id, field: "Expense.id")
    }

    func update(id: UUID, _ draft: ExpenseDraft) async throws {
        let output = try await client.update_expense_expenses__expense_id__patch(
            path: .init(expense_id: id.uuidString),
            body: .json(Mapping.expenseUpdate(draft))
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    /// Replaces the expense's line items (the backend upserts by id, so passing existing items with their ids
    /// + new ones appends). Only `items` is sent; other fields are untouched.
    func setItems(id: UUID, items: [ItemDraft], updatedBy: String?) async throws {
        let output = try await client.update_expense_expenses__expense_id__patch(
            path: .init(expense_id: id.uuidString),
            body: .json(.init(
                group_id: nil, description: nil, amount: nil, currency: nil,
                date: nil, category: nil, notes: nil, updated_by: updatedBy,
                transaction_id: nil, splits: nil, items: items.map(Mapping.itemInput)
            ))
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    /// Patches only the category (splits/items untouched server-side; pushes to Splitwise for
    /// linked expenses).
    func updateCategory(id: UUID, category: String, updatedBy: String?) async throws {
        let output = try await client.update_expense_expenses__expense_id__patch(
            path: .init(expense_id: id.uuidString),
            body: .json(.init(
                group_id: nil, description: nil, amount: nil, currency: nil,
                date: nil, category: category, notes: nil, updated_by: updatedBy,
                transaction_id: nil, splits: nil, items: nil
            ))
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    /// Applies the same category to many expenses at once (bulk recategorize from "Find Related Expenses").
    /// The PATCHes run **concurrently** and every response is cached in a **single** save - mirroring
    /// `AccountRepository.setCategoryOverride(ids:)`. An expense the server no longer has (404) is skipped so
    /// one stale member can't fail the batch. Each PATCH still pushes to Splitwise for synced expenses.
    func updateCategory(ids: [UUID], category: String, updatedBy: String?) async throws {
        guard !ids.isEmpty else { return }
        let client = self.client
        let responses = try await withThrowingTaskGroup(
            of: Components.Schemas.ExpenseResponse?.self
        ) { group in
            for id in ids {
                group.addTask {
                    do {
                        let ok = try await client.update_expense_expenses__expense_id__patch(
                            path: .init(expense_id: id.uuidString),
                            body: .json(.init(
                                group_id: nil, description: nil, amount: nil, currency: nil,
                                date: nil, category: category, notes: nil, updated_by: updatedBy,
                                transaction_id: nil, splits: nil, items: nil))).ok
                        return try ok.body.json
                    } catch BackendError.notFound {
                        return nil  // expense gone - skip, apply to the rest
                    }
                }
            }
            var out: [Components.Schemas.ExpenseResponse] = []
            for try await r in group { if let r { out.append(r) } }
            return out
        }
        try upsert(responses)
    }

    /// Links this expense to a bank/manual transaction (or unlinks, with nil) so spending counts your
    /// owed share once instead of both the gross transaction and your share. Local-only - never pushed to
    /// Splitwise; splits/amount untouched.
    func linkTransaction(expenseId: UUID, transactionId: UUID?) async throws {
        let output = try await client.link_expense_transaction_expenses__expense_id__transaction_link_put(
            path: .init(expense_id: expenseId.uuidString),
            body: .json(.init(transaction_id: transactionId?.uuidString))
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    /// Deletes an expense. `propagate` overrides the backend's default for Splitwise-linked rows
    /// (nil = let the backend decide by expense kind). The local row is removed on success.
    func delete(id: UUID, propagate: Bool? = nil) async throws {
        let output = try await client.delete_expense_expenses__expense_id__delete(
            path: .init(expense_id: id.uuidString),
            query: .init(propagate: propagate)
        )
        _ = try output.noContent
        if let existing = try context.fetch(
            FetchDescriptor<Expense>(predicate: #Predicate { $0.id == id })
        ).first {
            context.delete(existing)
            try context.save()
        }
    }

    /// Sets the caller's per-user budget overrides (include in spending / cash flow) on an expense and caches
    /// the response. Never propagates to Splitwise; never touches balances.
    func setFlags(id: UUID, includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil) async throws {
        let output = try await client.update_expense_override_expenses__expense_id__override_patch(
            path: .init(expense_id: id.uuidString),
            body: .json(.init(include_in_spending: includeInSpending, include_in_cash_flow: includeInCashFlow))
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    /// Sets the caller's per-user free-text note (blank to clear) via the override endpoint. Only `note` is
    /// sent, so the include-flag overrides are untouched; never propagates to Splitwise.
    func setNote(id: UUID, note: String) async throws {
        let output = try await client.update_expense_override_expenses__expense_id__override_patch(
            path: .init(expense_id: id.uuidString),
            body: .json(.init(note: note))
        )
        let ok = try output.ok
        try upsert([try ok.body.json])
    }

    /// Bulk-set the per-user note on many expenses at once (find-related bulk apply). Concurrent; a member the
    /// server no longer has (404) is skipped. One cache write. Never propagates to Splitwise.
    func setNotes(ids: [UUID], note: String) async throws {
        guard !ids.isEmpty else { return }
        let client = self.client
        let responses = try await withThrowingTaskGroup(
            of: Components.Schemas.ExpenseResponse?.self
        ) { group in
            for id in ids {
                group.addTask {
                    do {
                        let ok = try await client.update_expense_override_expenses__expense_id__override_patch(
                            path: .init(expense_id: id.uuidString),
                            body: .json(.init(note: note))).ok
                        return try ok.body.json
                    } catch BackendError.notFound {
                        return nil
                    }
                }
            }
            var out: [Components.Schemas.ExpenseResponse] = []
            for try await r in group { if let r { out.append(r) } }
            return out
        }
        try upsert(responses)
    }

    /// Fetches a single expense's full detail and upserts it.
    func refreshDetail(id: UUID) async throws {
        let output = try await client.get_expense_expenses__expense_id__get(
            .init(path: .init(expense_id: id.uuidString))
        )
        try upsert([try output.ok.body.json])
    }

    /// Full fetch that also deletes local expenses the server no longer has, so cached deletes (which
    /// `updated_since` doesn't report) are reconciled. Optionally group-scoped.
    func reconcileAll(groupId: UUID? = nil) async throws {
        let responses = try await client.list_expenses_expenses_get(query: .init(
            group_id: groupId?.uuidString, limit: 500
        )).ok.body.json
        try upsert(responses)
        let keep = Set(try responses.map { try Mapping.uuid($0.id, field: "Expense.id") })
        let predicate: Predicate<Expense> = groupId.map { gid in
            #Predicate { $0.groupId == gid }
        } ?? #Predicate { _ in true }
        for local in try context.fetch(FetchDescriptor<Expense>(predicate: predicate))
        where !keep.contains(local.id) {
            context.delete(local)
        }
        try context.save()
    }

    func upsert(_ responses: [Components.Schemas.ExpenseResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Expense.id")
            let mapped = try Mapping.expense(r)  // fresh, not yet inserted
            guard let existing = try context.fetch(
                FetchDescriptor<Expense>(predicate: #Predicate { $0.id == id })
            ).first else {
                context.insert(mapped)
                continue
            }
            // Update in place so the Expense (and its unchanged splits/items/receipts) keep their
            // identity - deleting + re-inserting invalidates objects live views still hold, which
            // crashes SwiftData ("access a full future backing data ... with nil").
            existing.groupId = mapped.groupId
            existing.transactionId = mapped.transactionId
            existing.splitwiseExpenseId = mapped.splitwiseExpenseId
            existing.details = mapped.details
            existing.amount = mapped.amount
            existing.currency = mapped.currency
            existing.date = mapped.date
            existing.category = mapped.category
            existing.createdByIdentifier = mapped.createdByIdentifier
            existing.updatedByIdentifier = mapped.updatedByIdentifier
            existing.splitwiseCreatedAt = mapped.splitwiseCreatedAt
            existing.splitwiseUpdatedAt = mapped.splitwiseUpdatedAt
            existing.notes = mapped.notes
            existing.commentsCount = mapped.commentsCount
            existing.repeats = mapped.repeats
            existing.repeatInterval = mapped.repeatInterval
            existing.expenseBundleId = mapped.expenseBundleId
            existing.splitwiseReceiptURL = mapped.splitwiseReceiptURL
            existing.splitwiseRepayments = mapped.splitwiseRepayments
            existing.includeInSpending = mapped.includeInSpending
            existing.includeInCashFlow = mapped.includeInCashFlow
            existing.note = mapped.note
            existing.createdAt = mapped.createdAt
            existing.updatedAt = mapped.updatedAt
            reconcileSplits(existing, mapped.splits)
            reconcileItems(existing, mapped.items)
            reconcileReceipts(existing, mapped.receipts)
        }
        try context.save()
    }

    /// Reconcile a to-many relationship by `id`: update matched children in place, insert new, delete removed.
    private func reconcileSplits(_ expense: Expense, _ incoming: [Split]) {
        var byId = Dictionary(expense.splits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Split] = []
        for new in incoming {
            if let current = byId.removeValue(forKey: new.id) {
                current.userIdentifier = new.userIdentifier
                current.paidShare = new.paidShare
                current.owedShare = new.owedShare
                result.append(current)
            } else {
                context.insert(new)
                result.append(new)
            }
        }
        for removed in byId.values { context.delete(removed) }
        expense.splits = result
    }

    private func reconcileItems(_ expense: Expense, _ incoming: [ExpenseItem]) {
        var byId = Dictionary(expense.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [ExpenseItem] = []
        for new in incoming {
            if let current = byId.removeValue(forKey: new.id) {
                current.name = new.name
                current.quantity = new.quantity
                current.price = new.price
                current.category = new.category
                result.append(current)
            } else {
                context.insert(new)
                result.append(new)
            }
        }
        for removed in byId.values { context.delete(removed) }
        expense.items = result
    }

    private func reconcileReceipts(_ expense: Expense, _ incoming: [Receipt]) {
        var byId = Dictionary(expense.receipts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Receipt] = []
        for new in incoming {
            if let current = byId.removeValue(forKey: new.id) {
                current.bucket = new.bucket
                current.objectKey = new.objectKey
                current.contentType = new.contentType
                result.append(current)
            } else {
                context.insert(new)
                result.append(new)
            }
        }
        for removed in byId.values { context.delete(removed) }
        expense.receipts = result
    }
}
