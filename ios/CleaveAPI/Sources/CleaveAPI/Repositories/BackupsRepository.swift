import Foundation

/// Admin-only backup management. Server-only - there's no SwiftData cache for backups. Create and restore
/// are long-running (a full pg_dump/pg_restore + receipt IO), so `AppEnvironment` vends this on the slow
/// (300s) client. The raw artifact never reaches the device; only metadata + actions cross the wire.
@MainActor
struct BackupsRepository {
    let client: Client

    func list() async throws -> [Components.Schemas.BackupResponse] {
        let output = try await client.list_backups_backups_get()
        let ok = try output.ok
        return try ok.body.json
    }

    @discardableResult
    func create(label: String?) async throws -> Components.Schemas.BackupResponse {
        let output = try await client.create_backup_backups_post(body: .json(.init(label: label)))
        let created = try output.created
        return try created.body.json
    }

    @discardableResult
    func restore(name: String) async throws -> Components.Schemas.RestoreResult {
        let output = try await client.restore_backup_backups__name__restore_post(path: .init(name: name))
        let ok = try output.ok
        return try ok.body.json
    }

    func delete(name: String) async throws {
        let output = try await client.delete_backup_backups__name__delete(path: .init(name: name))
        _ = try output.noContent
    }

    /// Off-device (restic) backup tier: current config + last-run status.
    func offsiteStatus() async throws -> Components.Schemas.OffsiteStatus {
        let output = try await client.offsite_status_backups_offsite_get()
        return try output.ok.body.json
    }

    /// Push a fresh off-device snapshot now (long-running). Throws on 409 when the tier is disabled/unconfigured
    /// or the push fails - the detail surfaces via `errorMessage`.
    @discardableResult
    func offsitePushNow() async throws -> Components.Schemas.OffsiteStatus {
        let output = try await client.offsite_backup_now_backups_offsite_post()
        return try output.ok.body.json
    }

    /// The restic snapshots in the off-device repo (read-only). Empty when the tier is off/unconfigured.
    func offsiteSnapshots() async throws -> [Components.Schemas.OffsiteSnapshot] {
        let output = try await client.offsite_snapshots_backups_offsite_snapshots_get()
        return try output.ok.body.json
    }
}
