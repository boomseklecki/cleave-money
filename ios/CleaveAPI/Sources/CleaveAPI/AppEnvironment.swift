import Foundation
import SwiftData
import Observation
import UIKit
import UserNotifications

/// Shared app-wide services: one configured API `Client` plus repository/service factories and the
/// bearer-token state. Created by the app shell and injected into the SwiftUI environment.
/// The auth middleware reads the Keychain token per request, so token changes take effect at once.
@MainActor
@Observable
public final class AppEnvironment {
    @ObservationIgnored private(set) var client: Client
    /// A long-timeout client for slow operations (the Splitwise cold-backfill import + syncs), which can
    /// run for minutes and otherwise hit NSURLErrorTimedOut on the default 60s request timeout.
    @ObservationIgnored private(set) var slowClient: Client
    @ObservationIgnored private var tokenStore: KeychainTokenStore

    /// Whether a bearer token is stored (drives Settings UI). The backend is default-open without one.
    public private(set) var hasToken: Bool
    /// Current base URL string (drives Settings UI).
    public private(set) var baseURLString: String
    /// The signed-in user's profile from `GET /me` (nil in open mode / not signed in). Source of truth
    /// for "you" - no hardcoded identity.
    public private(set) var currentUser: CurrentUser?
    /// Whether a Splitwise token is connected. Gates the scoped sync endpoints (which 400 without one)
    /// so non-Splitwise instances don't call them on every pull-to-refresh.
    public private(set) var splitwiseConnected = false
    /// Whether the configured backend requires sign-in (from the unguarded `GET /server-info`). Nil
    /// until first loaded / when server-info is unreachable; drives the launch gate.
    public private(set) var serverRequiresAuth: Bool?
    /// Sign-in providers the backend offers (e.g. ["apple","google","splitwise"]); filters the gate.
    public private(set) var authProviders: [String] = []
    /// Whether the last `/server-info` probe reached a Cleave backend. Nil before the first probe;
    /// false means the configured URL is wrong/unreachable (drives the gate's connectivity hint).
    public private(set) var serverReachable: Bool?
    /// The backend's friendly name from `/server-info` (e.g. "Alice's Household"); used as the join link label.
    public private(set) var serverName: String?
    /// Whether the configured backend is a public DEMO instance (guest login + sample data). Drives the
    /// gate's "Start Demo" path and the persistent "sample data" banner.
    public private(set) var serverIsDemo = false
    /// Whether the backend has a push relay configured. Drives showing the push-notification controls in
    /// Server Settings (only on a prod, non-demo server that can actually push).
    public private(set) var serverHasPush = false
    /// Which "connect a bank" methods the backend offers (from /server-info). Plaid needs API creds;
    /// SimpleFIN is admin-toggled. Statement import + manual account are always available.
    public private(set) var serverPlaidConfigured = false
    public private(set) var serverPlaidEnabled = true   // admin can stop offering NEW Plaid links (default on)
    public private(set) var serverSimpleFinEnabled = false
    /// Inbox badge count: actionable suggestions + unread activity. Drives the Inbox tab badge.
    public private(set) var inboxBadge = 0
    /// A single-use enrollment invite captured from a join link, applied to the next sign-in (then cleared).
    /// Persisted so it survives the install→open hop; drives the gate's "you have an invite" hint.
    public private(set) var pendingInvite: String?

    /// Transient status shown by the top banner during/after a smart refresh ("Syncing with your bank...",
    /// "Already up to date"). Set by `smartRefresh` (see SmartRefresh.swift). Nil = no banner.
    public private(set) var syncStatus: String?
    @ObservationIgnored private var statusToken = UUID()
    /// Pull-to-refresh staleness thresholds (minutes), loaded from server settings; defaults until loaded.
    @ObservationIgnored var refreshThresholds = RefreshThresholds()

    private static let pendingInviteKey = "pending_invite"

