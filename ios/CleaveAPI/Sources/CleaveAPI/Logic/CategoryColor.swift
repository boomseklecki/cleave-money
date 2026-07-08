import SwiftUI

/// A stable color for a category, for the spending donut and budget bars. The user's chosen color (from the
/// category editor) wins; otherwise canonical categories get a fixed hue and anything else hashes into the same
/// palette so colors stay consistent across renders. Main-actor because it reads `CategoryCatalog` (like
/// `categorySymbol`); every caller is already on the main thread (SwiftUI view bodies).
@MainActor
func categoryColor(_ category: String?) -> Color {
    guard let category, !category.isEmpty else { return .gray }
    if let hex = CategoryCatalog.shared.color(for: category), let custom = Color(hex: hex) { return custom }
    return categoryPaletteColor(category)
}

/// The deterministic (non-custom) color for a category name: the fixed hue for a canonical category, else a
/// stable hash into the wheel. What `categoryColor` falls back to, and what the editor's "Auto" swatch shows.
func categoryPaletteColor(_ category: String) -> Color {
    if let fixed = palette[category] { return fixed }
    let index = abs(category.hashValue) % wheel.count
    return wheel[index]
}

/// The preset color swatches offered in the category editor (stored/synced as hex so they persist).
let categoryColorChoices: [String] = [
    "#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#30B0C7", "#5856D6", "#00C7BE",
    "#FF3B30", "#32ADE6", "#FFCC00", "#A2845E", "#8E8E93",
]

private let wheel: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint,
    .red, .cyan, .yellow, .brown,
]

private let palette: [String: Color] = [
    "Groceries": .green,
    "Dining": .orange,
    "Alcohol": .purple,
    "Transport": .blue,
    "Fuel": .indigo,
    "Utilities": .yellow,
    "Rent": .brown,
    "Mortgage": .brown,
    "Entertainment": .pink,
    "Travel": .teal,
    "Health": .red,
    "Insurance": .gray,
    "Shopping": .purple,
    "Household": .mint,
    "Services": .brown,
    "Subscriptions": .cyan,
    "Education": .blue,
    "Gifts": .pink,
    "Personal Care": .purple,
    "Pets": .brown,
    "Fees": .gray,
    "Income": .green,
    "Transfer": .gray,
    "Settle-up": .gray,
    "Other": .secondary,
]
