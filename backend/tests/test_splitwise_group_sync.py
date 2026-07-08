"""The Splitwise group/expense/user upserts bump `updated_at` on the conflict path, so they track the last
sync - the freshness signal the app's smart-refresh thresholds + "Updated ... ago" read. DB-backed."""
import asyncio
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.splitwise.importer import _upsert_expense, _upsert_group, _upsert_user
from app.models import Expense, Group, User

SWID = "sw-grp-zzz"
SW_EXP_ID = "sw-exp-zzz"
SW_USER_IDENT = "swuser-zzz"


async def _cleanup(session):
    await session.execute(delete(Expense).where(Expense.splitwise_expense_id == SW_EXP_ID))
    await session.execute(delete(Group).where(Group.splitwise_group_id == SWID))
    await session.execute(delete(User).where(User.identifier == SW_USER_IDENT))
    await session.commit()


async def test_upsert_group_bumps_updated_at():
    async with async_session() as s:
        await _cleanup(s)
        try:
            gid = await _upsert_group(s, SWID, "Trip")
            await s.commit()
            first = await s.scalar(select(Group.updated_at).where(Group.id == gid))

            await asyncio.sleep(0.05)  # ensure a later transaction clock so now() advances
            await _upsert_group(s, SWID, "Trip")  # conflict → DO UPDATE
            await s.commit()
            second = await s.scalar(select(Group.updated_at).where(Group.id == gid))

            assert second > first  # the upsert advanced updated_at even though nothing changed
        finally:
            await _cleanup(s)


async def test_upsert_expense_bumps_updated_at():
    async with async_session() as s:
        await _cleanup(s)
        gid = await _upsert_group(s, SWID, "Trip")
        await s.commit()
        mapped = {"splitwise_expense_id": SW_EXP_ID, "description": "Dinner", "amount": Decimal("40.00"),
                  "currency": "USD", "date": date(2024, 1, 2), "category": "Dining", "splits": []}
        try:
            await _upsert_expense(s, mapped, gid)
            await s.commit()
            first = await s.scalar(select(Expense.updated_at).where(Expense.splitwise_expense_id == SW_EXP_ID))
            await asyncio.sleep(0.05)
            await _upsert_expense(s, mapped, gid)  # conflict → DO UPDATE
            await s.commit()
            second = await s.scalar(select(Expense.updated_at).where(Expense.splitwise_expense_id == SW_EXP_ID))
            assert second > first
        finally:
            await _cleanup(s)


async def test_upsert_user_bumps_updated_at():
    async with async_session() as s:
        await _cleanup(s)
        try:
            await _upsert_user(s, SW_USER_IDENT, "SW User", "sw-uid-zzz")
            await s.commit()
            first = await s.scalar(select(User.updated_at).where(User.identifier == SW_USER_IDENT))
            await asyncio.sleep(0.05)
            await _upsert_user(s, SW_USER_IDENT, "SW User", "sw-uid-zzz")  # conflict → DO UPDATE
            await s.commit()
            second = await s.scalar(select(User.updated_at).where(User.identifier == SW_USER_IDENT))
            assert second > first
        finally:
            await _cleanup(s)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
