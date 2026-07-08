"""Invites router: create / list / revoke, plus the admin-or-`invites_open_to_members` permission. DB-backed."""
from fastapi import HTTPException
from sqlalchemy import delete, select

from app import server_settings
from app.db import async_session
from app.models import Invite, User
from app.models.enums import UserSource
from app.routers.invites import create_invite, list_invites, require_can_invite, revoke_invite
from app.schemas.invite import InviteCreate

PREFIX = "inv-zzz"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(Invite).where(Invite.created_by.like(f"{PREFIX}%")))
        await s.execute(delete(User).where(User.identifier.like(f"{PREFIX}%")))
        await s.commit()


async def test_create_list_revoke():
    await _purge()
    try:
        async with async_session() as s:
            s.add(User(identifier=f"{PREFIX}-admin", display_name="A", source=UserSource.app,
                       enrolled=True, is_admin=True))
            await s.commit()
        async with async_session() as s:
            created = await create_invite(
                InviteCreate(label="for Bob", ttl_days=7), caller=f"{PREFIX}-admin", session=s)
            assert created.status == "active" and created.code and created.expires_at is not None
            invite_id = created.id
        async with async_session() as s:
            rows = await list_invites(caller=f"{PREFIX}-admin", session=s)
            assert any(r.id == invite_id for r in rows)
        async with async_session() as s:
            await revoke_invite(invite_id, caller=f"{PREFIX}-admin", session=s)
        async with async_session() as s:
            inv = await s.scalar(select(Invite).where(Invite.id == invite_id))
            assert inv.revoked_at is not None
    finally:
        await _purge()


async def test_permission_admin_or_open():
    await _purge()
    try:
        async with async_session() as s:
            s.add(User(identifier=f"{PREFIX}-member", display_name="M", source=UserSource.app,
                       enrolled=True, is_admin=False))
            await server_settings.set_value(s, "invites_open_to_members", False)
            await s.commit()
        # Default: a non-admin member is forbidden.
        async with async_session() as s:
            try:
                await require_can_invite(caller=f"{PREFIX}-member", session=s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
        # Flip the toggle on: now any member may invite.
        async with async_session() as s:
            await server_settings.set_value(s, "invites_open_to_members", True)
            await s.commit()
        async with async_session() as s:
            assert await require_can_invite(caller=f"{PREFIX}-member", session=s) == f"{PREFIX}-member"
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "invites_open_to_members", False)
            await s.commit()
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
