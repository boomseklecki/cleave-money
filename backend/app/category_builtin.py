"""Server-side ports of the deterministic, built-in category maps and spend-class sets.

Mirrors the iOS enums verbatim so the backend resolves a transaction's canonical category the same way the
app does:

- `PlaidCategory` (`ios/.../Logic/PlaidCategory.swift`) → `plaid_canonical`
- `SplitwiseCategory` (`ios/.../Logic/SplitwiseCategory.swift`) → `splitwise_canonical`
- `CanonicalCategory` spend-class sets (`ios/.../Logic/CategoryMapping.swift`) → the sets below

These are closed, static taxonomies (no AI/network). `tests/test_category_builtin.py` pins them against the
iOS values and asserts every canonical output is in `app.categories.CATEGORIES` - the front-line defense
against iOS/backend resolver divergence.
"""
from __future__ import annotations

from .categories import CATEGORIES

# --- Plaid personal_finance_category → canonical (mirrors PlaidCategory.swift) --------------------------

# Plaid's 16 primary categories → canonical.
_PLAID_PRIMARY: dict[str, str] = {
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
}

# Detailed values whose canonical differs from their primary.
_PLAID_DETAILED: dict[str, str] = {
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
}


def plaid_canonical(raw: str) -> str | None:
    """Canonical category for a raw Plaid label (detailed override first, then primary prefix match), or
    None if it isn't a recognized Plaid taxonomy value."""
    override = _PLAID_DETAILED.get(raw)
    if override is not None:
        return override
    for primary, canonical in _PLAID_PRIMARY.items():
        if raw == primary or raw.startswith(primary + "_"):
            return canonical
    return None


# --- Splitwise taxonomy → canonical (mirrors SplitwiseCategory.swift) ----------------------------------

_SPLITWISE: dict[str, str] = {
    # Food and drink
    "Food and drink": "Dining",
    "Dining out": "Dining",
    "Groceries": "Groceries",
    "Liquor": "Alcohol",
    # Entertainment
    "Entertainment": "Entertainment",
    "Games": "Entertainment",
    "Movies": "Entertainment",
    "Music": "Entertainment",
    "Sports": "Entertainment",
    # Home
    "Home": "Household",
    "Rent": "Rent",
    "Mortgage": "Mortgage",
    "Furniture": "Household",
    "Household supplies": "Household",
    "Maintenance": "Household",
    "Services": "Services",
    "Electronics": "Shopping",
    "Pets": "Pets",
    # Life
    "Life": "Other",
    "Clothing": "Shopping",
    "Medical expenses": "Health",
    "Insurance": "Insurance",
    "Education": "Education",
    "Gifts": "Gifts",
    "Taxes": "Fees",
    "Childcare": "Household",
    # Transportation
    "Transportation": "Transport",
    "Car": "Transport",
    "Bicycle": "Transport",
    "Bus/train": "Transport",
    "Parking": "Transport",
    "Taxi": "Transport",
    "Gas/fuel": "Fuel",
    "Plane": "Travel",
    "Hotel": "Travel",
    # Utilities
    "Utilities": "Utilities",
    "Electricity": "Utilities",
    "Heat/gas": "Utilities",
    "Water": "Utilities",
    "Trash": "Utilities",
    "TV/Phone/Internet": "Utilities",
    "Cleaning": "Utilities",
    # Uncategorized
    "General": "Other",
    "Other": "Other",
}


def splitwise_canonical(raw: str) -> str | None:
    """Canonical category for a Splitwise category name, or None if unrecognized."""
    return _SPLITWISE.get(raw)


# --- Spend-class sets (mirrors CanonicalCategory in CategoryMapping.swift) ------------------------------

# Never counted toward spend (donut/budgets).
EXCLUDED_FROM_SPEND: frozenset[str] = frozenset({"Transfer", "Income", "Settle-up", "Reimbursement"})
# No economic event - money just moving between people/accounts. Excluded from spend and net income.
NEUTRAL: frozenset[str] = frozenset({"Transfer", "Settle-up"})
# Money coming in - a net-income inflow, excluded from spend.
INCOME_LIKE: frozenset[str] = frozenset({"Income", "Reimbursement"})
TRANSFER = "Transfer"

# Every canonical value either of the built-in maps can emit must be a known category - guards divergence.
_BUILTIN_OUTPUTS: frozenset[str] = frozenset(_PLAID_PRIMARY.values()) | frozenset(
    _PLAID_DETAILED.values()
) | frozenset(_SPLITWISE.values())
assert _BUILTIN_OUTPUTS <= set(CATEGORIES), _BUILTIN_OUTPUTS - set(CATEGORIES)
