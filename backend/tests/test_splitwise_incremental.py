"""Incremental Splitwise sync: delta upsert, idempotency, deletion archiving, cursor stamping.

`sw_client.fetch_expenses` is monkeypatched (no live Splitwise); everything else hits the real DB.
"""
from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.splitwise import client as c
from app.integrations.splitwise import importer
from app.models import Expense, Group, Split, SplitwiseToken, User
from app.routers.splitwise import sync_expenses as sync_expenses_endpoint
from app.schemas.splitwise import SyncRequest

GROUP_KEY = "sync-grp-zzz"
EXP_KEY = "sync-exp-zzz"
SWIDS = ["9001", "9002"]
TOKEN_USER = "synctok"


def _expense(splitwise_id, *, deleted=False, desc="sync expense"):
    return {
        "splitwise_id": splitwise_id,
        "group_id": GROUP_KEY,
        "description": desc,
        "cost": "10.00",
        "currency_code": "USD",
        "date": "2023-01-15T00:00:00Z",
        "category": "Groceries",
        "payment": False,
        "deleted_at": "2023-02-01T00:00:00Z" if deleted else None,
        "receipt_url": None,
        "repayments": None,
        "users": [
            {"user_id": "9001", "first_name": "SyncA", "paid_share": "10.00", "owed_share": "5.00"},
            {"user_id": "9002", "first_name": "SyncB", "paid_share": "0.00", "owed_share": "5.00"},
        ],
    }


async def _purge():
    async with async_session() as session:
        exp_ids = (
            await session.scalars(
                select(Expense.id).where(Expense.splitwise_expense_id == EXP_KEY)
            )
        ).all()
        if exp_ids:
            await session.execute(delete(Split).where(Split.expense_id.in_(exp_ids)))
        await session.execute(delete(Expense).where(Expense.splitwise_expense_id == EXP_KEY))
        await session.execute(delete(Group).where(Group.splitwise_group_id == GROUP_KEY))
        await session.execute(delete(User).where(User.splitwise_user_id.in_(SWIDS)))
        await session.execute(
            delete(SplitwiseToken).where(SplitwiseToken.user_identifier == TOKEN_USER)
        )
        await session.commit()


async def test_incremental_upsert_is_idempotent():
    await _purge()
    original = c.fetch_expenses
    c.fetch_expenses = lambda client, **kw: [_expense(EXP_KEY)]
    try:
        async with async_session() as session:
            stats = await importer.sync_expenses(
                session, object(), {}, updated_after="2023-01-01T00:00:00Z"
            )
            assert stats["imported"] == 1
            assert stats["expenses_fetched"] == 1
            # re-running the same delta produces no duplicate
            await importer.sync_expenses(session, object(), {}, updated_after="2023-01-01T00:00:00Z")
        async with async_session() as session:
            count = await session.scalar(
                select(func.count()).select_from(Expense).where(
                    Expense.splitwise_expense_id == EXP_KEY
                )
            )
            assert count == 1
    finally:
        c.fetch_expenses = original
        await _purge()


async def test_deletion_removes_locally():
    await _purge()
    original = c.fetch_expenses
    try:
        c.fetch_expenses = lambda client, **kw: [_expense(EXP_KEY)]
        async with async_session() as session:
            await importer.sync_expenses(session, object(), {}, updated_after=None)
        # Splitwise now reports the expense deleted -> hard-delete the local row
        c.fetch_expenses = lambda client, **kw: [_expense(EXP_KEY, deleted=True)]
        async with async_session() as session:
            stats = await importer.sync_expenses(
                session, object(), {}, updated_after="2023-02-01T00:00:00Z"
            )
            assert stats["deleted"] == 1
            assert stats["imported"] == 0
        async with async_session() as session:
            row = await session.scalar(
                select(Expense.id).where(Expense.splitwise_expense_id == EXP_KEY)
            )
            assert row is None  # gone, not archived
    finally:
        c.fetch_expenses = original
        await _purge()


async def test_sync_expenses_endpoint_stamps_cursor():
    await _purge()
    async with async_session() as session:
        session.add(SplitwiseToken(user_identifier=TOKEN_USER, access_token="x"))
        await session.commit()
    original = c.fetch_expenses
    c.fetch_expenses = lambda client, **kw: []
    try:
        async with async_session() as session:
            result = await sync_expenses_endpoint(SyncRequest(as_user=TOKEN_USER), caller=None, session=session)
            assert result.cursor is not None
        async with async_session() as session:
            stamped = await session.scalar(
                select(SplitwiseToken.expenses_synced_at).where(
                    SplitwiseToken.user_identifier == TOKEN_USER
                )
            )
            assert stamped is not None
    finally:
        c.fetch_expenses = original
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
