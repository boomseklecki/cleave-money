"""Cross-backend expense move + delete propagation (audit Criticals #1, #2).

Moving a Splitwise-stamped expense OUT of its Splitwise group, or deleting one that sits in a self-hosted
group, must delete the Splitwise copy and (for the move) clear splitwise_expense_id - otherwise the next
sync re-matches by id and resurrects/reverts it. Splitwise is stubbed (push_delete recorded, no live call).
"""
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import writer as sw_writer
from app.models import BackendType, Expense, Group, GroupMember, Split, SplitwiseToken
from app.routers.expenses import delete_expense, update_expense
from app.schemas.expense import ExpenseUpdate

MOVER = "mover-zzz"


async def _purge():
    async with async_session() as s:
        gids = list(await s.scalars(
            select(GroupMember.group_id).where(GroupMember.user_identifier == MOVER)))
        if gids:
            await s.execute(delete(Group).where(Group.id.in_(gids)))  # cascades expenses/splits
        await s.execute(delete(GroupMember).where(GroupMember.user_identifier == MOVER))
        await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == MOVER))
        await s.commit()


class _DeleteRecorder:
    def __init__(self):
        self.ids: list[str] = []

    async def __call__(self, client, sw_id):
        self.ids.append(sw_id)


async def _seed(group_backend: BackendType, sw_group_id: str | None, swid: str | None):
    """A group of the given backend + a self-hosted destination + a stamped expense; MOVER is a member of
    both and has a Splitwise token so select_token resolves."""
    async with async_session() as s:
        src = Group(name="src", backend_type=group_backend, splitwise_group_id=sw_group_id)
        dst = Group(name="dst", backend_type=BackendType.self_hosted)
        s.add_all([src, dst])
        await s.flush()
        s.add_all([GroupMember(group_id=src.id, user_identifier=MOVER),
                   GroupMember(group_id=dst.id, user_identifier=MOVER),
                   SplitwiseToken(user_identifier=MOVER, access_token="x")])
        e = Expense(group_id=src.id, description="Dinner", amount=Decimal("10.00"), currency="USD",
                    date=date(2023, 1, 1), splitwise_expense_id=swid,
                    splits=[Split(user_identifier=MOVER, paid_share=Decimal("10"), owed_share=Decimal("10"))])
        s.add(e)
        await s.commit()
        return e.id, dst.id


async def test_move_out_of_splitwise_deletes_and_clears_id():
    await _purge()
    rec = _DeleteRecorder()
    orig = (sw_writer.push_delete, sw_client.make_client)
    sw_writer.push_delete = rec
    sw_client.make_client = lambda token: object()
    try:
        eid, dst_id = await _seed(BackendType.splitwise, "g-zzz", "swexp-zzz")
        async with async_session() as s:
            await update_expense(eid, ExpenseUpdate(group_id=dst_id), caller=MOVER, session=s)
        assert rec.ids == ["swexp-zzz"]                       # Splitwise copy deleted
        async with async_session() as s:
            row = await s.get(Expense, eid)
            assert row.splitwise_expense_id is None            # id cleared -> won't resurrect on sync
            assert row.group_id == dst_id                      # move persisted
    finally:
        sw_writer.push_delete, sw_client.make_client = orig
        await _purge()


async def test_delete_stamped_expense_in_selfhosted_group_propagates():
    await _purge()
    rec = _DeleteRecorder()
    orig = (sw_writer.push_delete, sw_client.make_client)
    sw_writer.push_delete = rec
    sw_client.make_client = lambda token: object()
    try:
        # A stamped expense that sits in a SELF-HOSTED group (no splitwise_group_id) must still propagate.
        eid, _ = await _seed(BackendType.self_hosted, None, "swexp-stale-zzz")
        async with async_session() as s:
            await delete_expense(eid, propagate=None, caller=MOVER, session=s)
        assert rec.ids == ["swexp-stale-zzz"]                 # propagated despite the self-hosted group
        async with async_session() as s:
            assert await s.get(Expense, eid) is None           # hard-deleted locally
    finally:
        sw_writer.push_delete, sw_client.make_client = orig
        await _purge()


async def test_delete_local_only_expense_does_not_propagate():
    await _purge()
    rec = _DeleteRecorder()
    orig = sw_writer.push_delete
    sw_writer.push_delete = rec
    try:
        eid, _ = await _seed(BackendType.self_hosted, None, None)  # no splitwise_expense_id
        async with async_session() as s:
            await delete_expense(eid, propagate=None, caller=MOVER, session=s)
        assert rec.ids == []                                   # nothing to propagate
        async with async_session() as s:
            assert await s.get(Expense, eid) is None
    finally:
        sw_writer.push_delete = orig
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
