"""update_expense pushes to Splitwise BEFORE mutating/flushing the tracked expense (audit High #8) - so the
writer's autoflush can't take row locks that would then be held across the blocking Splitwise HTTP call. Two
guarantees are asserted here:
  1. the pushed payload reflects the EDITED state (the detached snapshot carries the edit, even pre-mutation);
  2. an HTTP failure raises 502 with the local row left UNCHANGED (push-first: nothing mutated/committed).
The Splitwise SDK is monkeypatched - no network.
"""
from datetime import date
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.splitwise import client as sw_client
from app.models import BackendType, Expense, Group, GroupMember, Split, SplitwiseToken, User
from app.models.enums import UserSource
from app.routers.expenses import update_expense
from app.schemas.expense import ExpenseUpdate, SplitInput

CALLER = "pushord-alice"
PARTNER = "pushord-bob"
SWGID = "99000500"  # numeric: build_payload does int(splitwise_group_id)


async def _purge():
    async with async_session() as s:
        gids = list(await s.scalars(select(Group.id).where(Group.splitwise_group_id == SWGID)))
        if gids:
            await s.execute(delete(Group).where(Group.id.in_(gids)))  # cascades expenses/splits
        await s.execute(delete(GroupMember).where(GroupMember.user_identifier.in_([CALLER, PARTNER])))
        await s.execute(delete(User).where(User.identifier.in_([CALLER, PARTNER])))
        await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == CALLER))
        await s.commit()


async def _seed():
    """A Splitwise-linked group with a stamped expense; CALLER is a member with a Splitwise token, and both
    participants carry splitwise_user_ids so the payload resolves."""
    async with async_session() as s:
        s.add(User(identifier=CALLER, display_name="M", source=UserSource.app, splitwise_user_id="11"))
        s.add(User(identifier=PARTNER, display_name="N", source=UserSource.splitwise, splitwise_user_id="22"))
        g = Group(name="pushord-g", backend_type=BackendType.splitwise, splitwise_group_id=SWGID)
        s.add(g)
        await s.flush()
        s.add(GroupMember(group_id=g.id, user_identifier=CALLER))
        s.add(SplitwiseToken(user_identifier=CALLER, access_token="x"))
        e = Expense(group_id=g.id, description="Dinner", amount=Decimal("40.00"), currency="USD",
                    date=date(2023, 1, 1), splitwise_expense_id="sw-existing")
        e.splits = [Split(user_identifier=CALLER, paid_share=Decimal("40"), owed_share=Decimal("20")),
                    Split(user_identifier=PARTNER, paid_share=Decimal("0"), owed_share=Decimal("20"))]
        s.add(e)
        await s.commit()
        return e.id


def _stub_splitwise(update_fn):
    """Patch the three SDK entry points update_expense touches; return the originals to restore."""
    orig = (sw_client.make_client, sw_client.category_name_to_id, sw_client.update_expense)
    sw_client.make_client = lambda token: object()
    sw_client.category_name_to_id = lambda client: {}   # no category HTTP
    sw_client.update_expense = update_fn
    return orig


def _restore(orig):
    sw_client.make_client, sw_client.category_name_to_id, sw_client.update_expense = orig


async def test_push_payload_reflects_edited_state():
    await _purge()
    captured = {}

    def fake_update(client, sw_id, payload):
        captured["id"] = sw_id
        captured["payload"] = payload
        return sw_id

    orig = _stub_splitwise(fake_update)
    try:
        eid = await _seed()
        async with async_session() as s:
            await update_expense(
                eid,
                ExpenseUpdate(amount=Decimal("60.00"), splits=[
                    SplitInput(user_identifier=CALLER, paid_share=Decimal("60"), owed_share=Decimal("30")),
                    SplitInput(user_identifier=PARTNER, paid_share=Decimal("0"), owed_share=Decimal("30"))]),
                caller=CALLER, session=s)
        # The payload pushed to Splitwise carries the NEW amount + splits - proving the pre-mutation snapshot
        # reflects the edit (not the stale pre-edit ORM state).
        assert captured["id"] == "sw-existing"
        assert captured["payload"]["cost"] == "60.00"
        owed = {u["user_id"]: u["owed_share"] for u in captured["payload"]["users"]}
        assert owed == {"11": "30", "22": "30"}   # str(Decimal("30")) from the edited splits
        # And the local row was updated after the successful push.
        async with async_session() as s:
            row = await s.get(Expense, eid)
            assert row.amount == Decimal("60.00")
    finally:
        _restore(orig)
        await _purge()


async def test_push_failure_leaves_local_row_unchanged():
    await _purge()

    def boom(client, sw_id, payload):
        raise RuntimeError("splitwise 500")

    orig = _stub_splitwise(boom)
    try:
        eid = await _seed()
        async with async_session() as s:
            try:
                await update_expense(eid, ExpenseUpdate(amount=Decimal("99.00")), caller=CALLER, session=s)
                assert False, "expected the push failure to raise"
            except HTTPException as exc:
                assert exc.status_code == 502
        # Push-first: the edit was never applied because mutations happen only after a successful push.
        async with async_session() as s:
            row = await s.get(Expense, eid)
            assert row.amount == Decimal("40.00")   # unchanged
    finally:
        _restore(orig)
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
