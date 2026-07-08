"""Two-way Splitwise group management: create / delete / restore / add-member / remove-member propagate to
Splitwise (wrappers monkeypatched, no live calls); self-hosted groups stay local. DB-backed."""
from datetime import date, datetime, timezone
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.splitwise import client as c
from app.models import BackendType, Expense, Group, GroupMember, Split, SplitwiseToken, User
from app.routers.groups import (
    add_member,
    create_group,
    delete_group,
    list_deleted_groups,
    remove_member,
    restore_group,
)
from app.schemas.group import GroupCreate
from app.schemas.group_member import GroupMemberCreate

SWID = "gm-sw-9100"
TOKEN_USER = "gmtok"
NEW_SWID = "gm-sw-new"


def _group_dict(sw_id, name="GM Trip", members=None):
    return {
        "splitwise_id": sw_id, "name": name, "group_type": "trip",
        "avatar_url": None, "cover_photo_url": None, "members": members or [],
    }


def _member(uid, first="Mem", email=None):
    return {"user_id": uid, "first_name": first, "last_name": "", "email": email,
            "picture": None, "registration_status": "confirmed"}


def _record(calls, key, value, ret):
    """Record a mock call and return `ret` (lambdas can't assign)."""
    calls[key] = value
    return ret


async def _purge():
    async with async_session() as s:
        for swid in (SWID, NEW_SWID):
            gid = await s.scalar(select(Group.id).where(Group.splitwise_group_id == swid))
            if gid:
                await s.execute(delete(GroupMember).where(GroupMember.group_id == gid))
                await s.execute(delete(Expense).where(Expense.group_id == gid))
                await s.execute(delete(Group).where(Group.id == gid))
        await s.execute(delete(Group).where(Group.name == "GM Local"))
        await s.execute(delete(User).where(User.splitwise_user_id.in_(["8001", "8002"])))
        await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == TOKEN_USER))
        await s.commit()


async def _seed_token():
    async with async_session() as s:
        s.add(SplitwiseToken(user_identifier=TOKEN_USER, access_token="x"))
        await s.commit()


async def _seed_sw_group(members=None):
    async with async_session() as s:
        g = Group(name="GM Trip", backend_type=BackendType.splitwise, splitwise_group_id=SWID)
        s.add(g)
        await s.flush()
        s.add(GroupMember(group_id=g.id, user_identifier=TOKEN_USER))  # the caller must be a member
        for uid, ident in (members or []):
            s.add(User(identifier=ident, display_name=ident, source="splitwise", splitwise_user_id=uid))
            s.add(GroupMember(group_id=g.id, user_identifier=ident))
        await s.commit()
        return g.id


async def test_create_splitwise_propagates():
    await _purge()
    await _seed_token()
    orig = (c.make_client, c.create_group, c.fetch_groups)
    calls = {}
    c.make_client = lambda token: object()
    c.create_group = lambda client, name, group_type=None: _record(
        calls, "create", (name, group_type), _group_dict(NEW_SWID, name, [_member("8001", "Me")]))
    c.fetch_groups = lambda client: [_group_dict(NEW_SWID, "GM Trip", [_member("8001", "Me")])]
    try:
        async with async_session() as s:
            g = await create_group(GroupCreate(name="GM Trip", backend_type=BackendType.splitwise),
                                   caller=TOKEN_USER, session=s)
            assert g.splitwise_group_id == NEW_SWID
            assert calls["create"] == ("GM Trip", None)
    finally:
        c.make_client, c.create_group, c.fetch_groups = orig
        await _purge()


async def test_create_self_hosted_stays_local():
    await _purge()
    # No token, no monkeypatch: a self-hosted create must not touch Splitwise.
    async with async_session() as s:
        g = await create_group(GroupCreate(name="GM Local"), caller=None, session=s)
        assert g.backend_type == BackendType.self_hosted and g.splitwise_group_id is None
    await _purge()


