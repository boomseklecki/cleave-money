import Foundation

/// Admin-editable, server-global runtime settings. GET is readable by any enrolled member; PATCH is admin-only.
@MainActor
struct ServerSettingsRepository {
    let client: Client

    func get() async throws -> Components.Schemas.ServerSettingsResponse {
        try await client.get_server_settings_server_settings_get().ok.body.json
    }

    @discardableResult
    func update(
        _ body: Components.Schemas.ServerSettingsUpdate
    ) async throws -> Components.Schemas.ServerSettingsResponse {
        let output = try await client.update_server_settings_server_settings_patch(body: .json(body))
        let ok = try output.ok
        return try ok.body.json
    }
}
