import SwiftUI

/// A circular avatar that loads a remote image when available and otherwise shows the person's
/// initials on a neutral background.
struct AvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 36
    /// When there's no remote image, show this SF Symbol instead of initials (e.g. a group-type icon).
    var systemImage: String? = nil
    /// Render a brand/bank logo (fit whole, on a white tile) instead of a photo (fill). Brand logos are
    /// often transparent with dark artwork, so the white tile keeps them visible - including in dark mode.
    var logo: Bool = false
    /// When set AND the remote image actually loads, overlay this SF Symbol as a small bottom-trailing badge
    /// (keeps the category cue once a merchant favicon replaces the category icon). Never drawn on the
    /// placeholder, so exactly one category icon is ever visible. Default nil → unchanged for all callers.
    var badgeSystemImage: String? = nil
    var badgeColor: Color = .secondary

    var body: some View { content }

    /// A custom-avatar URL is one of OUR auth-gated endpoints (`/users/{id}/avatar`, `/groups/{id}/avatar`),
    /// given as a host-less relative path (or absolute under the base URL). Those need the bearer + a base-URL
    /// prefix, so they load through `AvatarImageStore`. Everything else - external Splitwise/Google URLs and the
    /// `/logos` favicon proxy (which keeps the category badge) - stays on plain `AsyncImage`.
    private var avatarPath: String? {
        guard let url else { return nil }
        let path: String
        if url.hasPrefix("/") {
            path = String(url.dropFirst())
        } else {
            let base = APIConfig.baseURL.absoluteString
            guard url.hasPrefix(base) else { return nil }
            let rest = String(url.dropFirst(base.count))
            path = rest.hasPrefix("/") ? String(rest.dropFirst()) : rest
        }
        guard (path.hasPrefix("users/") || path.hasPrefix("groups/")) && path.hasSuffix("/avatar") else { return nil }
        return path
    }

    @ViewBuilder
    private var content: some View {
        if let avatarPath {
            // `.id(version)` reloads every avatar when one changes; the just-uploaded image is preseeded so the
            // reload is an instant cache hit. A 403/failure falls back to the placeholder (never a broken image).
            clipped(AsyncCachedImage(mode: .fill,
                                     load: { await AvatarImageStore.shared.image(path: avatarPath) }) {
                placeholder
            }
            .id(AvatarImageStore.shared.version))
        } else if let url, let resolved = URL(string: url) {
            AsyncImage(url: resolved) { phase in
                if let image = phase.image {
                    clipped(renderImage(image))
                        .overlay(alignment: .bottomTrailing) { badge }   // badge ONLY when loaded
                } else if phase.error != nil {
                    clipped(placeholder)                                 // error → category icon, no badge
                } else if systemImage != nil {
                    clipped(placeholder)                                 // loading → category icon (no spinner)
                } else {
                    clipped(ProgressView())                             // loading, no symbol → spinner (as before)
                }
            }
        } else {
            clipped(placeholder)                                        // no URL → category icon, no badge
        }
    }

    private func clipped(_ view: some View) -> some View {
        view.frame(width: size, height: size).clipShape(Circle())
    }

    @ViewBuilder
    private func renderImage(_ image: Image) -> some View {
        if logo {
            image.resizable().scaledToFit()
                .padding(size * 0.14)
                .frame(width: size, height: size)
                .background(Color.white)  // so dark, transparent logos stay visible in any appearance
        } else {
            image.resizable().scaledToFill()
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.secondary)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
    }

    /// Small category badge, drawn on a system-background chip so it reads over the white logo tile. Sits
    /// just past the bottom-trailing corner like a standard iOS status badge (not clipped by the avatar).
    @ViewBuilder
    private var badge: some View {
        if let badgeSystemImage {
            Image(systemName: badgeSystemImage)
                .font(.system(size: size * 0.30, weight: .semibold))     // glyph ~30% of avatar (in 25–33%)
                .foregroundStyle(badgeColor)
                .frame(width: size * 0.42, height: size * 0.42)
                .background(Circle().fill(Color(.systemBackground)))     // reads over the white logo tile
                .offset(x: size * 0.06, y: size * 0.06)                  // straddle the corner
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