async def test_delete_splitwise_soft_deletes_keeping_row():
    await _purge()
    await _seed_token()
    gid = await _seed_sw_group(members=[("8001", "alice")])
    orig = (c.make_client, c.delete_group)
    calls = {}
    c.make_client = lambda token: object()
    c.delete_group = lambda client, sw_id: calls.setdefault("del", sw_id)
    try:
        async with async_session() as s:
            await delete_group(gid, caller=TOKEN_USER, session=s)
            assert calls["del"] == SWID
        async with async_session() as s:
            g = await s.get(Group, gid)
            assert g is not None and g.deleted_at is not None  # flagged, not gone
            members = (await s.scalars(
                select(GroupMember.user_identifier).where(GroupMember.group_id == gid))).all()
            assert "alice" in members  # members kept so any of them can restore
        # The caller (a member) sees it in the deleted list; the active list excludes it.
        async with async_session() as s:
            deleted = await list_deleted_groups(caller=TOKEN_USER, session=s)
            assert any(d.id == gid for d in deleted)
    finally:
        c.make_client, c.delete_group = orig
        await _purge()


async def test_delete_splitwise_error_keeps_group():
    await _purge()
    await _seed_token()
    gid = await _seed_sw_group()

    def _boom(client, sw_id):
        raise RuntimeError("nope")
    orig = (c.make_client, c.delete_group)
    c.make_client = lambda token: object()
    c.delete_group = _boom
    try:
        async with async_session() as s:
            try:
                await delete_group(gid, caller=TOKEN_USER, session=s)
                raise AssertionError("expected 502")
            except HTTPException as e:
                assert e.status_code == 502
        async with async_session() as s:
            g = await s.get(Group, gid)
            assert g is not None and g.deleted_at is None  # untouched (not even flagged)
    finally:
        c.make_client, c.delete_group = orig
        await _purge()


async def test_add_member_by_email_invites():
    await _purge()
    await _seed_token()
    gid = await _seed_sw_group()
    orig = (c.make_client, c.add_user_to_group, c.fetch_groups)
    calls = {}
    c.make_client = lambda token: object()
    c.add_user_to_group = lambda client, sw_id, **kw: _record(
        calls, "add", kw,
        {"splitwise_id": "8002", "first_name": "Invited", "last_name": "", "email": "inv@example.com",
         "picture": None})
    # The follow-up sync returns the group now containing the invited member.
    c.fetch_groups = lambda client: [_group_dict(SWID, "GM Trip", [_member("8002", "Invited", "inv@example.com")])]
    try:
        async with async_session() as s:
            member = await add_member(gid, GroupMemberCreate(email="inv@example.com"),
                                      caller=TOKEN_USER, session=s)
            assert calls["add"].get("email") == "inv@example.com"
            assert member.group_id == gid
        async with async_session() as s:
            u = await s.scalar(select(User).where(User.splitwise_user_id == "8002"))
            assert u is not None
    finally:
        c.make_client, c.add_user_to_group, c.fetch_groups = orig
        await _purge()


async def test_remove_member_propagates():
    await _purge()
    await _seed_token()
    gid = await _seed_sw_group(members=[("8001", "alice")])
    orig = (c.remove_user_from_group,)
    calls = {}
    c.remove_user_from_group = lambda token, sw_id, swid: calls.setdefault("rm", (sw_id, swid))
    try:
        async with async_session() as s:
            await remove_member(gid, "alice", caller=TOKEN_USER, session=s)
            assert calls["rm"] == (SWID, "8001")
        async with async_session() as s:
            gone = await s.scalar(select(GroupMember).where(
                GroupMember.group_id == gid, GroupMember.user_identifier == "alice"))
            assert gone is None
    finally:
        c.remove_user_from_group = orig[0]
        await _purge()


async def test_restore_group_clears_flag_and_syncs():
    await _purge()
    await _seed_token()
    gid = await _seed_sw_group(members=[("8001", "alice")])
    async with async_session() as s:  # flag it deleted, as delete_group would
        g = await s.get(Group, gid)
        g.deleted_at = datetime.now(timezone.utc)
        await s.commit()
    orig = (c.make_client, c.restore_group, c.fetch_groups, c.fetch_expenses)
    calls = {}
    c.make_client = lambda token: object()
    c.restore_group = lambda token, sw_id: calls.setdefault("restore", sw_id)
    c.fetch_groups = lambda client: [_group_dict(SWID, "GM Trip", [_member("8001", "alice")])]
    c.fetch_expenses = lambda client, **kw: []
    try:
        async with async_session() as s:
            g = await restore_group(gid, caller=TOKEN_USER, session=s)
            assert calls["restore"] == SWID
            assert g.deleted_at is None
        async with async_session() as s:
            assert (await s.get(Group, gid)).deleted_at is None  # cleared, back in active lists
    finally:
        c.make_client, c.restore_group, c.fetch_groups, c.fetch_expenses = orig
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
