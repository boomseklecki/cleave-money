import SwiftUI
import UIKit

/// Loads an **app-hosted** (auth-gated) avatar: resolves the relative `/users|/groups/.../avatar` path against
/// the base URL and attaches the Keychain bearer, cached in memory - the same authed-URLSession approach the
/// receipt loaders use. External Splitwise/Google URLs are NOT loaded here (`AvatarView` keeps plain
/// `AsyncImage` for those). `version` bumps on any avatar change so every on-screen avatar reloads; the freshly
/// baked display image is preseeded under the new version so that reload is an instant cache hit (no flash).
@MainActor
@Observable
final class AvatarImageStore {
    static let shared = AvatarImageStore()
    private(set) var version = 0
    private let cache = NSCache<NSString, UIImage>()

    private func key(_ path: String) -> NSString { "\(path)#\(version)" as NSString }

    func image(path: String) async -> UIImage? {
        let cacheKey = key(path)
        if let cached = cache.object(forKey: cacheKey) { return cached }
        var request = URLRequest(url: APIConfig.baseURL.appendingPathComponent(path))
        if let token = KeychainTokenStore.forServer(APIConfig.baseURL).load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Call after an avatar upload/delete: bump so every `AvatarView` reloads, and preseed the just-baked
    /// display image (if any) under the new version so the reload is instant. Pass the resolved avatar path
    /// (e.g. "users/<id>/avatar"); a leading slash is tolerated.
    func changed(baked image: UIImage? = nil, path: String? = nil) {
        version += 1
        if let image, let path {
            cache.setObject(image, forKey: key(path.hasPrefix("/") ? String(path.dropFirst()) : path))
        }
    }
}
