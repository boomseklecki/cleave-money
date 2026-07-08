"""SimpleFIN mapper: amount-sign inversion, currency guard, epoch->date, truncation, org branding."""
from datetime import date
from decimal import Decimal

from app.integrations.simplefin import mapper


def test_amount_is_negated():
    # SimpleFIN + = deposit/inflow -> Cleave - (inflow); SimpleFIN - = withdrawal -> Cleave + (outflow/spend).
    assert mapper.map_transaction({"id": "t1", "amount": "100.00", "posted": 0})["amount"] == Decimal("-100.00")
    assert mapper.map_transaction({"id": "t2", "amount": "-40.00", "posted": 0})["amount"] == Decimal("40.00")


def test_account_currency_guard():
    assert mapper.map_account({"id": "a", "currency": "usd"})["currency"] == "USD"          # normalized
    assert mapper.map_account({"id": "a", "currency": "https://x/y"})["currency"] == "USD"   # URL -> USD
    assert mapper.map_account({"id": "a", "currency": "EUR"})["currency"] == "EUR"
    assert mapper.map_account({"id": "a"})["currency"] == "USD"                              # missing -> USD


def test_epoch_to_date_prefers_transacted_at():
    # 1677628800 = 2023-03-01T00:00:00Z
    assert mapper.map_transaction({"id": "t", "amount": "1", "posted": 1677628800})["date"] == date(2023, 3, 1)
    tx = {"id": "t", "amount": "1", "posted": 0, "transacted_at": 1677628800}  # transacted_at wins over posted
    assert mapper.map_transaction(tx)["date"] == date(2023, 3, 1)


def test_truncation_dedup_key_and_org_branding():
    acct = mapper.map_account({"id": "a", "name": "N" * 300,
                               "org": {"name": "Chase", "domain": "chase.com"}})
    assert len(acct["name"]) == 255
    assert acct["institution_name"] == "Chase" and acct["institution_domain"] == "chase.com"
    assert acct["simplefin_account_id"] == "a"
    txn = mapper.map_transaction({"id": "t", "amount": "1", "posted": 0, "description": "D" * 600})
    assert len(txn["description"]) == 512
    assert txn["external_transaction_id"] == "t"  # SimpleFIN id -> our per-account dedup key


def test_balance_and_available():
    a = mapper.map_account({"id": "a", "balance": "12.34", "available-balance": "5.00"})
    assert a["balance"] == Decimal("12.34") and a["available_balance"] == Decimal("5.00")
    assert mapper.map_account({"id": "a"})["balance"] == Decimal("0")
    assert mapper.map_account({"id": "a"})["available_balance"] is None


def test_maps_org_through_catalog_and_extracts_mask():
    a = mapper.map_account({"id": "a", "name": "Chase Checking x1234",
                            "org": {"name": "Chase", "domain": "chase.com"}})
    assert a["institution_name"] == "Chase" and a["institution_domain"] == "chase.com"  # canonical from catalog
    assert a["mask"] == "1234"
    # An org not in the catalog falls back to SimpleFIN's raw values, and a name with no mask -> no mask.
    b = mapper.map_account({"id": "b", "name": "My Wallet",
                            "org": {"name": "Weird Bank", "domain": "wb.example"}})
    assert b["institution_name"] == "Weird Bank" and b["institution_domain"] == "wb.example"
    assert b["mask"] is None


def test_mask_requires_an_indicator():
    assert mapper._mask("Checking x1234") == "1234"
    assert mapper._mask("Savings ...5678") == "5678"
    assert mapper._mask("ending in 7777") == "7777"
    assert mapper._mask("Total Checking") is None       # no digits at all
    assert mapper._mask("Founded 2019 Fund") is None    # a bare year, no mask indicator -> not a false mask


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
