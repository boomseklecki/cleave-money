import Foundation

/// Deterministic mapping of Plaid's `personal_finance_category` taxonomy to our canonical categories.
/// Plaid sends fixed SCREAMING_SNAKE labels (primary like `FOOD_AND_DRINK`, or detailed like
/// `FOOD_AND_DRINK_GROCERIES`); this resolves them with no AI/network. User and on-device overrides in
/// `category_map` still take precedence (see `CategoryMapping.effectiveCategory`).
enum PlaidCategory {
    /// The canonical category for a raw Plaid label, or nil if it isn't a recognized Plaid taxonomy
    /// value (then the caller falls back to the raw/humanized string).
    static func canonical(_ raw: String) -> String? {
        if let override = detailedOverrides[raw] { return override }
        for (primary, canonical) in primaryMap where raw == primary || raw.hasPrefix(primary + "_") {
            return canonical
        }
        return nil
    }

    /// A friendly Title Case rendering of a raw SCREAMING_SNAKE label, for display when there's no
    /// canonical mapping yet (e.g. "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS" → "Personal Care Gyms And...").
    static func humanized(_ raw: String) -> String {
        raw.split(separator: "_").map { $0.lowercased().capitalized }.joined(separator: " ")
    }

    /// A readable form of any raw category label: SCREAMING_SNAKE Plaid labels are humanized; already-readable
    /// labels (Splitwise "Dining out", "Gas/fuel", or a manual value) pass through unchanged so they're not
    /// mangled. Used wherever the bank's raw category is shown to the user.
    static func displayLabel(_ raw: String) -> String {
        let isPlaidFormat = !raw.isEmpty
            && raw.allSatisfy { $0.isUppercase || $0 == "_" || $0.isNumber }
            && raw.contains(where: \.isLetter)
        return isPlaidFormat ? humanized(raw) : raw
    }

    /// Plaid's 16 primary categories → canonical.
    private static let primaryMap: [String: String] = [
        "INCOME": "Income",
        "TRANSFER_IN": "Transfer",
        "TRANSFER_OUT": "Transfer",
        "LOAN_PAYMENTS": "Transfer",
        "BANK_FEES": "Fees",
        "ENTERTAINMENT": "Entertainment",
        "FOOD_AND_DRINK": "Dining",
        "GENERAL_MERCHANDISE": "Shopping",
        "HOME_IMPROVEMENT": "Household",
        "MEDICAL": "Health",
        "PERSONAL_CARE": "Personal Care",
        "GENERAL_SERVICES": "Other",
        "GOVERNMENT_AND_NON_PROFIT": "Other",
        "TRANSPORTATION": "Transport",
        "TRAVEL": "Travel",
        "RENT_AND_UTILITIES": "Utilities",
    ]

    /// Detailed values whose canonical differs from their primary (so the budget categories that split
    /// within a primary - Groceries vs Dining, Fuel vs Transport, Rent vs Utilities - are reachable).
    private static let detailedOverrides: [String: String] = [
        "FOOD_AND_DRINK_GROCERIES": "Groceries",
        "FOOD_AND_DRINK_BEER_WINE_AND_LIQUOR": "Alcohol",
        "TRANSPORTATION_GAS": "Fuel",
        "RENT_AND_UTILITIES_RENT": "Rent",
        "LOAN_PAYMENTS_MORTGAGE_PAYMENT": "Mortgage",
        "GENERAL_SERVICES_INSURANCE": "Insurance",
        "GENERAL_SERVICES_EDUCATION": "Education",
        "GENERAL_MERCHANDISE_PET_SUPPLIES": "Pets",
        "MEDICAL_VETERINARY_SERVICES": "Pets",
        "GOVERNMENT_AND_NON_PROFIT_DONATIONS": "Gifts",
    ]
}
