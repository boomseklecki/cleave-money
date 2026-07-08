import Foundation
import SwiftData

/// Reads accounts and transactions from the backend and reconciles them into SwiftData.
/// Plaid-sourced transactions dedupe on `plaidTransactionId`; upsert is keyed on `id`.
@MainActor
struct AccountRepository {
    let client: Client
    let context: ModelContext

    func refreshAccounts() async throws {
        let output = try await client.list_accounts_accounts_get()
        let responses = try output.ok.body.json
        // Cache only the caller's OWN accounts; partner-shared accounts (`shared_by_identifier != nil`) are
        // never persisted, so they can't leak into net-worth/analytics @Query results. The "Shared with you"
        // section live-fetches them separately (see `sharedInAccounts()`).
        let own = responses.filter { $0.shared_by_identifier == nil }
        try upsertAccounts(own)
        // The owned list is the full (per-caller-scoped) set, so prune any cached account the backend
        // no longer returns - plus the transactions belonging to those removed accounts - so another
        // user's data (or a now-hidden account) can't linger after sign-in/scoping. refreshTransactions is
        // paged and must NOT prune, so the transaction cleanup is anchored to account ownership here.
        let keep = Set(try own.map { try Mapping.uuid($0.id, field: "Account.id") })
        for account in try context.fetch(FetchDescriptor<Account>()) where !keep.contains(account.id) {
            context.delete(account)
        }
        for txn in try context.fetch(FetchDescriptor<Transaction>()) {
            if let aid = txn.accountId, !keep.contains(aid) { context.delete(txn) }
        }
        try context.save()
    }

    /// Partner-owned accounts shared *to* the caller (balances or full). Transient API objects - never
    /// cached, so they stay out of the owner-pure local analytics. Drives the "Shared with you" section.
    func sharedInAccounts() async throws -> [Components.Schemas.AccountResponse] {
        let responses = try await client.list_accounts_accounts_get().ok.body.json
        return responses.filter { $0.shared_by_identifier != nil }
    }

    /// Live, non-caching read of a (full-shared) account's transactions for the read-only shared drill-in.
    /// Deliberately does NOT upsert into SwiftData - shared transactions must never enter the local cache.
    func fetchTransactions(accountId: UUID, limit: Int = 200) async throws
        -> [Components.Schemas.TransactionResponse] {
        try await client.list_transactions_transactions_get(query: .init(
            account_id: accountId.uuidString, limit: limit, offset: 0)).ok.body.json
    }

    func refreshTransactions(
        accountId: UUID? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) async throws {
        let output = try await client.list_transactions_transactions_get(query: .init(
            account_id: accountId?.uuidString,
            since: since.map(Mapping.dateOnlyFormatter.string(from:)),
            until: until.map(Mapping.dateOnlyFormatter.string(from:)),
            limit: limit,
            offset: offset
        ))
        try upsertTransactions(try output.ok.body.json)
    }

    /// Re-fetches a single transaction (with its items + receipts) and upserts it - used after a receipt
    /// change, where the mutation response doesn't carry the full transaction.
    func refreshTransaction(id: UUID) async throws {
        let output = try await client.get_transaction_transactions__transaction_id__get(
            path: .init(transaction_id: id.uuidString))
        let ok = try output.ok
        try upsertTransactions([try ok.body.json])
    }

