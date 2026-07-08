"""Transaction line items: PUT upsert-by-id, GET returns items, transaction delete cascades them."""
import json
import urllib.request

from sqlalchemy import delete, select

from app.db import async_session
from app.models import Account, Transaction, TransactionItem

API = "http://localhost:8000"


def _req(method, path, data=None):
    headers = {}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=body, method=method, headers=headers)
    resp = urllib.request.urlopen(req)
    return resp.status, resp.read()


async def test_transaction_items_roundtrip_and_cascade():
    account_id = None
    tx_id = None
    try:
        account_id = json.loads(_req("POST", "/accounts", {"name": "Cash Wallet"})[1])["id"]
        status, body = _req("POST", "/transactions", {
            "account_id": account_id, "description": "Target", "amount": "100.00", "date": "2026-06-01",
        })
        assert status == 201, (status, body)
        tx = json.loads(body)
        tx_id = tx["id"]
        assert tx["items"] == []  # a fresh transaction has no items

        # PUT two items.
        status, body = _req("PUT", f"/transactions/{tx_id}/items", [
            {"name": "Milk", "price": "40.00", "category": "Groceries"},
            {"name": "Soap", "price": "30.00", "category": "Household"},
        ])
        assert status == 200, (status, body)
        items = json.loads(body)["items"]
        assert {i["name"] for i in items} == {"Milk", "Soap"}
        assert {i["category"] for i in items} == {"Groceries", "Household"}

        # GET reflects the items.
        got = json.loads(_req("GET", f"/transactions/{tx_id}")[1])
        assert len(got["items"]) == 2

        # PUT again: keep Milk (by id, recategorized), drop Soap, add Bread → upsert by id + drop-orphan.
        milk = next(i for i in items if i["name"] == "Milk")
        status, body = _req("PUT", f"/transactions/{tx_id}/items", [
            {"id": milk["id"], "name": "Milk", "price": "40.00", "category": "Snacks"},
            {"name": "Bread", "price": "5.00", "category": "Groceries"},
        ])
        assert status == 200, (status, body)
        items2 = json.loads(body)["items"]
        assert {i["name"] for i in items2} == {"Milk", "Bread"}
        kept = next(i for i in items2 if i["name"] == "Milk")
        assert kept["id"] == milk["id"]          # identity preserved
        assert kept["category"] == "Snacks"      # recategorized

        # Deleting the transaction cascades its items.
        assert _req("DELETE", f"/transactions/{tx_id}")[0] == 204
        async with async_session() as session:
            remaining = await session.scalars(
                select(TransactionItem).where(TransactionItem.transaction_id == tx_id)
            )
            assert list(remaining) == []
        tx_id = None
        assert _req("DELETE", f"/accounts/{account_id}")[0] == 204
        account_id = None
    finally:
        if tx_id or account_id:
            async with async_session() as session:
                if tx_id:
                    await session.execute(delete(Transaction).where(Transaction.id == tx_id))
                if account_id:
                    await session.execute(delete(Account).where(Account.id == account_id))
                await session.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
