"""Admin user management: invite-redemption notifies the creator; admins can delete/revoke other users
(with a self-revoke guard); non-admins can't. Drives the router/identity functions directly with an explicit
caller (no HTTP/auth plumbing), like test_scoping. Runs against the running Postgres; cleans up its own rows."""
from fastapi import HTTPException
from sqlalchemy import delete, select

from app.auth import identity
from app.config import settings
from app.db import async_session
from app.models import Invite, Notification, User
from app.models.enums import UserSource
from app.routers import users as users_router

ADMIN = "au-admin-zzz"
NEWBIE = "au-newbie-zzz"
VICTIM = "au-victim-zzz"


async def _cleanup(session) -> None:
    await session.execute(delete(Notification).where(
        Notification.owner_identifier.in_([ADMIN, NEWBIE, VICTIM])))
    await session.execute(delete(Invite).where(Invite.created_by == ADMIN))
    await session.execute(delete(User).where(User.identifier.in_([ADMIN, NEWBIE, VICTIM])))
    await session.execute(delete(User).where(User.google_sub == "au-sub-zzz"))  # the redeemer (slugified id)
    await session.commit()


async def test_invite_redemption_notifies_creator():
    async with async_session() as session:
        await _cleanup(session)
        try:
            # An enrolled admin exists, so resolve_user takes the redeem path (not the fresh-server claim).
            session.add(User(identifier=ADMIN, display_name="Admin", source=UserSource.app,
                             enrolled=True, is_admin=True))
            session.add(Invite(code="au-code-zzz", created_by=ADMIN))
            await session.commit()

            user = await identity.resolve_user(
                session, provider="google", sub="au-sub-zzz", email="au-newbie@x.com",
                name="Newbie Z", avatar=None, invite_code="au-code-zzz")
            assert user.enrolled is True

            notes = list(await session.scalars(select(Notification).where(
                Notification.owner_identifier == ADMIN, Notification.type == "invite_redeemed")))
            assert len(notes) == 1
            assert user.display_name in notes[0].content  # "Newbie Z accepted your invite and joined."
        finally:
            await _cleanup(session)


async def test_admin_can_delete_other_user_nonadmin_cannot():
    saved = settings.admin_users
    async with async_session() as session:
        await _cleanup(session)
        try:
            session.add(User(identifier=ADMIN, display_name="Admin", source=UserSource.app, enrolled=True))
            victim = User(identifier=VICTIM, display_name="Victim", source=UserSource.app, enrolled=True)
            session.add(victim)
            await session.commit()
            vid = victim.id
            settings.admin_users = [ADMIN]

            # A non-admin can't delete someone else.
            try:
                await users_router.delete_user(vid, caller=NEWBIE, session=session)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403

            # An admin can.
            await users_router.delete_user(vid, caller=ADMIN, session=session)
            assert await session.get(User, vid) is None
        finally:
            settings.admin_users = saved
            await _cleanup(session)


async def test_admin_revoke_deenrolls_with_self_guard():
    saved = settings.admin_users
    async with async_session() as session:
        await _cleanup(session)
        try:
            admin = User(identifier=ADMIN, display_name="Admin", source=UserSource.app,
                         enrolled=True, is_admin=True)
            victim = User(identifier=VICTIM, display_name="Victim", source=UserSource.app, enrolled=True)
            session.add_all([admin, victim])
            await session.commit()
            vid, aid = victim.id, admin.id
            settings.admin_users = [ADMIN]

            # non-admin → 403
            try:
                await users_router.revoke_user(vid, caller=NEWBIE, session=session)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403

            # admin revoking themselves → 400 (no self-lockout)
            try:
                await users_router.revoke_user(aid, caller=ADMIN, session=session)
                assert False, "expected 400"
            except HTTPException as e:
                assert e.status_code == 400

            # admin revokes the victim → de-enrolled, but the row (identity/history) stays
            await users_router.revoke_user(vid, caller=ADMIN, session=session)
            await session.refresh(victim)
            assert victim.enrolled is False
            assert await session.get(User, vid) is not None
        finally:
            settings.admin_users = saved
            await _cleanup(session)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
