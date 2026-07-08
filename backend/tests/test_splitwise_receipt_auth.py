"""Splitwise receipt endpoints are group-scoped, not readable/triggerable by any authenticated caller.
DB-backed - calls the router functions directly with an explicit caller (no HTTP/JWT, no network: a group
member gets past the membership gate and then fails on the missing Splitwise token, which is enough to prove
the gate)."""
import uuid
from datetime import date
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete, select

from app import server_settings
from app.db import async_session
from app.models import BackendType, Expense, Group, GroupMember
from app.routers.splitwise import download_group_receipts, splitwise_receipt

TAG = "sw-rcpt-auth-zzz"
MEMBER = "sw-member"
OUTSIDER = "sw-outsider"


async def _seed() -> tuple[uuid.UUID, uuid.UUID]:
    async with async_session() as s:
        g = Group(name=TAG, backend_type=BackendType.self_hosted)
        s.add(g)
        await s.flush()
        s.add(GroupMember(group_id=g.id, user_identifier=MEMBER))
        e = Expense(group_id=g.id, description="Dinner", amount=Decimal("1.00"), currency="USD",
                    date=date(2026, 6, 1), splitwise_receipt_url="http://receipts.invalid/x")
        s.add(e)
        await s.commit()
        return g.id, e.id


async def _purge():
    async with async_session() as s:
        gids = (await s.scalars(select(Group.id).where(Group.name == TAG))).all()
        if gids:
            await s.execute(delete(Expense).where(Expense.group_id.in_(gids)))
            await s.execute(delete(GroupMember).where(GroupMember.group_id.in_(gids)))
            await s.execute(delete(Group).where(Group.id.in_(gids)))
        await s.commit()


async def test_splitwise_receipt_group_scoped():
    await _purge()
    _, expense_id = await _seed()
    try:
        # An outsider (not a group member) is rejected before any token/network work.
        async with async_session() as s:
            try:
                await splitwise_receipt(expense_id, size=None, caller=OUTSIDER, session=s)
                assert False, "expected 403 for a non-member"
            except HTTPException as e:
                assert e.status_code == 403
        # A member (and open/dev mode) passes the gate - then fails on the missing token, never 403.
        for caller in (MEMBER, None):
            async with async_session() as s:
                try:
                    await splitwise_receipt(expense_id, size=None, caller=caller, session=s)
                except HTTPException as e:
                    assert e.status_code != 403, f"caller {caller} should pass the group gate, got 403"
    finally:
        await _purge()


async def test_download_group_receipts_requires_membership():
    await _purge()
    group_id, _ = await _seed()
    async with async_session() as s:
        original = await server_settings.get(s, "splitwise_receipt_download_enabled")
    try:
        async with async_session() as s:
            await server_settings.set_value(s, "splitwise_receipt_download_enabled", True)
            await s.commit()
        # With the flow enabled, a non-member cannot trigger a group's receipt download.
        async with async_session() as s:
            try:
                await download_group_receipts(group_id, caller=OUTSIDER, session=s)
                assert False, "expected 403 for a non-member"
            except HTTPException as e:
                assert e.status_code == 403
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "splitwise_receipt_download_enabled", original)
            await s.commit()
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