    /// Shows the sync banner. `autoDismiss` clears it after a beat (for terminal messages); the in-progress
    /// "Syncing..." message stays until replaced by the terminal one.
    func showSyncStatus(_ text: String?, autoDismiss: Bool) {
        syncStatus = text
        let token = UUID()
        statusToken = token
        guard autoDismiss, text != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if statusToken == token { syncStatus = nil }
        }
    }

    /// Loads the pull-to-refresh staleness thresholds from server settings (best-effort; keeps defaults on
    /// failure). Readable by any enrolled member.
    func loadRefreshThresholds() async {
        guard let s = try? await serverSettings.get() else { return }
        refreshThresholds = RefreshThresholds(
            plaid: s.refresh_plaid_stale_minutes, splitwise: s.refresh_splitwise_stale_minutes)
    }

    public init() {
        let store = KeychainTokenStore.forServer(APIConfig.baseURL)
        KeychainTokenStore.migrateLegacyTokenIfNeeded(into: store)  // carry an existing session over once
        self.tokenStore = store
        self.client = APIClientFactory.makeClient(tokenStore: store)
        self.slowClient = APIClientFactory.makeClient(tokenStore: store, requestTimeout: 300)
        self.hasToken = (store.load()?.isEmpty == false)
        self.baseURLString = APIConfig.baseURL.absoluteString
        self.pendingInvite = UserDefaults.standard.string(forKey: Self.pendingInviteKey)
        // Mirror the current session into the App Group every launch so the Share Extension has it even for an
        // already-signed-in user (setToken/setBaseURL only fire on a change).
        SharedImportConfig.update(baseURL: self.baseURLString, token: store.load())
    }

    /// Stores (or clears) the pending enrollment invite, persisted across launches.
    func setPendingInvite(_ code: String?) {
        pendingInvite = (code?.isEmpty == false) ? code : nil
        if let pendingInvite {
            UserDefaults.standard.set(pendingInvite, forKey: Self.pendingInviteKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pendingInviteKey)
        }
    }

    /// Handles an inbound join link: adopts its backend URL and captures any single-use invite for the next
    /// sign-in. Switching to a different backend wipes the local cache + signs out (prod/dev don't intermingle).
    /// Returns true if the URL was a join link (so the caller stops other handlers).
    @discardableResult
    func adoptJoinLink(_ url: URL, context: ModelContext) -> Bool {
        guard let parsed = JoinLink.parse(url) else { return false }
        if parsed.api != baseURLString {
            eraseLocalCache(context)   // drop the old server's data; setBaseURL swaps to the new server's token
            setBaseURL(parsed.api)
        }
        setPendingInvite(parsed.invite)
        Task { await loadServerInfo() }
        return true
    }

    func setToken(_ token: String?) {
        tokenStore.save(token)
        hasToken = (token?.isEmpty == false)
        SharedImportConfig.update(baseURL: baseURLString, token: token)  // mirror for the Share Extension
    }

    /// Refreshes the signed-in profile from `GET /me`. A definitive 401 means the stored token is
    /// invalid/expired → sign out so it isn't resent and the launch gate re-shows. Transient/offline
    /// failures leave the prior state (so a network blip doesn't lock a signed-in user out).
    func refreshCurrentUser(_ context: ModelContext) async {
        do {
            currentUser = try await users(context).currentUser()
        } catch BackendError.http(401) {
            signOut(context)
        } catch {
            // transient/offline - keep the prior currentUser
        }
    }

    /// Loads the backend's auth requirement + providers from the unguarded `GET /server-info`, and
    /// records whether the configured URL actually reached a Cleave backend.
    func loadServerInfo() async {
        do {
            let info = try await client.server_info_server_info_get().ok.body.json
            serverRequiresAuth = info.requires_auth
            authProviders = info.auth_providers
            serverName = info.name
            serverIsDemo = info.demo ?? false
            serverHasPush = info.push_configured ?? false
            serverPlaidConfigured = info.plaid_configured ?? false
            serverPlaidEnabled = info.plaid_enabled ?? true
            serverSimpleFinEnabled = info.simplefin_enabled ?? false
            serverReachable = true
        } catch {
            serverReachable = false  // wrong URL / unreachable / not a Cleave backend
        }
    }

    /// Refreshes whether Splitwise is connected (best-effort; leaves the prior value on failure).
    func refreshSplitwiseStatus() async {
        if let connected = try? await splitwise.status().connected {
            splitwiseConnected = connected
        }
    }

    /// Applies a session token issued after a provider sign-in, then loads the profile.
    func applySession(token: String, context: ModelContext) async {
        setToken(token)
        await refreshCurrentUser(context)
    }

    /// Clears the session token and profile (sign out) AND wipes the local SwiftData cache, so the previous
    /// account's data can't linger for the next sign-in - otherwise the on-device Inbox briefly renders the
    /// prior account's suggestions/nudges (e.g. a Splitwise settle-up card) until the new account syncs.
    /// Also unregisters this device's push token.
    func signOut(_ context: ModelContext) {
        if let token = deviceToken {
            Task { try? await devices.unregister(token: token) }
        }
        eraseLocalCache(context)
        setToken(nil)
        currentUser = nil
        // Reset per-account in-memory UI state so it can't flash for the next account (e.g. a stale Inbox
        // badge / settle-up nudge). Server-level state (serverName/authProviders/...) stays - it's per-backend.
        splitwiseConnected = false
        inboxBadge = 0
    }

    /// Changes the backend base URL (persisted) and rebuilds the clients against that server's own token
    /// store - so switching loads the new backend's session (re-auth only the first time per server), and a
    /// token is never sent to a server that didn't mint it.
    func setBaseURL(_ string: String?) {
        APIConfig.setOverride(string)
        baseURLString = APIConfig.baseURL.absoluteString
        tokenStore = KeychainTokenStore.forServer(APIConfig.baseURL)
        client = APIClientFactory.makeClient(baseURL: APIConfig.baseURL, tokenStore: tokenStore)
        slowClient = APIClientFactory.makeClient(baseURL: APIConfig.baseURL, tokenStore: tokenStore,
                                                 requestTimeout: 300)
        hasToken = (tokenStore.load()?.isEmpty == false)
        SharedImportConfig.update(baseURL: baseURLString, token: tokenStore.load())  // mirror new server+token
    }

    /// Drops ALL local per-account state - the SwiftData cache AND the UserDefaults-backed preference caches
    /// with their sync watermarks - WITHOUT signing out. Used when switching backends (so prod/dev data don't
    /// intermingle) and by `signOut`. Resetting the watermarks is essential: without it `applyIfNewer` would
    /// treat the wiped device as already up to date and skip re-restoring the now-current owner's blobs
    /// (so subscription rules / categories / etc. would silently vanish).
    func eraseLocalCache(_ context: ModelContext) {
        try? CleaveStore.eraseAll(context)
        PreferenceSyncGate.reset()      // block pref pushes until the next launch restore re-runs (no clobber)
        SuggestionSync.reset()          // subscription rules / split templates / dismissals (rows wiped above)
        CategorySync.reset()            // categories / maps (rows wiped above)
        LinkSensitivitySync.reset()
        OrderPreference.tabs.reset()
        OrderPreference.goals.reset()
        BrandGuessCache.shared.reset()
        MerchantPreferences.shared.reset()
        NotificationPrefs.shared.reset()
    }

    /// Wipes the local SwiftData cache and signs out (clears the current server's token) - used on account
    /// deletion. (`signOut` already erases the cache; kept as a named alias for the deletion call site.)
    func wipeLocalData(_ context: ModelContext) {
        signOut(context)
    }

    // Repository/service factories (constructed per-use with the view's ModelContext).
    func groups(_ context: ModelContext) -> GroupRepository { .init(client: client, context: context) }
    func expenses(_ context: ModelContext) -> ExpenseRepository { .init(client: client, context: context) }
    func users(_ context: ModelContext) -> UserRepository { .init(client: client, context: context) }
    func receipts(_ context: ModelContext) -> ReceiptRepository { .init(client: client, context: context) }
    func accounts(_ context: ModelContext) -> AccountRepository { .init(client: client, context: context) }
    func goals(_ context: ModelContext) -> GoalRepository { .init(client: client, context: context) }
    /// Shared memo cache for the Inbox's subscription analysis (one instance, reused across every built service).
    let suggestionAnalysisCache = SuggestionAnalysisCache()
    func suggestions(_ context: ModelContext) -> SuggestionService {
        .init(client: client, context: context, me: currentUser?.identifier, analysisCache: suggestionAnalysisCache)
    }
    func categoryMaps(_ context: ModelContext) -> CategoryMapRepository { .init(client: client, context: context) }
    func plaid(_ context: ModelContext) -> PlaidRepository { .init(client: client, context: context) }
    func plaidSlow(_ context: ModelContext) -> PlaidRepository { .init(client: slowClient, context: context) }  // exchange auto-syncs the new bank, which can backfill many months
    func simplefin(_ context: ModelContext) -> SimpleFinRepository { .init(client: client, context: context) }
    func simplefinSlow(_ context: ModelContext) -> SimpleFinRepository { .init(client: slowClient, context: context) }  // connect backfills ~24 months

    /// Fire-and-forget: pre-warm a Plaid link token so the next "Link Bank" tap opens Plaid Link without the
    /// token round-trip. No-op without a signed-in user; best-effort (never blocks, never surfaces errors).
    func prewarmPlaidLinkToken(_ context: ModelContext) {
        guard serverPlaidConfigured, serverPlaidEnabled else { return }  // don't warm a token Plaid won't accept
        guard let me = currentUser?.identifier else { return }
        Task { await PlaidLinkTokenCache.shared.prewarm(for: me) {
            try await self.plaid(context).linkToken(userIdentifier: me)
        } }
    }
    func balances(_ context: ModelContext) -> BalanceRepository { .init(client: client, context: context) }
    func categories(_ context: ModelContext) -> CategoryRepository { .init(client: client, context: context) }
    var splitwise: SplitwiseService { .init(client: slowClient) }  // slow client: the cold-backfill import can run minutes
    var backups: BackupsRepository { .init(client: slowClient) }   // slow client: pg_dump/restore + receipts can run minutes
    var invites: InviteRepository { .init(client: client) }
    var connections: ConnectionRepository { .init(client: client) }
    var notifications: NotificationRepository { .init(client: client) }
    var notificationPrefs: NotificationPrefsRepository { .init(client: client) }
    var institutions: InstitutionRepository { .init(client: client) }
    var devices: DeviceRepository { .init(client: client) }
    func statements(_ context: ModelContext) -> StatementRepository { .init(client: client, context: context) }

    /// The APNs token last handed to us, so we can unregister it on sign-out.
    @ObservationIgnored private var deviceToken: String?

    /// Requests push authorization and registers for remote notifications (call after sign-in). When the
    /// token arrives (via `PushTokenStore`) it's forwarded to `POST /devices`.
    func requestPushAuthorization() {
        PushTokenStore.shared.onToken = { [weak self] token in self?.forwardDeviceToken(token) }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound])
            UIApplication.shared.registerForRemoteNotifications()
            if let token = PushTokenStore.shared.token { forwardDeviceToken(token) }  // already registered
        }
    }

    /// Sends the device token to the backend once we have both a token and a signed-in user, along with this
    /// device's E2E public key so the backend can seal pushes (relay stays blind to content).
    private func forwardDeviceToken(_ token: String) {
        deviceToken = token
        guard currentUser != nil else { return }
        let publicKey = PushKeychain.shared.publicKeyBase64()
        Task { try? await devices.register(token: token, publicKey: publicKey) }
    }

    /// Sets the inbox badge directly (the Inbox view computes it from what it already loaded).
    func setInboxBadge(_ count: Int) { inboxBadge = count }

    /// Recomputes the inbox badge (actionable suggestions + unread activity). Best-effort; used at launch and
    /// after refreshes so the badge is current before the user opens the tab.
    func refreshInboxBadge(_ context: ModelContext) async {
        let suggestions = (try? await suggestions(context).current().count) ?? 0
        let unread = (try? await notifications.list().filter {
            !$0.read && !NotificationPrefs.shared.isHidden(type: $0._type, source: $0.source)
        }.count) ?? 0
        inboxBadge = suggestions + unread
    }
    var serverSettings: ServerSettingsRepository { .init(client: client) }
    var brandOverrides: BrandOverridesRepository { .init(client: client) }
    func auth(_ context: ModelContext) -> AuthService { .init(client: client, context: context) }

    /// On-launch / pull-to-refresh: reconcile the cacheable collections (handles server-side deletes).
    /// Categories are local-authoritative now (see `bootstrapPreferences`), so they're not reconciled here.
    func refreshAll(_ context: ModelContext) async throws {
        try await groups(context).reconcileAll()
        try await users(context).refresh()
        try await expenses(context).reconcileAll()
        try await goals(context).refresh()
    }

    /// On launch: ensure built-in categories exist, then restore per-user state that's newer than what this
    /// device last applied - a new phone gets it back. Categories come from the relational `/categories` store;
    /// the remaining settings (suggestions, tab/goals order, link sensitivity) ride the preferences blobs (one
    /// `fetchAll` serves them). Apply-if-newer never clobbers a device that's ahead.
    func bootstrapPreferences(_ context: ModelContext) async {
        CategorySeed.ensureBuiltins(context)
        let rows = await Preferences.fetchAll(client)
        let categoryConfig = try? await client.get_categories_categories_get().ok.body.json
        CategorySync.applyIfNewer(config: categoryConfig, context: context)
        SuggestionSync.applyIfNewer(from: rows, context: context)
        OrderPreference.tabs.applyIfNewer(from: rows)
        OrderPreference.goals.applyIfNewer(from: rows)
        LinkSensitivitySync.applyIfNewer(from: rows)
        BrandGuessCache.shared.applyIfNewer(from: rows)     // per-user on-device brand guesses (cross-device)
        MerchantPreferences.shared.applyIfNewer(from: rows) // per-user explicit brand/note overrides
        if let tokens = try? await notificationPrefs.fetch() { NotificationPrefs.shared.apply(tokens) }
        PreferenceSyncGate.markRestored()  // restore sweep done -> pref pushes are now safe (can't clobber the server)
        await BrandCatalogStore.shared.load(client)  // server-managed merchant→logo catalog (falls back to built-ins)
        await accounts(context).backfillRefinedCategories()  // one-time: seed server from local refinements
    }

    /// Back up this session's new on-device brand guesses + explicit brand/note preferences to the per-owner
    /// preferences blobs. Called at app-background (a natural checkpoint); both are dirty-gated, so a no-op when
    /// nothing changed.
    func flushBrandGuesses() async {
        await BrandGuessCache.shared.pushBestEffort(client: client)
        await MerchantPreferences.shared.pushBestEffort(client: client)
    }

    /// Manual "Sync now" from Categories settings: restore a newer backup, else back up local.
    func syncCategoriesNow(_ context: ModelContext) async {
        await CategorySync.syncNow(context, client: client)
    }

    /// Manual "Sync now" from Merchant Preferences: adopt a newer backup of the explicit brand/note/category
    /// rules (last-write-wins), then push any local changes. Mirrors the launch/background flow on demand so a
    /// rule made on another device shows up here.
    func syncMerchantPreferencesNow() async {
        let rows = await Preferences.fetchAll(client)
        MerchantPreferences.shared.applyIfNewer(from: rows)
        await MerchantPreferences.shared.pushBestEffort(client: client)
    }

    /// Push the explicit brand/note/category rules to the per-owner blob now (best-effort, dirty-gated) - e.g.
    /// right after a swipe-to-delete so the deletion propagates promptly.
    func pushMerchantPreferences() async {
        await MerchantPreferences.shared.pushBestEffort(client: client)
    }

    /// Back up the link-sensitivity choice to the preferences blob (call after the Settings picker changes).
    func pushLinkSensitivity() async {
        await LinkSensitivitySync.pushBestEffort(client: client)
    }

    /// Best-effort backup of the review-queue state (split templates, dismissals, subscription rules) to the
    /// `suggestions.v1` blob. Fire-and-forget; call after a view mutates a `SubscriptionRule` directly.
    func pushSuggestionsSync(_ context: ModelContext) {
        Task { await SuggestionSync.pushBestEffort(context, client: client) }
    }

    /// Persist a new main-tab order locally (the TabView re-renders) and back it up to the preferences blob.
    func setTabOrder(_ order: [MainTab]) async {
        OrderPreference.tabs.write(order)
        await OrderPreference.tabs.pushBestEffort(client: client)
    }

    /// Persist a new Goals-page section order locally and back it up to the preferences blob.
    func setGoalsOrder(_ order: [GoalSection]) async {
        OrderPreference.goals.write(order)
        await OrderPreference.goals.pushBestEffort(client: client)
    }
}
