"""Per-user include-in-spending / include-in-cash-flow overrides on expenses and groups: set/clear via the
router, scoped to the caller, never touching the shared row. DB-backed (calls the router fns directly)."""
import uuid
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.models import (
    BackendType,
    Expense,
    ExpenseOverride,
    Group,
    GroupMember,
    GroupOverride,
)
from app.routers.expenses import update_expense_override
from app.routers.groups import _attach_group_overrides, update_group
from app.schemas.expense import ExpenseOverrideUpdate
from app.schemas.group import GroupUpdate

CALLER = "inc-alice"
OTHER = "inc-bob"


async def _seed() -> tuple[uuid.UUID, uuid.UUID]:
    async with async_session() as s:
        group = Group(name="inc-grp", backend_type=BackendType.self_hosted)
        s.add(group)
        await s.flush()
        s.add(GroupMember(group_id=group.id, user_identifier=CALLER))
        s.add(GroupMember(group_id=group.id, user_identifier=OTHER))
        expense = Expense(group_id=group.id, description="x", amount=Decimal("10.00"), currency="USD",
                          date=date(2026, 6, 1))
        s.add(expense)
        await s.commit()
        return group.id, expense.id


async def _cleanup(group_id, expense_id):
    async with async_session() as s:
        await s.execute(delete(ExpenseOverride).where(ExpenseOverride.expense_id == expense_id))
        await s.execute(delete(GroupOverride).where(GroupOverride.group_id == group_id))
        await s.execute(delete(Group).where(Group.id == group_id))  # cascades members + expense
        await s.commit()


async def test_expense_override_set_clear_and_scoped():
    group_id, expense_id = await _seed()
    try:
        async with async_session() as s:
            e = await update_expense_override(
                expense_id, ExpenseOverrideUpdate(include_in_spending=False), caller=CALLER, session=s)
            assert e.include_in_spending is False
        # A different caller sees the default (no override).
        async with async_session() as s:
            from app.routers.expenses import _load_detail
            other = await _load_detail(s, expense_id, OTHER)
            assert other.include_in_spending is None
        # Clearing every field drops the row.
        async with async_session() as s:
            await update_expense_override(
                expense_id, ExpenseOverrideUpdate(include_in_spending=None), caller=CALLER, session=s)
            assert (await s.scalar(select(ExpenseOverride).where(
                ExpenseOverride.expense_id == expense_id))) is None
    finally:
        await _cleanup(group_id, expense_id)


async def test_group_include_override_coexists_with_hidden():
    group_id, expense_id = await _seed()
    try:
        async with async_session() as s:
            await update_group(group_id, GroupUpdate(include_in_spending=False, hidden=True),
                               caller=CALLER, session=s)
        async with async_session() as s:
            group = await s.get(Group, group_id)
            await _attach_group_overrides(s, CALLER, [group])
            assert group.include_in_spending is False and group.hidden is True
        # Unhide (hidden=False clears just that field); the include flag persists.
        async with async_session() as s:
            await update_group(group_id, GroupUpdate(hidden=False), caller=CALLER, session=s)
        async with async_session() as s:
            group = await s.get(Group, group_id)
            await _attach_group_overrides(s, CALLER, [group])
            assert group.hidden is False and group.include_in_spending is False
            assert (await s.scalar(select(GroupOverride).where(
                GroupOverride.group_id == group_id))) is not None
    finally:
        await _cleanup(group_id, expense_id)


async def test_expense_note_set_readback_scoped_and_clear():
    group_id, expense_id = await _seed()
    try:
        from app.routers.expenses import _load_detail
        async with async_session() as s:
            e = await update_expense_override(
                expense_id, ExpenseOverrideUpdate(note="Birthday dinner for Sam"), caller=CALLER, session=s)
            assert e.note == "Birthday dinner for Sam"
        # Per-user: another member sees no note.
        async with async_session() as s:
            assert (await _load_detail(s, expense_id, OTHER)).note is None
        # Blank clears the note-only row.
        async with async_session() as s:
            await update_expense_override(
                expense_id, ExpenseOverrideUpdate(note="  "), caller=CALLER, session=s)
            assert (await _load_detail(s, expense_id, CALLER)).note is None
            assert (await s.scalar(select(ExpenseOverride).where(
                ExpenseOverride.expense_id == expense_id))) is None
    finally:
        await _cleanup(group_id, expense_id)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
