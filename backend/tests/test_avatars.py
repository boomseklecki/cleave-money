"""Custom avatars: upload/serve/delete, resolver precedence, per-object content-type, and the MinIO
object cleanup when a user/group is deleted.

Calls the router handlers directly with a constructed Request: the `/me/*` and group routes require a
non-null caller (and membership), which the open-mode HTTP test harness can't supply. Bytes still flow
through MinIO exactly as in production.
"""
from fastapi import HTTPException
from sqlalchemy import delete, select
from starlette.requests import Request

from app.db import async_session
from app.integrations.storage import minio_client
from app.logic.avatars import avatar_endpoint
from app.models import Group, GroupMember, User
from app.models.enums import BackendType, UserSource
from app.routers.avatars import (
    delete_group_avatar,
    delete_my_avatar,
    download_group_avatar,
    download_my_avatar_original,
    download_user_avatar,
    upload_group_avatar,
    upload_my_avatar,
    upload_my_avatar_original,
)
from app.routers.groups import _hard_delete_group
from app.routers.users import delete_user

IDENT = "avatar-user-zzz"
PNG = b"\x89PNG\r\n\x1a\n" + b"avatar-display-bytes"
JPG = b"\xff\xd8\xff\xe0" + b"avatar-original-bytes"


def _req(body: bytes = b"", headers: dict | None = None, method: str = "PUT") -> Request:
    hlist = [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()]

    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}

    return Request({"type": "http", "method": method, "headers": hlist}, receive)


async def _make_user(ident: str = IDENT):
    async with async_session() as s:
        u = User(identifier=ident, display_name="Ava", source=UserSource.manual,
                 avatar_url="https://ext.example/fallback.png", enrolled=True)
        s.add(u)
        await s.commit()
        return u.id


async def _drop_user(ident: str = IDENT):
    async with async_session() as s:
        await s.execute(delete(User).where(User.identifier == ident))
        await s.commit()


async def test_user_avatar_round_trip_resolver_and_original_type():
    uid = await _make_user()
    try:
        # Upload the display square (png) + a crop transform.
        async with async_session() as s:
            resp = await upload_my_avatar(
                request=_req(PNG, {"content-type": "image/png", "x-avatar-crop": "2.0,10,-5"}),
                caller=IDENT, session=s)
        assert resp.has_custom_avatar is True
        assert resp.avatar_url == avatar_endpoint("users", uid)      # resolves to OUR endpoint, not the ext url
        assert resp.avatar_crop.scale == 2.0 and resp.avatar_crop.dx == 10 and resp.avatar_crop.dy == -5

        display_key = f"avatars/users/{uid}/display.img"
        original_key = f"avatars/users/{uid}/original.img"
        assert minio_client.object_exists(display_key)

        # Display serves its own bytes + type.
        async with async_session() as s:
            got = await download_user_avatar(user_id=uid, caller="someone-else", session=s)
        assert got.body == PNG and got.media_type == "image/png"

        # Upload a full-res original in a DIFFERENT format (jpeg).
        async with async_session() as s:
            await upload_my_avatar_original(
                request=_req(JPG, {"content-type": "image/jpeg"}), caller=IDENT, session=s)
        assert minio_client.object_exists(original_key)

        # #4: the original serves as its OWN type (jpeg), not the display's (png).
        async with async_session() as s:
            orig = await download_my_avatar_original(caller=IDENT, session=s)
        assert orig.body == JPG and orig.media_type == "image/jpeg"

        # Delete → both objects gone; resolver falls back to the external url.
        async with async_session() as s:
            await delete_my_avatar(caller=IDENT, session=s)
        assert not minio_client.object_exists(display_key)
        assert not minio_client.object_exists(original_key)
        async with async_session() as s:
            u = await s.scalar(select(User).where(User.identifier == IDENT))
            assert u.avatar_object_key is None and u.avatar_url == "https://ext.example/fallback.png"
    finally:
        for k in (f"avatars/users/{uid}/display.img", f"avatars/users/{uid}/original.img"):
            try:
                minio_client.remove(k)
            except Exception:
                pass
        await _drop_user()


async def test_upload_validators():
    uid = await _make_user()
    try:
        async with async_session() as s:
            try:
                await upload_my_avatar(request=_req(PNG, {"content-type": "text/html"}),
                                       caller=IDENT, session=s)
            except HTTPException as e:
                assert e.status_code == 422
            else:
                raise AssertionError("expected 422 for disallowed content-type")
        async with async_session() as s:
            try:
                await upload_my_avatar(request=_req(b"", {"content-type": "image/png"}),
                                       caller=IDENT, session=s)
            except HTTPException as e:
                assert e.status_code == 400
            else:
                raise AssertionError("expected 400 for empty body")
        # Nothing was stored.
        assert not minio_client.object_exists(f"avatars/users/{uid}/display.img")
    finally:
        await _drop_user()


async def test_deleting_user_purges_avatar_objects():
    """#2: deleting a user removes its avatar objects from MinIO (no orphan)."""
    uid = await _make_user()
    display_key = f"avatars/users/{uid}/display.img"
    original_key = f"avatars/users/{uid}/original.img"
    try:
        async with async_session() as s:
            await upload_my_avatar(request=_req(PNG, {"content-type": "image/png"}),
                                   caller=IDENT, session=s)
            await upload_my_avatar_original(request=_req(JPG, {"content-type": "image/jpeg"}),
                                            caller=IDENT, session=s)
        assert minio_client.object_exists(display_key) and minio_client.object_exists(original_key)

        async with async_session() as s:
            await delete_user(user_id=uid, caller=IDENT, session=s)
        assert not minio_client.object_exists(display_key)
        assert not minio_client.object_exists(original_key)
    finally:
        for k in (display_key, original_key):
            try:
                minio_client.remove(k)
            except Exception:
                pass
        await _drop_user()


async def test_deleting_group_purges_avatar_objects():
    """#2: hard-deleting a group removes its avatar objects from MinIO. Group serving is member-gated."""
    member = "avatar-grp-member-zzz"
    async with async_session() as s:
        g = Group(name="avatar-grp-zzz", backend_type=BackendType.self_hosted)
        s.add(g)
        await s.flush()
        s.add(GroupMember(group_id=g.id, user_identifier=member))
        await s.commit()
        gid = g.id
    display_key = f"avatars/groups/{gid}/display.img"
    try:
        async with async_session() as s:
            await upload_group_avatar(group_id=gid, request=_req(PNG, {"content-type": "image/png"}),
                                      caller=member, session=s)
        assert minio_client.object_exists(display_key)

        # Member can read it.
        async with async_session() as s:
            got = await download_group_avatar(group_id=gid, caller=member, session=s)
        assert got.body == PNG

        # Delete the group → object purged.
        async with async_session() as s:
            g = await s.get(Group, gid)
            await _hard_delete_group(s, g)
        assert not minio_client.object_exists(display_key)
    finally:
        try:
            minio_client.remove(display_key)
        except Exception:
            pass
        async with async_session() as s:
            await s.execute(delete(GroupMember).where(GroupMember.user_identifier == member))
            await s.execute(delete(Group).where(Group.id == gid))
            await s.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
