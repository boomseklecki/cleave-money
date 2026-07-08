"""Pure mapping from normalized Splitwise dicts to Cleave row data.

No DB or network here, so every branch is unit-testable with plain dicts.
"""
from datetime import date, datetime
from decimal import Decimal

NON_GROUP_SENTINEL = "0"
NON_GROUP_NAME = "Non-group expenses"
SETTLEUP_CATEGORY = "Settle-up"

# Our canonical categories whose name differs from Splitwise's - map to the Splitwise (sub)category name so we
# can resolve a category_id when pushing. Names that already match (Groceries, Rent, Insurance, Entertainment,
# Utilities, Education, Gifts, Pets, Mortgage) resolve directly. Every alias here is symmetric with the import
# map (SplitwiseCategory: the target label resolves back to the same canonical), so push and re-import agree.
# Intentionally NOT mapped (push as Splitwise "General"): Subscriptions (a cross-cutting app concept, not a
# Splitwise category - its "TV/Phone/Internet" is rightly Utilities on import), Personal Care (no Splitwise
# category exists), Income/Transfer (neutral - no spend category), Other (General is correct).
_CATEGORY_ALIASES = {
    "dining": "dining out",
    "alcohol": "liquor",
    "fuel": "gas/fuel",
    "health": "medical expenses",
    "household": "household supplies",
    "transport": "car",
    "shopping": "clothing",
    "fees": "taxes",
    "travel": "hotel",
}


def resolve_category_id(category: str | None, name_to_id: dict[str, int]) -> int | None:
    """Map our category string to a Splitwise category_id via its taxonomy (`{name.lower(): id}`). Settle-ups
    push as payments, not a category. Unknown → None (Splitwise leaves it 'General')."""
    if not category or category == SETTLEUP_CATEGORY:
        return None
    key = category.strip().lower()
    return name_to_id.get(key) or name_to_id.get(_CATEGORY_ALIASES.get(key, ""))


def resolve_user_identifier(user_id: str, first_name: str, user_map: dict[str, str]) -> str:
    mapped = user_map.get(user_id)
    if mapped:
        return mapped
    name = (first_name or "").strip().lower()
    return name or f"swuser_{user_id}"


def expense_group_key(expense: dict) -> str:
    group_id = expense.get("group_id")
    return group_id if group_id else NON_GROUP_SENTINEL


def is_importable(expense: dict) -> bool:
    """Skip deleted expenses; everything else (incl. settle-ups) is imported."""
    return not expense.get("deleted_at")


def _parse_date(value) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value).replace("Z", "+00:00")
    return datetime.fromisoformat(text).date()


def _parse_datetime(value) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def build_group_rows(groups: list[dict], expenses: list[dict]) -> dict[str, str]:
    """Return {splitwise_group_id: name} for every group referenced by an expense."""
    rows = {g["splitwise_id"]: g["name"] for g in groups}
    for expense in expenses:
        if not is_importable(expense):
            continue
        key = expense_group_key(expense)
        if key == NON_GROUP_SENTINEL:
            rows.setdefault(NON_GROUP_SENTINEL, NON_GROUP_NAME)
        elif key not in rows:
            rows[key] = f"Splitwise group {key}"
    return rows


def map_expense(expense: dict, user_map: dict[str, str]) -> dict:
    """Map one Splitwise expense to expense fields + splits. Caller resolves group FK."""
    category = SETTLEUP_CATEGORY if expense.get("payment") else expense.get("category")
    created_by = expense.get("created_by")
    created_by_identifier = (
        resolve_user_identifier(created_by["user_id"], created_by.get("first_name", ""), user_map)
        if created_by else None
    )
    updated_by = expense.get("updated_by")
    updated_by_identifier = (
        resolve_user_identifier(updated_by["user_id"], updated_by.get("first_name", ""), user_map)
        if updated_by else None
    )
    splits = [
        {
            "user_identifier": resolve_user_identifier(
                u["user_id"], u.get("first_name", ""), user_map
            ),
            "paid_share": Decimal(str(u.get("paid_share", "0"))),
            "owed_share": Decimal(str(u.get("owed_share", "0"))),
        }
        for u in expense.get("users", [])
    ]
    return {
        "splitwise_expense_id": expense["splitwise_id"],
        "group_key": expense_group_key(expense),
        "description": expense.get("description", ""),
        "amount": Decimal(str(expense.get("cost", "0"))),
        "currency": expense.get("currency_code", "USD"),
        "date": _parse_date(expense.get("date")),
        "category": category,
        "created_by": created_by_identifier,
        "updated_by": updated_by_identifier,
        "splitwise_created_at": _parse_datetime(expense.get("created_at")),
        "splitwise_updated_at": _parse_datetime(expense.get("updated_at")),
        "notes": expense.get("notes") or None,
        "comments_count": expense.get("comments_count"),
        # Prefer the boolean; fall back to deriving from the (correctly-populated) interval so a re-sync
        # backfills recurrence even for rows imported while the boolean read was broken.
        "repeats": (
            expense["repeats"]
            if expense.get("repeats") is not None
            else (expense.get("repeat_interval") not in (None, "", "never"))
        ),
        "repeat_interval": expense.get("repeat_interval"),
        "expense_bundle_id": (
            str(expense["expense_bundle_id"]) if expense.get("expense_bundle_id") else None
        ),
        "splitwise_receipt_url": expense.get("receipt_url"),
        "repayments": expense.get("repayments") or None,
        "splits": splits,
    }
