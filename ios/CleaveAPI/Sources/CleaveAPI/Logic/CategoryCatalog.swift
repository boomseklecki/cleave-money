import Foundation

/// In-memory `name → SF Symbol` cache so the free `categorySymbol(_:)` can honor a category's
/// user-chosen icon without every call site holding the local `SpendCategory` list. Rebuilt by
/// `CategoryRepository`/`CategorySync` whenever categories change. Main-thread only.
///
/// `@Observable` so a view that reads an icon through `categorySymbol(_:)` (e.g. a transaction/expense row's
/// category badge, which only has the resolved category *name*, not the `SpendCategory`) repaints when a
/// category's icon is edited. Tracking is pull-based: reading `icons` during a body render registers the
/// dependency, and only a real `update(_:)` mutation invalidates - there is no steady-state cost.
@MainActor
@Observable
final class CategoryCatalog {
    static let shared = CategoryCatalog()
    private var icons: [String: String] = [:]
    private var colors: [String: String] = [:]

    func update(_ categories: [SpendCategory]) {
        icons = Dictionary(
            categories.compactMap { c in c.icon.flatMap { $0.isEmpty ? nil : (c.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        colors = Dictionary(
            categories.compactMap { c in c.color.flatMap { $0.isEmpty ? nil : (c.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func icon(for name: String) -> String? { icons[name] }
    func color(for name: String) -> String? { colors[name] }
}
