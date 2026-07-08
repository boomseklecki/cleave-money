from datetime import date
from decimal import Decimal

from app.integrations.splitwise import mapper


def _expense(**overrides) -> dict:
    base = {
        "splitwise_id": "1001",
        "group_id": "77",
        "description": "Dinner",
        "cost": "40.00",
        "currency_code": "USD",
        "date": "2023-05-01T12:00:00Z",
        "category": "Dining out",
        "payment": False,
        "deleted_at": None,
        "users": [
            {"user_id": "1", "first_name": "Alice", "paid_share": "40.00", "owed_share": "20.00"},
            {"user_id": "2", "first_name": "Bob", "paid_share": "0.00", "owed_share": "20.00"},
        ],
    }
    base.update(overrides)
    return base


def test_settle_up_tagged():
    out = mapper.map_expense(_expense(payment=True, category="Dining out"), {})
    assert out["category"] == "Settle-up"


def test_normal_category_kept():
    out = mapper.map_expense(_expense(category="Groceries"), {})
    assert out["category"] == "Groceries"


def test_deleted_skipped():
    assert mapper.is_importable(_expense(deleted_at=None)) is True
    assert mapper.is_importable(_expense(deleted_at="2023-06-01T00:00:00Z")) is False


def test_non_group_sentinel():
    exp = _expense(group_id=None)
    assert mapper.expense_group_key(exp) == mapper.NON_GROUP_SENTINEL
    rows = mapper.build_group_rows([], [exp])
    assert rows[mapper.NON_GROUP_SENTINEL] == mapper.NON_GROUP_NAME


def test_referenced_group_not_in_list():
    rows = mapper.build_group_rows([], [_expense(group_id="77")])
    assert rows["77"] == "Splitwise group 77"


def test_user_map_and_fallback():
    assert mapper.resolve_user_identifier("1", "Alice", {"1": "alice"}) == "alice"
    assert mapper.resolve_user_identifier("999", "Bob", {}) == "bob"
    assert mapper.resolve_user_identifier("5", "", {}) == "swuser_5"


def test_amount_and_splits_decimal():
    out = mapper.map_expense(_expense(), {"1": "alice", "2": "bob"})
    assert out["amount"] == Decimal("40.00")
    assert {s["user_identifier"] for s in out["splits"]} == {"alice", "bob"}
    alice = next(s for s in out["splits"] if s["user_identifier"] == "alice")
    assert alice["paid_share"] == Decimal("40.00")
    assert alice["owed_share"] == Decimal("20.00")
    assert sum(s["owed_share"] for s in out["splits"]) == Decimal("40.00")


def test_repeats_from_boolean_or_interval():
    # Trust the boolean when present...
    assert mapper.map_expense(_expense(repeats=True, repeat_interval="monthly"), {})["repeats"] is True
    assert mapper.map_expense(_expense(repeats=False, repeat_interval="monthly"), {})["repeats"] is False
    # ...else derive from the (correctly-populated) interval so a re-sync backfills recurrence.
    assert mapper.map_expense(_expense(repeats=None, repeat_interval="monthly"), {})["repeats"] is True
    assert mapper.map_expense(_expense(repeats=None, repeat_interval="never"), {})["repeats"] is False
    assert mapper.map_expense(_expense(repeats=None, repeat_interval=None), {})["repeats"] is False


def test_date_parsing():
    assert mapper.map_expense(_expense(date="2023-05-01T12:00:00Z"), {})["date"] == date(2023, 5, 1)
    assert mapper.map_expense(_expense(date="2023-05-01"), {})["date"] == date(2023, 5, 1)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
