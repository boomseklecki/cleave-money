import Foundation
import SwiftData

/// The editable canonical category taxonomy (local/per-user): built-ins are seeded by `CategorySeed` and
/// users can add/rename/delete any; changes sync to the per-owner relational store (`/categories`) via
/// `CategorySync`.
/// `icon` is an optional SF Symbol chosen in the app (nil falls back to the keyword icon in `categorySymbol`).
///
/// Named `SpendCategory` because the bare `Category` collides with `ObjectiveC.Category`.
@Model
final class SpendCategory {
    @Attribute(.unique) var id: UUID
    var name: String
    var builtin: Bool
    var position: Int
    var icon: String?
    var color: String?   // hex like "#34C759"; nil falls back to the deterministic palette

    init(id: UUID, name: String, builtin: Bool, position: Int, icon: String? = nil, color: String? = nil) {
        self.id = id
        self.name = name
        self.builtin = builtin
        self.position = position
        self.icon = icon
        self.color = color
    }
}

extension SpendCategory {
    /// The SF Symbol to render for this category: the user's chosen `icon`, else the keyword/tag fallback.
    /// Reading `icon` (and `name`) here means a view row that shows this re-renders when the icon changes -
    /// `categorySymbol(name)` alone reads only the name, so an icon-only edit would not invalidate the row.
    @MainActor var displaySymbol: String {
        if let icon, !icon.isEmpty { return icon }
        return categorySymbol(name)
    }
}
