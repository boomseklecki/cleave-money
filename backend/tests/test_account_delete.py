"""Deleting an account (or unlinking a Plaid item) hard-deletes the linked transactions (+ their items/
overrides) rather than orphaning them with a null account_id. DB-backed; calls the handlers directly."""
from datetime import date
from decimal import Decimal

from sqlalchemy import func, select

from app.db import async_session
from app.models import (
    Account, PlaidItem, Transaction, TransactionItem, TransactionOverride, TransactionSource,
)
from app.routers.accounts import delete_account
from app.routers.plaid import delete_item

OWNER = "del-owner-zzz"


def _txn(account_id):
    return Transaction(account_id=account_id, source=TransactionSource.manual, description="x",
                       amount=Decimal("1.00"), currency="USD", date=date(2026, 3, 1), owner_identifier=OWNER)


async def _count(s, model, **where):
    stmt = select(func.count()).select_from(model)
    for k, v in where.items():
        stmt = stmt.where(getattr(model, k) == v)
    return await s.scalar(stmt)


async def test_delete_account_removes_its_transactions():
    async with async_session() as s:
        acct = Account(name="Manual zzz", owner_identifier=OWNER)
        s.add(acct); await s.flush()
        t = _txn(acct.id); s.add(t); await s.flush()
        s.add(TransactionItem(transaction_id=t.id, name="line", price=Decimal("1.00")))
        s.add(TransactionOverride(owner_identifier=OWNER, transaction_id=t.id, category="Dining"))
        await s.commit()
        aid, tid = acct.id, t.id

    async with async_session() as s:
        await delete_account(aid, caller=OWNER, session=s)

    async with async_session() as s:
        assert await _count(s, Account, id=aid) == 0
        assert await _count(s, Transaction, id=tid) == 0
        assert await _count(s, TransactionItem, transaction_id=tid) == 0      # cascaded
        assert await _count(s, TransactionOverride, transaction_id=tid) == 0  # cascaded


async def test_delete_item_removes_accounts_and_their_transactions():
    async with async_session() as s:
        item = PlaidItem(plaid_item_id="del-item-zzz", access_token="x", user_identifier=OWNER)
        s.add(item); await s.flush()
        acct = Account(name="Bank zzz", owner_identifier=OWNER, plaid_item_id=item.id,
                       plaid_account_id="del-acct-zzz")
        s.add(acct); await s.flush()
        t = _txn(acct.id); s.add(t)
        await s.commit()
        iid, aid, tid = item.id, acct.id, t.id

    async with async_session() as s:
        await delete_item(iid, caller=OWNER, session=s)

    async with async_session() as s:
        assert await _count(s, PlaidItem, id=iid) == 0
        assert await _count(s, Account, id=aid) == 0          # cascaded by the item
        assert await _count(s, Transaction, id=tid) == 0      # explicitly deleted (not orphaned)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
