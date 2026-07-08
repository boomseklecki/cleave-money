"""The Plaid account + transaction upserts bump `updated_at` on the conflict path, so the app's "Updated ...
ago" tracks the last sync (not just the last real change). DB-backed."""
import asyncio
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.plaid.sync import _upsert_account, _upsert_transaction
from app.models import Account, PlaidItem, Transaction

PLAID_ITEM_ID = "pi-zzz-acct"
PLAID_ACCOUNT_ID = "pa-zzz-1"
PLAID_TXN_ID = "ptx-zzz-1"
OWNER = "acctowner-zzz"


async def _cleanup(session):
    await session.execute(delete(Transaction).where(Transaction.plaid_transaction_id == PLAID_TXN_ID))
    await session.execute(delete(Account).where(Account.plaid_account_id == PLAID_ACCOUNT_ID))
    await session.execute(delete(PlaidItem).where(PlaidItem.plaid_item_id == PLAID_ITEM_ID))
    await session.commit()


async def test_upsert_account_bumps_updated_at():
    async with async_session() as s:
        await _cleanup(s)
        item = PlaidItem(plaid_item_id=PLAID_ITEM_ID, access_token="x", user_identifier=OWNER)
        s.add(item)
        await s.commit()
        await s.refresh(item)
        fields = {"plaid_account_id": PLAID_ACCOUNT_ID, "name": "Checking", "type": "depository",
                  "mask": "1234", "balance": Decimal("10.00"), "available_balance": None, "currency": "USD"}
        try:
            account_id, _, _ = await _upsert_account(s, item.id, fields, owner_identifier=OWNER)
            await s.commit()
            first = await s.scalar(select(Account.updated_at).where(Account.id == account_id))

            await asyncio.sleep(0.05)  # ensure a later transaction clock so now() advances
            await _upsert_account(s, item.id, fields, owner_identifier=OWNER)  # conflict → DO UPDATE
            await s.commit()
            second = await s.scalar(select(Account.updated_at).where(Account.id == account_id))

            assert second > first  # the upsert advanced updated_at even though no field changed
        finally:
            await _cleanup(s)


async def test_upsert_transaction_bumps_updated_at():
    async with async_session() as s:
        await _cleanup(s)
        item = PlaidItem(plaid_item_id=PLAID_ITEM_ID, access_token="x", user_identifier=OWNER)
        s.add(item)
        await s.commit()
        await s.refresh(item)
        acct_id, _, _ = await _upsert_account(
            s, item.id, {"plaid_account_id": PLAID_ACCOUNT_ID, "name": "Checking", "type": "depository",
                         "mask": "1234", "balance": Decimal("10.00"), "available_balance": None, "currency": "USD"}, owner_identifier=OWNER)
        await s.commit()
        account_map = {PLAID_ACCOUNT_ID: acct_id}
        txn = {"plaid_account_id": PLAID_ACCOUNT_ID, "plaid_transaction_id": PLAID_TXN_ID,
               "description": "Coffee", "amount": Decimal("4.50"), "currency": "USD",
               "date": date(2024, 1, 2), "category": "Dining", "pending": False}
        try:
            await _upsert_transaction(s, account_map, txn, owner_identifier=OWNER)
            await s.commit()
            first = await s.scalar(select(Transaction.updated_at)
                                   .where(Transaction.plaid_transaction_id == PLAID_TXN_ID))

            await asyncio.sleep(0.05)
            await _upsert_transaction(s, account_map, txn, owner_identifier=OWNER)  # conflict → DO UPDATE
            await s.commit()
            second = await s.scalar(select(Transaction.updated_at)
                                    .where(Transaction.plaid_transaction_id == PLAID_TXN_ID))

            assert second > first  # the upsert advanced updated_at even though no field changed
        finally:
            await _cleanup(s)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
