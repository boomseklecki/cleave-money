import Foundation

/// The pinch/pan transform baked into a custom avatar, so the crop editor can reload past a prior crop.
/// `dx`/`dy` are normalized to the crop-frame size (resolution-independent). Mirrors the backend `AvatarCrop`.
public struct AvatarCrop: Equatable, Sendable {
    public var scale: Double
    public var dx: Double
    public var dy: Double

    public init(scale: Double, dx: Double, dy: Double) {
        self.scale = scale; self.dx = dx; self.dy = dy
    }

    /// The `X-Avatar-Crop` header value: "scale,dx,dy".
    var headerValue: String { "\(scale),\(dx),\(dy)" }
}

/// Raw-URLSession HTTP for the custom-avatar endpoints. The display PUT carries `X-Avatar-Crop`, which the
/// backend reads as a plain request header (not a declared OpenAPI parameter), so these bypass the generated
/// client - the same authed-URLSession approach `SplitwiseReceiptImageStore` uses. Bearer token + base URL come
/// from the app's per-server config.
enum AvatarService {
    /// Which entity's avatar: the signed-in user (`me/avatar`) or a group (`groups/<id>/avatar`).
    enum Target {
        case me
        case group(UUID)

        var displayPath: String {
            switch self {
            case .me: "me/avatar"
            case .group(let id): "groups/\(id.uuidString)/avatar"
            }
        }
        var originalPath: String { displayPath + "/original" }
    }

    /// Upload the full-res original first, then the display square (the display PUT commits the avatar and
    /// stores the crop). If only the original lands, the entity still shows no custom avatar.
    static func upload(_ target: Target, display: Data, original: Data, crop: AvatarCrop) async throws {
        _ = try await send(target.originalPath, method: "PUT", body: original, crop: nil)
        _ = try await send(target.displayPath, method: "PUT", body: display, crop: crop)
    }

    static func delete(_ target: Target) async throws {
        _ = try await send(target.displayPath, method: "DELETE", body: nil, crop: nil)
    }

    /// The full-res original, for re-editing. 403 for non-owners/non-members.
    static func original(_ target: Target) async throws -> Data {
        try await send(target.originalPath, method: "GET", body: nil, crop: nil)
    }

    @discardableResult
    private static func send(_ path: String, method: String, body: Data?, crop: AvatarCrop?) async throws -> Data {
        var request = URLRequest(url: APIConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let token = KeychainTokenStore.forServer(APIConfig.baseURL).load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        }
        if let crop { request.setValue(crop.headerValue, forHTTPHeaderField: "X-Avatar-Crop") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BackendError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}
