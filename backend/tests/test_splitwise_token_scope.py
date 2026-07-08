"""Splitwise token resolution is scoped to the caller - a real authenticated caller never resolves to another
user's token (the cross-user leak that fed settle-up suggestions for someone else's friends). The lone-token
fallback survives only in open mode (caller/as_user None). Direct-call; runs against Postgres; self-cleaning."""
from fastapi import HTTPException
from sqlalchemy import delete, select

from app.db import async_session
from app.models import SplitwiseToken
from app.routers.balances import _splitwise_token
from app.routers.splitwise import _select_token

OWNER = "tok-owner-zzz"
OTHER = "tok-other-zzz"


async def _cleanup(session) -> None:
    await session.execute(delete(SplitwiseToken).where(
        SplitwiseToken.user_identifier.in_([OWNER, OTHER])))
    await session.commit()


async def test_splitwise_token_scoped_to_caller():
    async with async_session() as session:
        await _cleanup(session)
        try:
            session.add(SplitwiseToken(user_identifier=OWNER, access_token="tok-zzz"))
            await session.commit()

            # A real caller who isn't the owner gets nothing - NOT the owner's token (the leak).
            assert await _splitwise_token(session, OTHER) is None
            # The owner gets their own token.
            mine = await _splitwise_token(session, OWNER)
            assert mine is not None and mine.user_identifier == OWNER
            # Open mode (no caller) still uses a lone token - only assert on a clean single-token DB.
            if len((await session.scalars(select(SplitwiseToken))).all()) == 1:
                lone = await _splitwise_token(session, None)
                assert lone is not None and lone.user_identifier == OWNER
        finally:
            await _cleanup(session)


async def test_select_token_scoped_to_caller():
    async with async_session() as session:
        await _cleanup(session)
        try:
            session.add(SplitwiseToken(user_identifier=OWNER, access_token="tok-zzz"))
            await session.commit()

            # A real caller without their own token is rejected - never falls back to the owner's.
            try:
                await _select_token(session, OTHER)
                assert False, "expected 400"
            except HTTPException as e:
                assert e.status_code == 400
            # The owner resolves to their own token.
            assert (await _select_token(session, OWNER)).user_identifier == OWNER
            # Open mode uses a lone token - only assert on a clean single-token DB.
            if len((await session.scalars(select(SplitwiseToken))).all()) == 1:
                assert (await _select_token(session, None)).user_identifier == OWNER
        finally:
            await _cleanup(session)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
