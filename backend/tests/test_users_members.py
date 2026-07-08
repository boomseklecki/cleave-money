"""Users directory, /me, group membership, and Splitwise user/member upserts."""
import json
import urllib.error
import urllib.request

from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.splitwise import importer
from app.models import BackendType, Group, GroupMember, User
from app.models.enums import UserSource

API = "http://localhost:8000"


def _req(method, path, data=None):
    headers = {}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=body, method=method, headers=headers)
    try:
        resp = urllib.request.urlopen(req)
        return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


async def _purge_users(*identifiers):
    async with async_session() as session:
        for identifier in identifiers:
            await session.execute(delete(User).where(User.identifier == identifier))
        await session.commit()


async def _purge_group(group_id):
    async with async_session() as session:
        await session.execute(delete(Group).where(Group.id == group_id))
        await session.commit()


def test_me_open_mode():
    status, body = _req("GET", "/me")
    assert status == 200
    payload = json.loads(body)
    assert payload["authenticated"] is False
    assert payload["identifier"] is None
    assert payload["user"] is None


async def test_user_crud_and_duplicate():
    try:
        status, body = _req("POST", "/users", {"display_name": "John Doe"})
        assert status == 201, (status, body)
        user = json.loads(body)
        assert user["identifier"] == "johndoe"
        assert user["source"] == "manual"
        user_id = user["id"]

        # duplicate identifier -> 409
        assert _req("POST", "/users", {"display_name": "John Doe"})[0] == 409

        listed = json.loads(_req("GET", "/users?source=manual")[1])
        assert any(u["id"] == user_id for u in listed)

        status, body = _req("PATCH", f"/users/{user_id}", {"display_name": "Johnny", "email": "j@x.com"})
        assert status == 200
        patched = json.loads(body)
        assert patched["display_name"] == "Johnny" and patched["email"] == "j@x.com"

        assert _req("DELETE", f"/users/{user_id}")[0] == 204
        assert _req("GET", f"/users/{user_id}")[0] == 404
    finally:
        await _purge_users("johndoe")


async def test_group_membership():
    status, body = _req("POST", "/groups", {"name": "members-test"})
    group_id = json.loads(body)["id"]
    try:
        status, body = _req("POST", f"/groups/{group_id}/members", {"user_identifier": "memberx"})
        assert status == 201
        # idempotent add
        _req("POST", f"/groups/{group_id}/members", {"user_identifier": "memberx"})
        members = json.loads(_req("GET", f"/groups/{group_id}/members")[1])
        assert [m["user_identifier"] for m in members] == ["memberx"]

        assert _req("DELETE", f"/groups/{group_id}/members/memberx")[0] == 204
        assert json.loads(_req("GET", f"/groups/{group_id}/members")[1]) == []
    finally:
        await _purge_group(group_id)


async def test_upsert_user_preserves_existing_source():
    await _purge_users("appuser-zzz", "swuser-zzz")
    try:
        async with async_session() as session:
            session.add(User(identifier="appuser-zzz", display_name="Alice", source=UserSource.app))
            await session.commit()

            # New splitwise user
            await importer._upsert_user(session, "swuser-zzz", "Friend", "555")
            # Existing app user re-seen via Splitwise: gets splitwise_user_id, keeps app source
            await importer._upsert_user(session, "appuser-zzz", "AliceSW", "111")
            await session.commit()

            sw = await session.scalar(select(User).where(User.identifier == "swuser-zzz"))
            assert sw.source == UserSource.splitwise and sw.splitwise_user_id == "555"

            app = await session.scalar(select(User).where(User.identifier == "appuser-zzz"))
            assert app.source == UserSource.app  # not downgraded
            assert app.display_name == "Alice"  # not overwritten
            assert app.splitwise_user_id == "111"  # but linked
    finally:
        await _purge_users("appuser-zzz", "swuser-zzz")


async def test_upsert_group_member_dedupes():
    status, body = _req("POST", "/groups", {"name": "member-upsert-test"})
    group_id = json.loads(body)["id"]
    try:
        async with async_session() as session:
            from uuid import UUID

            gid = UUID(group_id)
            await importer._upsert_group_member(session, gid, "dup")
            await importer._upsert_group_member(session, gid, "dup")
            await session.commit()
            count = await session.scalar(
                select(func.count()).select_from(GroupMember).where(GroupMember.group_id == gid)
            )
            assert count == 1
    finally:
        await _purge_group(group_id)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
