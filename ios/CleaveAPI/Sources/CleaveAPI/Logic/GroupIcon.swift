import Foundation

extension Group {
    /// SF Symbol for the Splitwise `group_type`, used as the group's icon since the Splitwise SDK
    /// doesn't expose group avatars. Falls back to a generic people symbol.
    var typeSymbol: String {
        switch groupType?.lowercased() {
        case "trip": return "airplane"
        case "apartment", "house", "home": return "house.fill"
        case "couple": return "heart.fill"
        default: return "person.2.fill"
        }
    }
}
