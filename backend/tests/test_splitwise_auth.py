"""Splitwise OAuth token binding is server-derived (no client-controlled `user`): start binds the state to the
caller, login leaves it empty, and the callback binds the token to the caller-or-resolved identity. DB-backed."""
from sqlalchemy import delete, select

import app.routers.splitwise_auth as sw_auth
from app.db import async_session
from app.integrations.splitwise.pkce import generate_state
from app.models import SplitwiseOAuthState, SplitwiseToken, User
from app.models.enums import UserSource


async def test_start_binds_state_to_caller():
    async with async_session() as s:
        result = await sw_auth.start(caller="startcaller-zzz", session=s)
        try:
            assert result.authorize_url
            row = await s.scalar(select(SplitwiseOAuthState)
                                 .where(SplitwiseOAuthState.user_identifier == "startcaller-zzz"))
            assert row is not None  # state bound to the verified caller, not a query param
        finally:
            await s.execute(delete(SplitwiseOAuthState)
                            .where(SplitwiseOAuthState.user_identifier == "startcaller-zzz"))
            await s.commit()


async def test_login_has_empty_user_binding():
    async with async_session() as s:
        await sw_auth.login(invite=None, session=s)
        row = await s.scalar(select(SplitwiseOAuthState)
                             .order_by(SplitwiseOAuthState.created_at.desc()).limit(1))
        try:
            assert row is not None and row.user_identifier == ""  # no caller-controlled binding
        finally:
            if row is not None:
                await s.delete(row)
                await s.commit()


async def test_callback_binds_caller_or_resolved():
    saved = (sw_auth.exchange_code, sw_auth.make_client, sw_auth.get_current_user, sw_auth.resolve_user,
             sw_auth.importer.sync_notifications)

    async def _noop_sync(*a, **k):  # the connect-time notification backfill isn't what this test exercises
        return {}

    sw_auth.importer.sync_notifications = _noop_sync

    async def fake_resolve(session, **kwargs):
        user = await session.scalar(select(User).where(User.identifier == "swresolved-zzz"))
        if user is None:
            user = User(identifier="swresolved-zzz", display_name="SW", source=UserSource.app, enrolled=True)
            session.add(user)
            await session.flush()
            await session.refresh(user)
        return user

    sw_auth.exchange_code = lambda code, verifier: {
        "access_token": "tok-zzz", "token_type": "bearer", "scope": "x"}
    sw_auth.make_client = lambda token: object()
    sw_auth.get_current_user = lambda client: {
        "splitwise_id": "sw-zzz", "email": "sw-zzz@example.com",
        "first_name": "S", "last_name": "W", "picture": None}
    sw_auth.resolve_user = fake_resolve

    async with async_session() as s:
        try:
            # Connect flow: state bound to caller "alice-zzz" → token binds to alice-zzz.
            st1 = generate_state()
            s.add(SplitwiseOAuthState(state=st1, code_verifier="v", user_identifier="alice-zzz", invite=None))
            await s.commit()
            await sw_auth.callback(code="c", state=st1, session=s)
            tok = await s.scalar(select(SplitwiseToken).where(SplitwiseToken.user_identifier == "alice-zzz"))
            assert tok is not None and tok.access_token == "tok-zzz"

            # Login flow: empty state binding → token binds to the resolved Splitwise identity.
            st2 = generate_state()
            s.add(SplitwiseOAuthState(state=st2, code_verifier="v", user_identifier="", invite=None))
            await s.commit()
            await sw_auth.callback(code="c", state=st2, session=s)
            assert (await s.scalar(select(SplitwiseToken)
                                   .where(SplitwiseToken.user_identifier == "swresolved-zzz"))) is not None
        finally:
            (sw_auth.exchange_code, sw_auth.make_client, sw_auth.get_current_user, sw_auth.resolve_user,
             sw_auth.importer.sync_notifications) = saved
            await s.execute(delete(SplitwiseToken)
                            .where(SplitwiseToken.user_identifier.in_(["alice-zzz", "swresolved-zzz"])))
            await s.execute(delete(SplitwiseOAuthState)
                            .where(SplitwiseOAuthState.user_identifier.in_(["alice-zzz", ""])))
            await s.execute(delete(User).where(User.identifier == "swresolved-zzz"))
            await s.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
