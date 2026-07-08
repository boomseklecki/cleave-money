import Foundation

/// Deterministic mapping of Splitwise's fixed category taxonomy (parent + subcategory names, as returned
/// by the Splitwise API and stored on imported expenses) to our canonical categories. Splitwise's list is
/// closed (no custom categories), so this map is complete - no AI/network, mirroring `PlaidCategory`.
/// Used only for spend bucketing (`CategoryMapping.canonical`); the expense keeps its original label for
/// display, and `Settle-up` payments are excluded upstream.
enum SplitwiseCategory {
    /// The canonical category for a Splitwise category name, or nil if it isn't a recognized Splitwise
    /// taxonomy value (then the caller falls back to the raw string).
    static func canonical(_ raw: String) -> String? { map[raw] }

    private static let map: [String: String] = [
        // Food and drink
        "Food and drink": "Dining",
        "Dining out": "Dining",
        "Groceries": "Groceries",
        "Liquor": "Alcohol",

        // Entertainment
        "Entertainment": "Entertainment",
        "Games": "Entertainment",
        "Movies": "Entertainment",
        "Music": "Entertainment",
        "Sports": "Entertainment",

        // Home
        "Home": "Household",
        "Rent": "Rent",
        "Mortgage": "Mortgage",
        "Furniture": "Household",
        "Household supplies": "Household",
        "Maintenance": "Household",
        "Services": "Services",
        "Electronics": "Shopping",
        "Pets": "Pets",

        // Life
        "Life": "Other",
        "Clothing": "Shopping",
        "Medical expenses": "Health",
        "Insurance": "Insurance",
        "Education": "Education",
        "Gifts": "Gifts",
        "Taxes": "Fees",
        "Childcare": "Household",

        // Transportation
        "Transportation": "Transport",
        "Car": "Transport",
        "Bicycle": "Transport",
        "Bus/train": "Transport",
        "Parking": "Transport",
        "Taxi": "Transport",
        "Gas/fuel": "Fuel",
        "Plane": "Travel",
        "Hotel": "Travel",

        // Utilities
        "Utilities": "Utilities",
        "Electricity": "Utilities",
        "Heat/gas": "Utilities",
        "Water": "Utilities",
        "Trash": "Utilities",
        "TV/Phone/Internet": "Utilities",
        "Cleaning": "Utilities",

        // Uncategorized
        "General": "Other",
        "Other": "Other",
    ]
}
