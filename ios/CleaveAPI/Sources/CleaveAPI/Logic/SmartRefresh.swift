import Foundation
import SwiftData

/// Pull-to-refresh staleness thresholds (minutes), loaded from server settings. A live provider sync fires
/// only when the in-scope data is staler than that provider's threshold; 0 = always sync. Split by provider
/// (not by screen) because Plaid calls cost money while Splitwise is free; the *scope* of a pull comes from
/// the freshness signal each screen passes, not from the threshold.
public struct RefreshThresholds {
    var plaid: Int
    var splitwise: Int

    public init(plaid: Int = 60, splitwise: Int = 15) {
        self.plaid = plaid; self.splitwise = splitwise
    }

    func minutes(for source: AppEnvironment.RefreshSource) -> Int {
        switch source {
        case .bank: return plaid
        case .splitwise: return splitwise
        case .none: return 0  // unused - a .none source never live-syncs
        }
    }
}

@MainActor
extension AppEnvironment {
    /// The external source a scope can live-sync from (also selects which freshness threshold applies).
    public enum RefreshSource { case bank, splitwise, none }
    /// Which slice of Splitwise a live sync pulls. Drill-in scopes hit the narrow endpoints (one group /
    /// friend / expense) so a detail pull doesn't re-fetch the whole account; `.all` is the list-level
    /// token-wide sync. Associated values: Splitwise group id / local friend identifier / Splitwise expense id.
    public enum SplitwiseScope: Sendable { case all, group(String), friend(String), expense(String) }

    /// The one pull-to-refresh path. Decides - from the in-scope `freshness` (an entity's `updatedAt`, which
    /// equals its last sync time) vs the provider's server-set threshold - whether to do a **live** provider
    /// sync then reconcile, or just **reconcile** the backend cache. Drives the status banner. `reconcile` is
    /// the screen's local re-fetch (used in the reconcile-only path and after a Splitwise live sync).
    func smartRefresh(
        source rawSource: RefreshSource,
        freshness: Date?,
        plaidItemId: UUID? = nil,
        splitwiseScope: SplitwiseScope = .all,
        context: ModelContext,
        reconcile: () async throws -> Void
    ) async {
        // A Splitwise scope falls back to reconcile-only when Splitwise isn't connected.
        let source: RefreshSource = (rawSource == .splitwise && !splitwiseConnected) ? .none : rawSource
        let threshold = refreshThresholds.minutes(for: source)
        let stale = freshness == nil || threshold <= 0
            || Date().timeIntervalSince(freshness!) >= Double(threshold) * 60
        do {
            if source != .none && stale {
                showSyncStatus(source == .bank ? "Syncing with your bank…" : "Syncing with Splitwise…",
                               autoDismiss: false)
                let reconciledByLiveSync = try await liveSync(
                    source, plaidItemId: plaidItemId, splitwiseScope: splitwiseScope, context: context)
                if !reconciledByLiveSync { try await reconcile() }
                showSyncStatus("Updated just now", autoDismiss: true)
            } else {
                try await reconcile()
                showSyncStatus(source == .none ? "Refreshed" : "Already up to date", autoDismiss: true)
            }
        } catch {
            showSyncStatus("Couldn't refresh — pull to try again.", autoDismiss: true)
        }
    }

    /// Runs the live provider sync. Returns true if it already reconciled the local cache (Plaid sync does;
    /// the Splitwise syncs are server-side only, so the caller still reconciles).
    private func liveSync(
        _ source: RefreshSource, plaidItemId: UUID?, splitwiseScope: SplitwiseScope, context: ModelContext
    ) async throws -> Bool {
        switch source {
        case .bank:
            try await plaid(context).sync(itemId: plaidItemId)  // nil = all banks; also refreshes the cache
            // On an all-banks pull, also sync SimpleFIN. The backend gates it on its own 12h/quota window, so
            // this is a cheap no-op when fresh; best-effort so a SimpleFIN hiccup can't fail the bank refresh.
            // Skipped on a single-item drill-in (plaidItemId set), which targets one Plaid item.
            if plaidItemId == nil {
                _ = try? await simplefin(context).sync()
            }
            return true
        case .splitwise:
            // Scoped or token-wide; best-effort so one failing path doesn't abort the others. The drill-in
            // scopes deliberately don't advance the server-side cursor (the backend leaves it untouched).
            switch splitwiseScope {
            case .all:
                _ = try? await splitwise.syncExpenses()
                try? await splitwise.syncGroups()
                try? await splitwise.syncUsers()
            case let .group(swGroupId):
                try? await splitwise.syncGroup(swGroupId)
            case let .friend(identifier):
                try? await splitwise.syncFriend(identifier)
            case let .expense(swExpenseId):
                try? await splitwise.syncExpense(swExpenseId)
            }
            return false
        case .none:
            return false
        }
    }
}
