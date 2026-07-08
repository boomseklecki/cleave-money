import SwiftUI

/// Admin-only editor for the server-global runtime settings (formerly `.env` policy). Loads from
/// `GET /server-settings`, saves the full set via `PATCH /server-settings`.
struct ServerSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var loaded = false
    @State private var saving = false
    @State private var errorText: String?
    /// The last loaded/saved values; `dirty` compares the live fields to this to drive the Save button and the
    /// navigate-away guard.
    @State private var baseline = Editable()

    @State private var serverName = ""
    @State private var defaultCurrency = "USD"
    @State private var invitesOpenToMembers = false
    @State private var splitwiseReceiptDownload = false
    @State private var splitwiseReceiptBackfill = false
    @State private var downloadingReceipts = false
    @State private var downloadSummary: String?
    @State private var syncIntervalHours = 0
    @State private var backupIntervalHours = 0
    @State private var backupsRetentionDays = 30
    @State private var backupsRetentionMinKeep = 7
    @State private var refreshPlaidStale = 60
    @State private var refreshSplitwiseStale = 15
    @State private var refreshSimplefinStale = 720
    @State private var plaidEnabled = true
    @State private var simplefinEnabled = true
    @State private var notificationsRetention = 100
    @State private var notificationsPollMinutes = 0
    @State private var pushEnabled = true
    @State private var budgetPushEnabled = false
    @State private var offsiteBackupEnabled = false
    @State private var offsiteBackupTarget = ""
    @State private var offsiteStatus: Components.Schemas.OffsiteStatus?
    @State private var offsiteRunning = false

    /// The editable subset of the form (the action buttons/status aren't settings), captured so we can detect
    /// unsaved changes by value.
    private struct Editable: Equatable {
        var serverName = ""
        var defaultCurrency = "USD"
        var invitesOpenToMembers = false
        var splitwiseReceiptDownload = false
        var splitwiseReceiptBackfill = false
        var syncIntervalHours = 0
        var backupIntervalHours = 0
        var backupsRetentionDays = 30
        var backupsRetentionMinKeep = 7
        var refreshPlaidStale = 60
        var refreshSplitwiseStale = 15
        var refreshSimplefinStale = 720
        var plaidEnabled = true
        var simplefinEnabled = true
        var notificationsRetention = 100
        var notificationsPollMinutes = 0
        var pushEnabled = true
        var budgetPushEnabled = false
        var offsiteBackupEnabled = false
        var offsiteBackupTarget = ""
    }

    private var current: Editable {
        Editable(serverName: serverName, defaultCurrency: defaultCurrency,
                 invitesOpenToMembers: invitesOpenToMembers,
                 splitwiseReceiptDownload: splitwiseReceiptDownload,
                 splitwiseReceiptBackfill: splitwiseReceiptBackfill, syncIntervalHours: syncIntervalHours,
                 backupIntervalHours: backupIntervalHours, backupsRetentionDays: backupsRetentionDays,
                 backupsRetentionMinKeep: backupsRetentionMinKeep, refreshPlaidStale: refreshPlaidStale,
                 refreshSplitwiseStale: refreshSplitwiseStale, refreshSimplefinStale: refreshSimplefinStale,
                 plaidEnabled: plaidEnabled, simplefinEnabled: simplefinEnabled,
                 notificationsRetention: notificationsRetention,
                 notificationsPollMinutes: notificationsPollMinutes, pushEnabled: pushEnabled,
                 budgetPushEnabled: budgetPushEnabled, offsiteBackupEnabled: offsiteBackupEnabled,
                 offsiteBackupTarget: offsiteBackupTarget)
    }

    private var dirty: Bool { loaded && current != baseline }

    var body: some View {
        Form {
            Section {
                TextField("Server name", text: $serverName)
                    .autocorrectionDisabled()
                TextField("Default currency", text: $defaultCurrency)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Toggle("Let any member invite people", isOn: $invitesOpenToMembers)
            } header: {
                Text("General")
            } footer: {
                Text("Server name shows on the join/confirm screen when someone adds this server. Default "
                     + "currency (an ISO code like USD) applies to new expenses, accounts, and goals that "
                     + "don't specify one. Invites: off = only admins can create invite links, on = any "
                     + "enrolled member can.")
            }

            Section {
                if env.serverPlaidConfigured {
                    Toggle("Allow new Plaid links", isOn: $plaidEnabled)
                }
                Toggle("Allow SimpleFIN", isOn: $simplefinEnabled)
            } header: {
                Text("Bank connections")
            } footer: {
                Text("Which ways to connect a bank the app offers. Turning off Plaid stops new Plaid links; "
                     + "existing Plaid accounts keep syncing. SimpleFIN needs no server setup, and user data "
                     + "only flows through SimpleFIN once someone connects it.")
            }

            Section {
                Stepper("Auto-sync: \(intervalLabel(syncIntervalHours))",
                        value: $syncIntervalHours, in: 0...168)
                Stepper("Bank (Plaid): \(staleLabel(refreshPlaidStale))",
                        value: $refreshPlaidStale, in: 0...1440)
                Stepper("Splitwise: \(staleLabel(refreshSplitwiseStale))",
                        value: $refreshSplitwiseStale, in: 0...1440)
                if simplefinEnabled {
                    Stepper("SimpleFIN refresh: \(staleLabel(refreshSimplefinStale))",
                            value: $refreshSimplefinStale, in: 60...1440, step: 30)
                }
            } header: {
                Text("Syncing")
            } footer: {
                Text("Auto-sync runs a full background sync on a schedule (0h = off). The freshness values "
                     + "are for pull-to-refresh: it does a live sync only when the data is older than this, "
                     + "otherwise it just refreshes from the server. Bank (Plaid) calls cost money, so sync "
                     + "them less often than free Splitwise (0 min = always sync). SimpleFIN refreshes about "
                     + "daily, so its window is long to stay under its request quota. Changes take effect "
                     + "within a minute, no restart needed.")
            }

            Section {
                Stepper("Auto-backup: \(intervalLabel(backupIntervalHours))",
                        value: $backupIntervalHours, in: 0...168)
                Stepper("Keep backups \(backupsRetentionDays) days",
                        value: $backupsRetentionDays, in: 1...365)
                Stepper("Always keep newest \(backupsRetentionMinKeep)",
                        value: $backupsRetentionMinKeep, in: 1...100)
                NavigationLink {
                    BackupsView()
                } label: {
                    Label("Local Backups", systemImage: "externaldrive")
                }
            } header: {
                Text("Local backups")
            } footer: {
                Text("On-server snapshots (database + receipts) kept in the backend's own storage. Auto-backup "
                     + "runs on a schedule (0h = off); snapshots past the retention window are pruned, but the "
                     + "newest are always kept. Open Local Backups to create, restore, or delete one. Changes "
                     + "take effect within a minute, no restart needed.")
            }

            Section {
                Toggle("Off-device backup", isOn: $offsiteBackupEnabled)
                TextField("s3:host/bucket/path", text: $offsiteBackupTarget)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let offsiteStatus, let last = offsiteStatus.last_run_at {
                    Text("Last backup \(last.formatted(.relative(presentation: .named)))"
                         + " · \(offsiteStatus.last_status ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No off-device backup yet.").font(.caption).foregroundStyle(.secondary)
                }
                Button { offsiteBackupNow() } label: {
                    HStack {
                        Label(offsiteRunning ? "Backing up…" : "Back up off-device now",
                              systemImage: "arrow.up.circle")
                        Spacer()
                        if offsiteRunning { ProgressView() }
                    }
                }
                .disabled(!offsiteBackupEnabled || offsiteBackupTarget.isEmpty || offsiteRunning || !loaded)
                NavigationLink {
                    OffsiteSnapshotsView()
                } label: {
                    Label("Off-device snapshots", systemImage: "list.bullet")
                }
            } header: {
                Text("Off-device backups")
            } footer: {
                Text("Encrypted, off-host backups via restic (mirrors the local backup schedule). The repository "
                     + "is a non-secret restic target; its password (RESTIC_PASSWORD) and any cloud credentials "
                     + "must be set in the server's .env — the app never collects them. Save before backing up.")
            }

            Section {
                Stepper("Keep newest \(notificationsRetention)",
                        value: $notificationsRetention, in: 10...1000, step: 10)
                Stepper("Live notification poll: \(pollLabel(notificationsPollMinutes))",
                        value: $notificationsPollMinutes, in: 0...60)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Keep: how many notifications to retain per person (older are pruned on each sync). "
                     + "Live poll: how often to check Splitwise just for new activity so partner-activity "
                     + "pushes arrive promptly instead of waiting for the full auto-sync. 0 = off.")
            }

            // Only shown on a prod server that actually has a push relay configured (not on demo).
            if env.serverHasPush && !env.serverIsDemo {
                Section {
                    Toggle("Push notifications", isOn: $pushEnabled)
                    Toggle("Budget alerts", isOn: $budgetPushEnabled)
                } header: {
                    Text("Push notifications")
                } footer: {
                    Text("Master switch for device push (the relay is set up in the server's .env; turning this "
                         + "off pauses push without touching it). Budget alerts push a solo spend-goal owner "
                         + "once a month when they cross 85% / 100% of a budget.")
                }
            }

            Section {
                Toggle("Download receipts on import to local", isOn: $splitwiseReceiptDownload)
                Toggle("Download all + auto-backfill receipts", isOn: $splitwiseReceiptBackfill)
                Button { downloadAllReceipts() } label: {
                    HStack {
                        Label(downloadingReceipts ? "Starting…" : "Download all receipts now",
                              systemImage: "arrow.down.circle")
                        Spacer()
                        if downloadingReceipts { ProgressView() }
                    }
                }
                .disabled(!splitwiseReceiptBackfill || downloadingReceipts || !loaded)
                if let downloadSummary {
                    Text(downloadSummary).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Splitwise receipts")
            } footer: {
                Text("Import-to-local downloads a group's receipts only when you convert it to a local group. "
                     + "All + auto-backfill enables the button below (a one-time background pull of every "
                     + "not-yet-saved receipt, newest first) and trickles new ones in during scheduled syncs. "
                     + "Save before using the button.")
            }

            Section {
                NavigationLink {
                    BrandCatalogView()
                } label: {
                    Label("Brand logos", systemImage: "photo.circle")
                }
            } header: {
                Text("Merchant logos")
            } footer: {
                Text("Curate the merchant→logo map used for transaction and expense favicons (add, edit, or "
                     + "remove brands). Saved separately from this screen.")
            }

        }
        .navigationTitle("Server Settings")
        .navigationBarTitleDisplayMode(.inline)
        .unsavedChangesGuard(dirty: dirty, saving: saving) { await save() }
        .errorAlert($errorText)
        .task { if !loaded { await load() } }
    }

    private func downloadAllReceipts() {
        downloadingReceipts = true
        downloadSummary = nil
        Task {
            defer { downloadingReceipts = false }
            do {
                let result = try await env.splitwise.downloadAllReceipts()
                downloadSummary = result.enabled
                    ? "Downloading \(result.pending.formatted()) receipt\(result.pending == 1 ? "" : "s") in the "
                        + "background — you can leave this screen."
                    : "Turn on “Download all + auto-backfill” and Save first."
            } catch { errorText = errorMessage(error) }
        }
    }

    private func intervalLabel(_ hours: Int) -> String { hours <= 0 ? "Off" : "every \(hours)h" }
    private func staleLabel(_ minutes: Int) -> String { minutes <= 0 ? "always sync" : "\(minutes) min" }
    private func pollLabel(_ minutes: Int) -> String { minutes <= 0 ? "Off" : "every \(minutes) min" }

    private func apply(_ s: Components.Schemas.ServerSettingsResponse) {
        serverName = s.public_hostname
        defaultCurrency = s.default_currency
        invitesOpenToMembers = s.invites_open_to_members
        splitwiseReceiptDownload = s.splitwise_receipt_download_enabled
        splitwiseReceiptBackfill = s.splitwise_receipt_backfill_enabled
        syncIntervalHours = s.sync_interval_hours
        backupIntervalHours = s.backup_interval_hours
        backupsRetentionDays = s.backups_retention_days
        backupsRetentionMinKeep = s.backups_retention_min_keep
        refreshPlaidStale = s.refresh_plaid_stale_minutes
        refreshSplitwiseStale = s.refresh_splitwise_stale_minutes
        refreshSimplefinStale = s.refresh_simplefin_stale_minutes
        plaidEnabled = s.plaid_enabled
        simplefinEnabled = s.simplefin_enabled
        notificationsRetention = s.notifications_retention_count
        notificationsPollMinutes = s.notifications_poll_minutes
        pushEnabled = s.push_enabled
        budgetPushEnabled = s.budget_push_enabled
        offsiteBackupEnabled = s.offsite_backup_enabled
        offsiteBackupTarget = s.offsite_backup_target
        baseline = current   // freshly loaded/saved values are the new clean baseline
    }

    private func load() async {
        do { apply(try await env.serverSettings.get()); loaded = true }
        catch { errorText = errorMessage(error) }
        offsiteStatus = try? await env.backups.offsiteStatus()  // best-effort; nil on a backend without the tier
    }

    private func offsiteBackupNow() {
        offsiteRunning = true
        Task {
            defer { offsiteRunning = false }
            do { offsiteStatus = try await env.backups.offsitePushNow() }
            catch { errorText = errorMessage(error) }
        }
    }

    /// Saves the full set; returns whether it succeeded (so the guard's Save & Close only dismisses on success).
    @discardableResult
    private func save() async -> Bool {
        saving = true
        defer { saving = false }
        do {
            let updated = try await env.serverSettings.update(.init(
                invites_open_to_members: invitesOpenToMembers,
                public_hostname: serverName,
                default_currency: defaultCurrency,
                splitwise_receipt_download_enabled: splitwiseReceiptDownload,
                splitwise_receipt_backfill_enabled: splitwiseReceiptBackfill,
                sync_interval_hours: syncIntervalHours,
                backup_interval_hours: backupIntervalHours,
                backups_retention_days: backupsRetentionDays,
                backups_retention_min_keep: backupsRetentionMinKeep,
                offsite_backup_enabled: offsiteBackupEnabled,
                offsite_backup_target: offsiteBackupTarget,
                refresh_plaid_stale_minutes: refreshPlaidStale,
                refresh_splitwise_stale_minutes: refreshSplitwiseStale,
                refresh_simplefin_stale_minutes: refreshSimplefinStale,
                simplefin_enabled: simplefinEnabled,
                plaid_enabled: plaidEnabled,
                notifications_retention_count: notificationsRetention,
                notifications_poll_minutes: notificationsPollMinutes,
                push_enabled: pushEnabled,
                budget_push_enabled: budgetPushEnabled))
            apply(updated)   // resets baseline → dirty=false
            await env.loadRefreshThresholds()  // apply the new thresholds to the running app
            return true
        } catch { errorText = errorMessage(error); return false }
    }
}

#if DEBUG
// An environment-backed screen: `.previewEnvironment()` supplies the AppEnvironment + an in-memory store.
// Offline in the canvas, so the form shows its default values (the network load just no-ops).
#Preview {
    NavigationStack { ServerSettingsView() }
        .previewEnvironment()
}
#endif