    /// Plaid drops a pending transaction when it posts (it returns a new posted row and lists the pending id in
    /// `removed`, which the backend deletes). Our transaction refresh is append-only, so that dead pending row
    /// lingers locally - a phantom in the account's Pending section that also double-counts in spending. Reap
    /// it: refetch a recent window (pending are always recent) and delete any LOCAL pending row the server no
    /// longer returns. Scoped to pending + the window so a truncated page can't take a posted row with it.
    func reapStalePending(accountId: UUID? = nil, lookbackDays: Int = 45) async throws {
        guard let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: .now) else { return }
        let responses = try await client.list_transactions_transactions_get(query: .init(
            account_id: accountId?.uuidString,
            since: Mapping.dateOnlyFormatter.string(from: since),
            limit: 500, offset: 0)).ok.body.json
        try upsertTransactions(responses)           // keep the window fresh while we're here
        guard responses.count < 500 else { return }  // full page = window truncated; not safe to prune
        let live = Set(try responses.map { try Mapping.uuid($0.id, field: "Transaction.id") })
        let cutoff = Calendar.current.startOfDay(for: since)
        let stale = try context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.pending && $0.date >= cutoff }))
        for txn in stale where !live.contains(txn.id) {
            if let accountId, txn.accountId != accountId { continue }
            context.delete(txn)
        }
        try context.save()
    }

    /// Creates a manual account (plaid_account_id null) and caches it. `type` is a Plaid subtype string that
    /// the app classifies into a kind (see `AccountKind.representativeSubtype`).
    @discardableResult
    func createAccount(name: String, type: String?, balance: Decimal, currency: String?) async throws -> UUID {
        let output = try await client.create_account_accounts_post(
            body: .json(Mapping.accountCreate(name: name, type: type, balance: balance, currency: currency)))
        let created = try output.created
        let response = try created.body.json
        try upsertAccounts([response])
        return try Mapping.uuid(response.id, field: "Account.id")
    }

    /// Deletes an account and all its data server-side (transactions + their items/overrides), then mirrors the
    /// hard-delete locally (the account + its cached transactions).
    func deleteAccount(id: UUID) async throws {
        let output = try await client.delete_account_accounts__account_id__delete(
            path: .init(account_id: id.uuidString))
        _ = try output.noContent
        for txn in try context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.accountId == id })) { context.delete(txn) }
        if let account = try context.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })).first {
            context.delete(account)
        }
        try context.save()
    }

    /// Creates a manual transaction (source=manual) and caches it. `idempotencyKey` (a UUID the view mints
    /// once per create form) is sent as the `Idempotency-Key` header so a retry of the same create collapses
    /// to one row server-side instead of a duplicate (see `IdempotencyMiddleware`). Manual transactions never
    /// push to Splitwise, so there is no residual window.
    @discardableResult
    func createTransaction(_ draft: TransactionDraft, idempotencyKey: String? = nil) async throws -> UUID {
        let output = try await IdempotencyContext.$key.withValue(idempotencyKey) {
            try await client.create_transaction_transactions_post(
                body: .json(Mapping.transactionCreate(draft))
            )
        }
        let created = try output.created
        let response = try created.body.json
        try upsertTransactions([response])
        return try Mapping.uuid(response.id, field: "Transaction.id")
    }

    /// Sets (or clears, with nil) the per-transaction category override and caches the response.
    func setCategoryOverride(id: UUID, category: String?) async throws {
        let output = try await client.update_transaction_transactions__transaction_id__patch(
            path: .init(transaction_id: id.uuidString),
            body: .json(.init(category_override: category))
        )
        let ok = try output.ok
        try upsertTransactions([try ok.body.json])
    }

    /// Applies the same category override to many transactions at once (bulk recategorize from the Inbox,
    /// Find Related, or a subscription). The PATCHes run **concurrently** and every response is cached in a
    /// **single** save - so a card covering dozens of rows doesn't fan out into N sequential round-trips and N
    /// store writes (each of which re-runs every `@Query`, which is what made the Inbox jank after a bulk accept).
    /// A transaction the server no longer has (404 - e.g. a pending row that posted & was reaped) is **skipped**
    /// so one stale member can't fail the whole batch; the rest still apply. (The single-id overload keeps
    /// throwing `.notFound` - `TransactionDetailView` uses it to raise the "already posted" prompt.)
    func setCategoryOverride(ids: [UUID], category: String?) async throws {
        guard !ids.isEmpty else { return }
        let client = self.client
        let responses = try await withThrowingTaskGroup(
            of: Components.Schemas.TransactionResponse?.self
        ) { group in
            for id in ids {
                group.addTask {
                    do {
                        let ok = try await client.update_transaction_transactions__transaction_id__patch(
                            path: .init(transaction_id: id.uuidString),
                            body: .json(.init(category_override: category))).ok
                        return try ok.body.json
                    } catch BackendError.notFound {
                        return nil  // transaction gone (pending posted & reaped) - skip, apply to the rest
                    }
                }
            }
            var out: [Components.Schemas.TransactionResponse] = []
            for try await r in group { if let r { out.append(r) } }
            return out
        }
        try upsertTransactions(responses)
    }

    /// Sets the per-transaction budget overrides (include in spending / cash flow) and caches the response.
    func setTransactionFlags(id: UUID, includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil) async throws {
        let output = try await client.update_transaction_override_transactions__transaction_id__override_patch(
            path: .init(transaction_id: id.uuidString),
            body: .json(.init(include_in_spending: includeInSpending, include_in_cash_flow: includeInCashFlow))
        )
        let ok = try output.ok
        try upsertTransactions([try ok.body.json])
    }

    /// Sets the caller's per-user free-text note (blank to clear) via the override endpoint, and caches the
    /// response. Only `note` is sent, so it never disturbs the include-flag/category overrides.
    func setTransactionNote(id: UUID, note: String) async throws {
        let output = try await client.update_transaction_override_transactions__transaction_id__override_patch(
            path: .init(transaction_id: id.uuidString),
            body: .json(.init(note: note))
        )
        let ok = try output.ok
        try upsertTransactions([try ok.body.json])
    }

    /// Bulk-set the per-user note on many transactions at once (find-related bulk apply). Concurrent; a member
    /// the server no longer has (404) is skipped so one stale row can't fail the whole batch. One cache write.
    func setTransactionNotes(ids: [UUID], note: String) async throws {
        guard !ids.isEmpty else { return }
        let client = self.client
        let responses = try await withThrowingTaskGroup(
            of: Components.Schemas.TransactionResponse?.self
        ) { group in
            for id in ids {
                group.addTask {
                    do {
                        let ok = try await client.update_transaction_override_transactions__transaction_id__override_patch(
                            path: .init(transaction_id: id.uuidString),
                            body: .json(.init(note: note))).ok
                        return try ok.body.json
                    } catch BackendError.notFound {
                        return nil  // transaction gone (pending posted & reaped) - skip, apply to the rest
                    }
                }
            }
            var out: [Components.Schemas.TransactionResponse] = []
            for try await r in group { if let r { out.append(r) } }
            return out
        }
        try upsertTransactions(responses)
    }

    /// Replaces a transaction's line items (receipt itemization) and caches the response.
    func setItems(id: UUID, items: [ItemDraft]) async throws {
        let output = try await client.set_transaction_items_transactions__transaction_id__items_put(
            path: .init(transaction_id: id.uuidString),
            body: .json(items.map(Mapping.transactionItemInput))
        )
        let ok = try output.ok
        try upsertTransactions([try ok.body.json])
    }

    /// Updates per-account overrides (any subset; a nil argument leaves that field unchanged server-side,
    /// matching the backend's exclude_unset semantics) and caches the response. Pass an empty
    /// `displayName` to reset the name back to the Plaid value.
    func update(id: UUID, displayName: String? = nil, kind: String? = nil,
                includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil,
                shareLevel: String? = nil) async throws {
        let output = try await client.update_account_accounts__account_id__patch(
            path: .init(account_id: id.uuidString),
            body: .json(Mapping.accountUpdate(
                displayName: displayName, kind: kind,
                includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow,
                shareLevel: shareLevel))
        )
        let ok = try output.ok
        try upsertAccounts([try ok.body.json])
    }

    /// Sets just the Goals-analytics inclusion overrides (thin wrapper over `update`).
    func updateFlags(id: UUID, includeInSpending: Bool?, includeInCashFlow: Bool?) async throws {
        try await update(id: id, includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow)
    }

    func upsertAccounts(_ responses: [Components.Schemas.AccountResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Account.id")
            if let existing = try context.fetch(
                FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
            ).first {
                existing.name = r.name
                existing.displayName = r.display_name
                existing.type = r._type
                existing.kindOverride = r.kind
                existing.mask = r.mask
                existing.plaidAccountId = r.plaid_account_id
                existing.balance = try Mapping.decimal(r.balance, field: "Account.balance")
                existing.availableBalance = r.available_balance.flatMap {
                    try? Mapping.decimal($0, field: "Account.available_balance") }
                existing.currency = r.currency
                existing.includeInSpending = r.include_in_spending
                existing.includeInCashFlow = r.include_in_cash_flow
                existing.institutionName = r.institution_name
                existing.institutionDomain = r.institution_domain
                existing.institutionColor = r.institution_color
                existing.institutionStatus = r.institution_status
                existing.shareLevel = r.share_level
                existing.createdAt = r.created_at
                existing.updatedAt = r.updated_at
            } else {
                context.insert(try Mapping.account(r))
            }
        }
        try context.save()
    }

    func upsertTransactions(_ responses: [Components.Schemas.TransactionResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Transaction.id")
            let transaction: Transaction
            if let existing = try context.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })
            ).first {
                existing.accountId = try Mapping.optionalUUID(r.account_id, field: "Transaction.account_id")
                existing.plaidTransactionId = r.plaid_transaction_id
                existing.pendingTransactionId = r.pending_transaction_id
                existing.source = Mapping.transactionSource(r.source)
                existing.details = r.description
                existing.amount = try Mapping.decimal(r.amount, field: "Transaction.amount")
                existing.currency = r.currency
                existing.date = try Mapping.dateOnly(r.date, field: "Transaction.date")
                existing.category = r.category
                existing.categoryOverride = r.category_override
                existing.includeInSpending = r.include_in_spending
                existing.includeInCashFlow = r.include_in_cash_flow
                existing.note = r.note
                existing.linkedExpenseId = try Mapping.optionalUUID(r.linked_expense_id,
                                                                    field: "Transaction.linked_expense_id")
                // Refined is device-derived but now mirrored server-side: adopt the server's value when it
                // has one, else keep any local value (this device may have computed it and not pushed yet) - 
                // never clobber a non-nil local refinement to nil on a plain re-sync.
                if let refined = r.refined_category, !refined.isEmpty { existing.refinedCategory = refined }
                existing.pending = r.pending
                existing.createdAt = r.created_at
                existing.updatedAt = r.updated_at
                transaction = existing
            } else {
                let new = try Mapping.transaction(r)
                if let refined = r.refined_category, !refined.isEmpty { new.refinedCategory = refined }
                context.insert(new)
                transaction = new
            }
            try reconcileItems(transaction, r.items ?? [])
            try reconcileReceipts(transaction, r.receipts ?? [])
        }
        try context.save()
    }

    /// Mirrors the on-device AI refinement to the backend (provenance .aiRefined → "AI" badge) so other devices
    /// inherit it. Best-effort and **concurrent + single-save** like `setCategoryOverride(ids:)`: a card's worth
    /// of newly refined rows push in parallel and cache in one write. A transaction the server no longer has
    /// (404) is skipped. Outranks the built-in map but not an explicit override (see `CategoryMapping.resolve`).
    func setRefinedCategory(_ entries: [(id: UUID, refined: String)]) async throws {
        guard !entries.isEmpty else { return }
        let client = self.client
        let responses = try await withThrowingTaskGroup(
            of: Components.Schemas.TransactionResponse?.self
        ) { group in
            for entry in entries {
                group.addTask {
                    do {
                        let ok = try await client
                            .update_transaction_override_transactions__transaction_id__override_patch(
                                path: .init(transaction_id: entry.id.uuidString),
                                body: .json(.init(refined_category: entry.refined))).ok
                        return try ok.body.json
                    } catch BackendError.notFound {
                        return nil  // gone (pending posted & reaped) - skip
                    }
                }
            }
            var out: [Components.Schemas.TransactionResponse] = []
            for try await r in group { if let r { out.append(r) } }
            return out
        }
        try upsertTransactions(responses)
    }

    /// Set the AI refinement on a single transaction (the manual "Categorize with Apple Intelligence" button).
    func setRefinedCategory(id: UUID, category: String) async throws {
        try await setRefinedCategory([(id: id, refined: category)])
    }

    /// "Reset to Automatic": clear both the AI refinement and the manual override so the row falls back to the
    /// deterministic/map resolution. Best-effort + iOS-first - the caller optimistically nils both locally; the
    /// server clear of `refinedCategory` is best-effort (an empty string transmits and is treated as cleared,
    /// since `upsertTransactions` only adopts a non-empty server value). Refined is cleared **before** the
    /// override so the override PATCH's response upsert doesn't re-adopt a still-set refined value.
    func resetCategory(id: UUID) async throws {
        _ = try? await client.update_transaction_override_transactions__transaction_id__override_patch(
            path: .init(transaction_id: id.uuidString), body: .json(.init(refined_category: "")))
        try await setCategoryOverride(id: id, category: nil)
    }

    /// One-time push of every locally-computed refinement to the backend, so a user who refined before this
    /// feature existed seeds the server (and thus their other devices). Gated by a UserDefaults flag; runs once
    /// per device. Best-effort - a failure leaves the flag unset so it retries next launch.
    func backfillRefinedCategories() async {
        let flag = "categories.refinedBackfilled"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let local = (try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.refinedCategory != nil }))) ?? []
        let entries = local.compactMap { t in t.refinedCategory.map { (id: t.id, refined: $0) } }
        do {
            try await setRefinedCategory(entries)
            UserDefaults.standard.set(true, forKey: flag)
        } catch { /* leave the flag unset; retry next launch */ }
    }

    /// Upserts a transaction's line items by id (preserving object identity for unchanged rows), inserting
    /// new ones and deleting any the server dropped. Mirrors `ExpenseRepository.reconcileItems`.
    private func reconcileItems(_ transaction: Transaction,
                                _ incoming: [Components.Schemas.TransactionItemResponse]) throws {
        var byId = Dictionary(transaction.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [TransactionItem] = []
        for r in incoming {
            let mapped = try Mapping.transactionItem(r)
            if let current = byId.removeValue(forKey: mapped.id) {
                current.name = mapped.name
                current.quantity = mapped.quantity
                current.price = mapped.price
                current.category = mapped.category
                current.editedBy = mapped.editedBy
                current.editedOn = mapped.editedOn
                result.append(current)
            } else {
                context.insert(mapped)
                result.append(mapped)
            }
        }
        for removed in byId.values { context.delete(removed) }
        transaction.items = result
    }

    /// Reconciles a transaction's receipts against the server response - updating existing rows, inserting new
    /// ones and deleting any the server dropped. Mirrors `ExpenseRepository.reconcileReceipts`.
    private func reconcileReceipts(_ transaction: Transaction,
                                   _ incoming: [Components.Schemas.ReceiptResponse]) throws {
        var byId = Dictionary(transaction.receipts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Receipt] = []
        for r in incoming {
            let mapped = try Mapping.receipt(r)
            if let current = byId.removeValue(forKey: mapped.id) {
                current.bucket = mapped.bucket
                current.objectKey = mapped.objectKey
                current.contentType = mapped.contentType
                result.append(current)
            } else {
                context.insert(mapped)
                result.append(mapped)
            }
        }
        for removed in byId.values { context.delete(removed) }
        transaction.receipts = result
    }
}
