"""Per-(owner, group) `hidden` override: set/clear via PATCH, scoped to the caller. DB-backed."""
import uuid

from sqlalchemy import delete, select

from app.db import async_session
from app.models import BackendType, Group, GroupMember, GroupOverride
from app.routers.groups import list_groups, update_group
from app.schemas.group import GroupUpdate


async def _make_group(session, members: list[str]) -> uuid.UUID:
    group = Group(name="Trip", backend_type=BackendType.self_hosted)
    session.add(group)
    await session.flush()
    for m in members:
        session.add(GroupMember(group_id=group.id, user_identifier=m))
    await session.commit()
    return group.id


async def _cleanup(session, group_id):
    await session.execute(delete(GroupOverride).where(GroupOverride.group_id == group_id))
    await session.execute(delete(GroupMember).where(GroupMember.group_id == group_id))
    await session.execute(delete(Group).where(Group.id == group_id))
    await session.commit()


async def _visible(session, caller, include_hidden=False) -> set[uuid.UUID]:
    rows = await list_groups(caller=caller, session=session, include_hidden=include_hidden)
    return {g.id for g in rows}


async def test_set_clear_and_scope():
    async with async_session() as s:
        group_id = await _make_group(s, ["alice", "bob"])
        try:
            # Both members see the group by default.
            assert group_id in await _visible(s, "alice")
            assert group_id in await _visible(s, "bob")

            # Alice hides it → an override row for alice, gone from her default list, back with include_hidden.
            await update_group(group_id, GroupUpdate(hidden=True), caller="alice", session=s)
            assert (await s.scalar(select(GroupOverride).where(
                GroupOverride.owner_identifier == "alice", GroupOverride.group_id == group_id))) is not None
            assert group_id not in await _visible(s, "alice")
            assert group_id in await _visible(s, "alice", include_hidden=True)

            # Per-user: bob still sees it (his view is unaffected).
            assert group_id in await _visible(s, "bob")

            # Unhide (hidden=False is the default) → the row is deleted and the group reappears.
            await update_group(group_id, GroupUpdate(hidden=False), caller="alice", session=s)
            assert (await s.scalar(select(GroupOverride).where(
                GroupOverride.group_id == group_id))) is None
            assert group_id in await _visible(s, "alice")
        finally:
            await _cleanup(s, group_id)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
