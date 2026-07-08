import SwiftUI
import UIKit

/// A generic NSCache-backed image store - one implementation behind the receipt and Splitwise loaders.
@MainActor
final class CacheImageStore<Key: NSObject> {
    private let cache = NSCache<Key, UIImage>()

    /// Returns the cached image for `key`, else runs `loader`, caches, and returns it (nil on failure).
    func image(for key: Key, loader: () async -> UIImage?) async -> UIImage? {
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = await loader() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Loads an image via an async closure and renders it (fill or fit) - with a spinner while loading and a
/// caller-supplied fallback on failure. The shared core of the receipt thumbnails, full-screen viewers, and the
/// carousel page (which previously each re-implemented this load-into-frame dance).
struct AsyncCachedImage<Fallback: View>: View {
    enum Mode { case fill, fit }
    let mode: Mode
    let load: () async -> UIImage?
    let fallback: Fallback

    @State private var image: UIImage?
    @State private var loading = true

    init(mode: Mode, load: @escaping () async -> UIImage?, @ViewBuilder fallback: () -> Fallback) {
        self.mode = mode
        self.load = load
        self.fallback = fallback()
    }

    var body: some View {
        SwiftUI.Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: mode == .fill ? .fill : .fit)
            } else if loading {
                ProgressView()
            } else {
                fallback
            }
        }
        .task {
            defer { loading = false }
            image = await load()
        }
    }
}
