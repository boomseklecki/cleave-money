"""Concurrent check-then-insert upserts resolve to ONE row instead of 500ing the loser (audit Medium #15).
add_member, the expense override upsert, and the group override upsert now insert inside a savepoint and
adopt the winner on IntegrityError. DB-backed; two real concurrent calls via asyncio.gather."""
import asyncio
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.db import async_session
from app.models import (
    BackendType, Expense, ExpenseOverride, Group, GroupMember, GroupOverride, Split,
)
from app.routers.expenses import update_expense_override
from app.routers.groups import add_member, update_group
from app.schemas.expense import ExpenseOverrideUpdate
from app.schemas.group import GroupUpdate
from app.schemas.group_member import GroupMemberCreate

CALLER = "conc-caller"
NEWGUY = "conc-newguy"


async def _purge():
    async with async_session() as s:
        gids = list(await s.scalars(select(Group.id).where(Group.name == "conc-grp")))
        if gids:
            await s.execute(delete(GroupOverride).where(GroupOverride.group_id.in_(gids)))
            await s.execute(delete(Group).where(Group.id.in_(gids)))  # cascades members/expenses/splits
        await s.execute(delete(ExpenseOverride).where(ExpenseOverride.owner_identifier == CALLER))
        await s.commit()


async def _seed_group_with_caller() -> "UUID":
    async with async_session() as s:
        g = Group(name="conc-grp", backend_type=BackendType.self_hosted)
        s.add(g); await s.flush()
        s.add(GroupMember(group_id=g.id, user_identifier=CALLER))
        await s.commit()
        return g.id


async def test_concurrent_add_member_resolves_to_one_row():
    await _purge()
    try:
        gid = await _seed_group_with_caller()

        async def _one():
            async with async_session() as s:
                return await add_member(gid, GroupMemberCreate(user_identifier=NEWGUY),
                                        caller=CALLER, session=s)
        await asyncio.gather(_one(), _one())  # must NOT 500 the loser
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(GroupMember).where(
                GroupMember.group_id == gid, GroupMember.user_identifier == NEWGUY))
            assert n == 1                                          # exactly one membership row
    finally:
        await _purge()


async def test_concurrent_group_override_resolves_to_one_row():
    await _purge()
    try:
        gid = await _seed_group_with_caller()

        async def _one():
            async with async_session() as s:
                return await update_group(gid, GroupUpdate(hidden=True), caller=CALLER, session=s)
        await asyncio.gather(_one(), _one())
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(GroupOverride).where(
                GroupOverride.owner_identifier == CALLER, GroupOverride.group_id == gid))
            assert n == 1
    finally:
        await _purge()


async def test_concurrent_expense_override_resolves_to_one_row():
    await _purge()
    try:
        gid = await _seed_group_with_caller()
        async with async_session() as s:
            e = Expense(group_id=gid, description="x", amount=Decimal("10.00"), currency="USD",
                        date=date(2026, 6, 1))
            e.splits = [Split(user_identifier=CALLER, paid_share=Decimal("10"), owed_share=Decimal("10"))]
            s.add(e); await s.commit()
            eid = e.id

        async def _one():
            async with async_session() as s:
                return await update_expense_override(
                    eid, ExpenseOverrideUpdate(include_in_spending=False), caller=CALLER, session=s)
        await asyncio.gather(_one(), _one())
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(ExpenseOverride).where(
                ExpenseOverride.owner_identifier == CALLER, ExpenseOverride.expense_id == eid))
            assert n == 1
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
