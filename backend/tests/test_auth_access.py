"""DB-backed enrollment: resolve_user requires a single-use invite for new users once the server is claimed,
redeems it once, and require_auth re-checks enrollment every request. Runs against the running Postgres.
"""
import secrets

from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy import delete, select

from app.auth import require_auth, tokens
from app.auth.access import is_admin, is_enrolled
from app.auth.identity import resolve_user
from app.config import settings
from app.db import async_session
from app.models import Invite, User
from app.models.enums import UserSource

PREFIX = "enroll-zzz"
EMAILS = [f"{PREFIX}-{i}@example.com" for i in range(4)]
SUBS = [f"{PREFIX}-sub-{i}" for i in range(4)]


async def _purge():
    async with async_session() as s:
        await s.execute(delete(User).where(User.email.in_(EMAILS)))
        await s.execute(delete(User).where(User.google_sub.in_(SUBS)))
        await s.execute(delete(Invite).where(Invite.created_by == PREFIX))
        await s.commit()


async def _seed_enrolled(s) -> None:
    """An enrolled anchor user so the server isn't in the first-claim state."""
    s.add(User(identifier=f"{PREFIX}-anchor", display_name="Anchor", source=UserSource.app,
               email=EMAILS[0], google_sub=SUBS[0], enrolled=True))
    await s.commit()


def test_is_enrolled_and_admin():
    assert is_enrolled(None) is False
    u = User(identifier="x", display_name="X", source=UserSource.app)
    assert is_enrolled(u) is False
    u.enrolled = True
    assert is_enrolled(u) is True
    assert is_admin("x", u) is False
    u.is_admin = True
    assert is_admin("x", u) is True  # DB flag
    saved = settings.admin_users
    try:
        settings.admin_users = ["boss"]
        assert is_admin("boss", None) is True   # config union
        assert is_admin("rando", None) is False
    finally:
        settings.admin_users = saved


async def test_new_user_requires_invite_then_single_use():
    await _purge()
    try:
        async with async_session() as s:
            await _seed_enrolled(s)  # server is "claimed"

        # No invite -> 403, no user created.
        async with async_session() as s:
            try:
                await resolve_user(s, provider="google", sub=SUBS[1], email=EMAILS[1],
                                   name="NoInvite", avatar=None)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403

        code = secrets.token_urlsafe(8)
        async with async_session() as s:
            s.add(Invite(code=code, created_by=PREFIX))
            await s.commit()

        # Valid invite -> enrolled user; invite marked redeemed.
        async with async_session() as s:
            u = await resolve_user(s, provider="google", sub=SUBS[2], email=EMAILS[2],
                                   name="Invited", avatar=None, invite_code=code)
            assert u.enrolled is True
            redeemer = u.identifier
        async with async_session() as s:
            inv = await s.scalar(select(Invite).where(Invite.code == code))
            assert inv.redeemed_at is not None and inv.redeemed_by == redeemer

        # Single-use: the same code can't enroll another identity.
        async with async_session() as s:
            try:
                await resolve_user(s, provider="google", sub=SUBS[3], email=EMAILS[3],
                                   name="Reuse", avatar=None, invite_code=code)
                raise AssertionError("expected 403 (invite already redeemed)")
            except HTTPException as e:
                assert e.status_code == 403
    finally:
        await _purge()


async def test_require_auth_enrollment_gate():
    await _purge()
    try:
        async with async_session() as s:
            await _seed_enrolled(s)
            user = User(identifier=f"{PREFIX}-pending", display_name="Pending", source=UserSource.app,
                        email=EMAILS[1], google_sub=SUBS[1], enrolled=False)
            s.add(user)
            await s.commit()
            token = tokens.issue(user)
        creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)

        # Un-enrolled -> 403 on every request.
        async with async_session() as s:
            try:
                await require_auth(creds, s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403

        # Enroll -> passes and returns the identifier.
        async with async_session() as s:
            u = await s.scalar(select(User).where(User.identifier == f"{PREFIX}-pending"))
            u.enrolled = True
            await s.commit()
        async with async_session() as s:
            assert await require_auth(creds, s) == f"{PREFIX}-pending"
    finally:
        await _purge()


def test_jwt_secret_required_when_auth_enforced():
    from app.config import Settings
    try:
        Settings(auth_required=True, auth_jwt_secret="")
        raise AssertionError("expected a validation error for an empty secret")
    except ValueError as e:
        assert "AUTH_JWT_SECRET" in str(e)
    assert Settings(auth_required=True, auth_jwt_secret="x" * 32).auth_required
    assert Settings(auth_required=False, auth_jwt_secret="").auth_required is False


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
