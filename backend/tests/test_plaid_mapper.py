from datetime import date
from decimal import Decimal

from app.integrations.plaid import mapper


def test_map_account():
    out = mapper.map_account(
        {"plaid_account_id": "a1", "name": "Checking", "type": "checking", "balance": "100.50", "currency": "USD"}
    )
    assert out["plaid_account_id"] == "a1"
    assert out["name"] == "Checking"
    assert out["balance"] == Decimal("100.50")


def test_map_account_defaults():
    out = mapper.map_account(
        {"plaid_account_id": "a1", "name": None, "type": None, "balance": None, "currency": None}
    )
    assert out["name"] == "Account"
    assert out["balance"] == Decimal("0")
    assert out["currency"] == "USD"


def test_map_transaction_string_date():
    out = mapper.map_transaction(
        {
            "plaid_transaction_id": "t1",
            "plaid_account_id": "a1",
            "description": "Coffee",
            "amount": "4.50",
            "currency": "USD",
            "date": "2023-03-01",
            "category": "Food",
            "pending": False,
        }
    )
    assert out["amount"] == Decimal("4.50")
    assert out["date"] == date(2023, 3, 1)
    assert out["pending"] is False
    assert out["category"] == "Food"


def test_map_transaction_date_object_and_negative_amount():
    out = mapper.map_transaction(
        {
            "plaid_transaction_id": "t2",
            "plaid_account_id": "a1",
            "description": "Refund",
            "amount": "-20.00",
            "currency": "USD",
            "date": date(2023, 3, 2),
            "category": None,
            "pending": True,
        }
    )
    assert out["amount"] == Decimal("-20.00")  # inflow kept negative, not flipped
    assert out["date"] == date(2023, 3, 2)
    assert out["pending"] is True


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
