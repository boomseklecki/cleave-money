import Foundation

/// Registers / unregisters this device's APNs token for push (`/devices`). Transient - no local cache.
@MainActor
struct DeviceRepository {
    let client: Client

    func register(token: String, publicKey: String? = nil) async throws {
        let output = try await client.register_device_devices_post(
            body: .json(.init(token: token, platform: "ios", public_key: publicKey)))
        _ = try output.noContent
    }

    func unregister(token: String) async throws {
        let output = try await client.unregister_device_devices_delete(
            body: .json(.init(token: token, platform: "ios")))
        _ = try output.noContent
    }
}
