import Foundation

/// Presentation of category provenance: a short user-facing badge (You / AI / Auto) and a compact debug
/// inspector string. Keeps the on-device AI - and AI-written map entries - visible instead of hidden.
extension CategoryOrigin {
    /// User-facing badge text.
    var badgeLabel: String {
        switch self {
        case .override, .mappedByYou, .explicit: return "You"
        case .mappedByAI, .aiRefined: return "AI"
        case .deterministic: return "Auto"
        case .raw: return "Raw"
        }
    }

    /// SF Symbol paired with the badge.
    var badgeSymbol: String {
        switch self {
        case .override, .mappedByYou, .explicit: return "pencil"            // you set it
        case .mappedByAI, .aiRefined: return "apple.intelligence"           // on-device Apple Intelligence
        case .deterministic: return "gearshape"                            // routed via a built-in rule
        case .raw: return "tag"                                            // unmapped passthrough (hidden)
        }
    }

    /// The operator used in the inspector string, encoding the source.
    /// `\` override · `>` you-mapped · `*` AI (map or refine) · `=` deterministic · `:` explicit · `~` raw.
    var inspectorOperator: String {
        switch self {
        case .override: return "\\"
        case .mappedByYou: return ">"
        case .mappedByAI, .aiRefined: return "*"
        case .deterministic: return "="
        case .explicit: return ":"
        case .raw: return "~"
        }
    }

    /// Whether the source is worth badging - a bare raw passthrough says nothing useful.
    var isNotable: Bool { self != .raw }
}

extension CategoryResolution {
    /// "<raw> <op> <canonical>" - a one-line provenance trace for the debug inspector. The raw side is cleaned
    /// (Plaid SCREAMING_SNAKE → Title Case; Splitwise/manual labels pass through) so it reads naturally.
    var inspectorString: String {
        "\(raw.map(PlaidCategory.displayLabel) ?? "—") \(source.inspectorOperator) \(category ?? "—")"
    }
}
