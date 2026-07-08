"""Golden parity tests: the backend built-in maps + resolver must match the iOS enums verbatim, so
server-side category resolution agrees with the app. The expected dicts below are copied from
`ios/.../Logic/PlaidCategory.swift`, `SplitwiseCategory.swift`, and `CategoryMapping.swift` - if those
change, these fail until both sides are updated.
"""
from app import category_builtin as cb
from app.categories import CATEGORIES
from app.services.category_resolver import (
    ORIGIN_AI_REFINED,
    ORIGIN_DETERMINISTIC,
    ORIGIN_EXPLICIT,
    ORIGIN_MAPPED_BY_AI,
    ORIGIN_MAPPED_BY_YOU,
    ORIGIN_OVERRIDE,
    ORIGIN_RAW,
    CategoryResolver,
)

# --- Plaid parity ---------------------------------------------------------------------------------------

_EXPECTED_PLAID = {
    # primary
    "INCOME": "Income",
    "TRANSFER_IN": "Transfer",
    "BANK_FEES": "Fees",
    "FOOD_AND_DRINK": "Dining",
    "GENERAL_MERCHANDISE": "Shopping",
    "GENERAL_SERVICES": "Other",
    "RENT_AND_UTILITIES": "Utilities",
    # detailed overrides win over primary
    "FOOD_AND_DRINK_GROCERIES": "Groceries",
    "FOOD_AND_DRINK_BEER_WINE_AND_LIQUOR": "Alcohol",
    "TRANSPORTATION_GAS": "Fuel",
    "RENT_AND_UTILITIES_RENT": "Rent",
    "LOAN_PAYMENTS_MORTGAGE_PAYMENT": "Mortgage",
    "MEDICAL_VETERINARY_SERVICES": "Pets",
    # detailed without an override falls back to its primary
    "FOOD_AND_DRINK_FAST_FOOD": "Dining",
    "TRANSPORTATION_TAXIS_AND_RIDE_SHARES": "Transport",
}


def test_plaid_canonical_parity():
    for raw, expected in _EXPECTED_PLAID.items():
        assert cb.plaid_canonical(raw) == expected, raw


def test_plaid_canonical_unknown_is_none():
    assert cb.plaid_canonical("NOT_A_PLAID_CATEGORY") is None
    assert cb.plaid_canonical("") is None


# --- Splitwise parity -----------------------------------------------------------------------------------


def test_splitwise_canonical_parity():
    cases = {
        "Dining out": "Dining",
        "Groceries": "Groceries",
        "Liquor": "Alcohol",
        "Gas/fuel": "Fuel",
        "TV/Phone/Internet": "Utilities",
        "Clothing": "Shopping",
        "Services": "Services",
        "General": "Other",
        "Plane": "Travel",
    }
    for raw, expected in cases.items():
        assert cb.splitwise_canonical(raw) == expected, raw
    assert cb.splitwise_canonical("Nope") is None


# --- Output / spend-class invariants --------------------------------------------------------------------


def test_every_builtin_output_is_a_known_category():
    outputs = {cb.plaid_canonical(k) for k in _EXPECTED_PLAID} | set(cb._SPLITWISE.values())
    assert outputs <= set(CATEGORIES)


def test_spend_class_sets():
    assert cb.EXCLUDED_FROM_SPEND == {"Transfer", "Income", "Settle-up", "Reimbursement"}
    assert cb.NEUTRAL == {"Transfer", "Settle-up"}
    assert cb.INCOME_LIKE == {"Income", "Reimbursement"}


# --- Resolver: the 5-rank transaction chain (mirrors CategoryMapping.resolve(for:)) ----------------------


def test_resolve_override_wins():
    r = CategoryResolver(lookup={"FOOD_AND_DRINK": "Dining"})
    res = r.resolve("FOOD_AND_DRINK", override="Travel", refined="Shopping")
    assert (res.category, res.origin) == ("Travel", ORIGIN_OVERRIDE)


def test_resolve_owner_map_beats_builtin():
    r = CategoryResolver(lookup={"FOOD_AND_DRINK": "Groceries"}, sources={"FOOD_AND_DRINK": "manual"})
    res = r.resolve("FOOD_AND_DRINK")
    assert (res.category, res.origin) == ("Groceries", ORIGIN_MAPPED_BY_YOU)


def test_resolve_owner_map_ondevice_origin():
    r = CategoryResolver(lookup={"X": "Pets"}, sources={"X": "ondevice"})
    assert r.resolve("X").origin == ORIGIN_MAPPED_BY_AI


def test_resolve_builtin_deterministic():
    r = CategoryResolver(lookup={})
    res = r.resolve("FOOD_AND_DRINK_GROCERIES")
    assert (res.category, res.origin) == ("Groceries", ORIGIN_DETERMINISTIC)


def test_resolve_refined_only_for_vague_rows():
    r = CategoryResolver(lookup={})
    # GENERAL_SERVICES → "Other" (vague), so the per-transaction refinement wins.
    res = r.resolve("GENERAL_SERVICES", refined="Shopping")
    assert (res.category, res.origin) == ("Shopping", ORIGIN_AI_REFINED)
    # ...but a confident built-in (≠ Other) is NOT second-guessed by refined.
    res2 = r.resolve("FOOD_AND_DRINK", refined="Shopping")
    assert (res2.category, res2.origin) == ("Dining", ORIGIN_DETERMINISTIC)


def test_resolve_vague_without_refined_falls_to_other():
    r = CategoryResolver(lookup={})
    res = r.resolve("GENERAL_SERVICES")
    assert (res.category, res.origin) == ("Other", ORIGIN_DETERMINISTIC)


def test_resolve_unknown_raw_passthrough():
    r = CategoryResolver(lookup={})
    assert r.resolve("Weird Label").origin == ORIGIN_RAW
    assert r.resolve("Dining").origin == ORIGIN_EXPLICIT  # already canonical
    assert r.resolve(None).category is None


# --- Resolver: expense chain (mirrors CategoryMapping.resolve(expenseCategory:)) -------------------------


def test_resolve_expense_splitwise_taxonomy():
    r = CategoryResolver(lookup={})
    assert r.resolve_expense("Dining out").category == "Dining"
    assert r.resolve_expense("Gas/fuel").category == "Fuel"


def test_resolve_expense_owner_map_first():
    r = CategoryResolver(lookup={"Dining out": "Entertainment"})
    assert r.resolve_expense("Dining out").category == "Entertainment"


def test_resolve_expense_nil_and_empty():
    r = CategoryResolver(lookup={})
    assert r.resolve_expense(None).category is None
    assert r.resolve_expense("").category is None


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
