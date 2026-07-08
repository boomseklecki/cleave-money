import Foundation

/// How aggressively the Inbox suggests linking a bank charge to an expense - a per-user, on-device knob
/// (no server involvement; the suggestion engine runs locally). Maps to the `TransactionMatcher` score floor
/// fed to `SuggestionEngine.generate(linkThreshold:)`. Default is `.strict`, preserving prior behavior; a
/// looser setting surfaces more candidates, which the confirmation sheet lets the user vet before linking.
enum LinkSensitivity: String, CaseIterable, Identifiable {
    case strict, balanced, loose

    static let storageKey = "linkSensitivity"

    var id: String { rawValue }

    /// Confidence floor (0...1) for surfacing a link suggestion.
    var threshold: Double {
        switch self {
        case .strict: return 0.85
        case .balanced: return 0.78
        case .loose: return 0.70
        }
    }

    var label: String {
        switch self {
        case .strict: return "Strict"
        case .balanced: return "Balanced"
        case .loose: return "Loose"
        }
    }

    /// The user's current choice from `UserDefaults` (defaults to `.strict`).
    static func current(_ defaults: UserDefaults = .standard) -> LinkSensitivity {
        defaults.string(forKey: storageKey).flatMap(LinkSensitivity.init(rawValue:)) ?? .strict
    }
}
