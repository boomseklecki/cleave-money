"""Plaid item listing/unlink and manual account/transaction creation."""
import json
import urllib.request

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.plaid import sync as plaid_sync
from app.models import Account, PlaidItem, Transaction

API = "http://localhost:8000"
ITEM = "items-test-zzz"
ACC = "items-acc-zzz"
TX = "items-tx-zzz"


def _req(method, path, data=None):
    headers = {}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=body, method=method, headers=headers)
    resp = urllib.request.urlopen(req)
    return resp.status, resp.read()


async def test_manual_account_and_transaction():
    account_id = None
    tx_id = None
    try:
        status, body = _req("POST", "/accounts", {"name": "Cash Wallet"})
        assert status == 201, (status, body)
        account_id = json.loads(body)["id"]
        assert any(a["id"] == account_id for a in json.loads(_req("GET", "/accounts")[1]))

        status, body = _req("POST", "/transactions", {
            "account_id": account_id,
            "description": "Lunch",
            "amount": "12.00",
            "date": "2023-04-01",
        })
        assert status == 201, (status, body)
        tx = json.loads(body)
        tx_id = tx["id"]
        assert tx["source"] == "manual"
        assert any(t["id"] == tx_id for t in json.loads(_req("GET", f"/transactions?account_id={account_id}")[1]))

        assert _req("DELETE", f"/transactions/{tx_id}")[0] == 204
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


async def _cleanup_plaid():
    async with async_session() as session:
        await session.execute(delete(Transaction).where(Transaction.plaid_transaction_id == TX))
        await session.execute(delete(Account).where(Account.plaid_account_id == ACC))
        await session.execute(delete(PlaidItem).where(PlaidItem.plaid_item_id == ITEM))
        await session.commit()


async def test_plaid_item_list_and_unlink():
    await _cleanup_plaid()
    try:
        async with async_session() as session:
            item = PlaidItem(plaid_item_id=ITEM, access_token="x", institution_name="Test Bank")
            session.add(item)
            await session.commit()
            await plaid_sync.apply_sync(
                session, item,
                [{"plaid_account_id": ACC, "name": "Checking", "type": "checking", "balance": "50.00", "currency": "USD"}],
                {"added": [{"plaid_transaction_id": TX, "plaid_account_id": ACC, "description": "x", "amount": "1.00", "currency": "USD", "date": "2023-01-01", "category": None, "pending": False}], "modified": [], "removed": [], "cursor": "c1"},
            )
            item_id = str(item.id)

        items = json.loads(_req("GET", "/plaid/items")[1])
        mine = next(i for i in items if i["id"] == item_id)
        assert mine["institution_name"] == "Test Bank"
        assert any(a["plaid_account_id"] == ACC for a in mine["accounts"])

        assert _req("DELETE", f"/plaid/items/{item_id}")[0] == 204

        async with async_session() as session:
            assert await session.scalar(select(PlaidItem).where(PlaidItem.plaid_item_id == ITEM)) is None
            assert await session.scalar(select(Account).where(Account.plaid_account_id == ACC)) is None
            # the item's accounts' transactions are hard-deleted too (no longer orphaned with account_id null)
            tx = await session.scalar(select(Transaction).where(Transaction.plaid_transaction_id == TX))
            assert tx is None
    finally:
        await _cleanup_plaid()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
