import SwiftUI
import UIKit

/// Maps a Plaid institution name to a logo, served by our own favicon proxy (`/logos/{domain}`) - the same
/// service that powers subscription brand logos, so bank domains never leave the self-hosted server. Matching
/// is keyword-based (institutions report varied names like "Citibank Online"); unknown banks return nil and
/// the row falls back to a generic bank glyph.
enum InstitutionBrand {
    /// `(keyword, domain)` - checked in order, so put more specific keywords first (e.g. "citizens" before
    /// "citi", since "citizens" contains "citi").
    private static let domains: [(keyword: String, domain: String)] = [
        ("citizens", "citizensbank.com"),
        ("citi", "citi.com"),
        ("chase", "chase.com"),
        ("bank of america", "bankofamerica.com"),
        ("bofa", "bankofamerica.com"),
        ("wells fargo", "wellsfargo.com"),
        ("capital one", "capitalone.com"),
        ("u.s. bank", "usbank.com"),
        ("us bank", "usbank.com"),
        ("usaa", "usaa.com"),
        ("american express", "americanexpress.com"),
        ("amex", "americanexpress.com"),
        ("discover", "discover.com"),
        ("ally", "ally.com"),
        ("td bank", "td.com"),
        ("truist", "truist.com"),
        ("pnc", "pnc.com"),
        ("regions", "regions.com"),
        ("huntington", "huntington.com"),
        ("fifth third", "53.com"),
        ("keybank", "key.com"),
        ("navy federal", "navyfederal.org"),
        ("charles schwab", "schwab.com"),
        ("schwab", "schwab.com"),
        ("fidelity", "fidelity.com"),
        ("vanguard", "vanguard.com"),
        ("synchrony", "synchrony.com"),
        ("barclays", "barclaysus.com"),
        ("marcus", "marcus.com"),
        ("goldman", "marcus.com"),
        ("sofi", "sofi.com"),
        ("chime", "chime.com"),
        ("varo", "varomoney.com"),
        ("venmo", "venmo.com"),
        ("paypal", "paypal.com"),
        ("cash app", "cash.app"),
        ("robinhood", "robinhood.com"),
        ("apple card", "apple.com"),
        ("apple cash", "apple.com"),
    ]

    /// The registrable domain for an institution name, or nil when unknown.
    static func domain(for institutionName: String?) -> String? {
        guard let name = institutionName?.lowercased() else { return nil }
        return domains.first { name.contains($0.keyword) }?.domain
    }

    /// The favicon-proxy logo URL string for an institution name (nil when unknown), for `AvatarView(url:)`.
    static func logoURL(for institutionName: String?) -> String? {
        guard let domain = domain(for: institutionName) else { return nil }
        return APIConfig.baseURL.appendingPathComponent("logos/\(domain)").absoluteString
    }

    /// Logo URL preferring the backend-resolved `domain` (authoritative, any bank - both the favicon and
    /// Plaid's full logo are seeded into the proxy), falling back to the on-device catalog by name for items
    /// not yet re-synced. Honors the per-bank Icon/Logo preference: a bank set to `.logo` requests Plaid's full
    /// logo (`?variant=plaid`, which the proxy serves when seeded and otherwise falls back to the favicon);
    /// otherwise the favicon. The preference is keyed on the resolved domain so account rows (whose own
    /// `institutionDomain` may be nil and resolve via the catalog) match the Linked Banks choice.
    @MainActor static func logoURL(domain: String?, name: String?) -> String? {
        let backendDomain = domain.flatMap { $0.isEmpty ? nil : $0 }
        guard let resolved = backendDomain ?? self.domain(for: name) else { return nil }
        var url = APIConfig.baseURL.appendingPathComponent("logos/\(resolved)").absoluteString
        if BankLogoPreferences.shared.style(forDomain: resolved) == .logo {
            url += "?variant=plaid"
        }
        return url
    }
}

/// Which image a bank's avatar shows: its square favicon (`.icon`, the default) or Plaid's full logo
/// (`.logo`). The choice is per-domain and persisted in `UserDefaults`.
enum BankLogoStyle: String { case icon, logo }

/// Shared, observable store for the per-bank Icon/Logo choice. Backed by `UserDefaults` (so it persists) but
/// `@Observable` so reading `style(forDomain:)` during a SwiftUI body registers a dependency - every bank
/// avatar across the app re-renders the moment the choice changes, not just the screen that changed it.
@MainActor
@Observable
final class BankLogoPreferences {
    static let shared = BankLogoPreferences()

    private var styles: [String: BankLogoStyle]

    private static func key(_ domain: String) -> String { "bankLogoStyle.\(domain)" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [String: BankLogoStyle] = [:]
        for (k, v) in defaults.dictionaryRepresentation() where k.hasPrefix("bankLogoStyle.") {
            if let raw = v as? String, let style = BankLogoStyle(rawValue: raw) {
                loaded[String(k.dropFirst("bankLogoStyle.".count))] = style
            }
        }
        self.styles = loaded
    }

    private let defaults: UserDefaults

    func style(forDomain domain: String) -> BankLogoStyle { styles[domain] ?? .icon }

    func setStyle(_ style: BankLogoStyle, forDomain domain: String) {
        styles[domain] = style
        defaults.set(style.rawValue, forKey: Self.key(domain))
    }
}

extension Color {
    /// A SwiftUI `Color` from a hex string: 6-digit RGB ("#0079be") or 8-digit RGBA ("#0079be80"); nil when
    /// unparseable. The alpha byte is optional so a custom color with opacity round-trips.
    init?(hex: String?) {
        guard var hex, !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6:
            self.init(.sRGB,
                      red: Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
        case 8:
            self.init(.sRGB,
                      red: Double((value >> 24) & 0xFF) / 255,
                      green: Double((value >> 16) & 0xFF) / 255,
                      blue: Double((value >> 8) & 0xFF) / 255,
                      opacity: Double(value & 0xFF) / 255)
        default:
            return nil
        }
    }

    /// The inverse of `init(hex:)`: "#RRGGBB", or "#RRGGBBAA" when the color has partial opacity. nil if the
    /// color's components can't be read (e.g. a non-RGB dynamic color). Used to persist a custom-picked color.
    func hexString() -> String? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func byte(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        let rgb = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        return a < 0.999 ? rgb + String(format: "%02X", byte(a)) : rgb
    }
}
