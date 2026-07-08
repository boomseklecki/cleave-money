"""The Splitwise importer reuses an existing user (by splitwise_user_id, then email) instead of minting a
duplicate - so an Apple/Google sign-in and a Splitwise import converge on one identifier. Runs against the
running Postgres; cleans up its own rows. Sentinel-suffixed identifiers so it can't touch real data.
"""
from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.splitwise import importer
from app.models import User
from app.models.enums import UserSource

EMAIL = "unify-zzz@example.com"
APP_ID = "unifyappzzz"          # an existing app sign-in
SW_ID = "unify-sw-zzz"          # the Splitwise participant id (no prior link)
OTHER_SW = "unify-other-zzz"
OTHER_NAME = "Zqunifyzzz"        # slugifies to "zqunifyzzz" (unique)
OTHER_ID = "zqunifyzzz"


async def _cleanup(session) -> None:
    await session.execute(delete(User).where(User.identifier.in_([APP_ID, OTHER_ID])))
    await session.execute(delete(User).where(User.email == EMAIL))
    await session.execute(delete(User).where(User.splitwise_user_id.in_([SW_ID, OTHER_SW])))
    await session.commit()


async def test_resolve_reuses_existing_user_by_email_then_sub():
    async with async_session() as session:
        await _cleanup(session)
        try:
            # An app sign-in already created this user (email known, no Splitwise link yet).
            session.add(User(identifier=APP_ID, display_name="Alice Rivera",
                             source=UserSource.app, email=EMAIL))
            await session.commit()

            # Same email on a Splitwise participant -> reuse the app user, do NOT mint a name slug.
            ident = await importer._resolve_identifier(
                session, splitwise_user_id=SW_ID, first_name="Alice", email=EMAIL, user_map={})
            assert ident == APP_ID

            # An unrelated participant with no match -> deterministic slug fallback.
            other = await importer._resolve_identifier(
                session, splitwise_user_id=OTHER_SW, first_name=OTHER_NAME, email=None, user_map={})
            assert other == OTHER_ID

            # Once linked by splitwise_user_id, that wins regardless of email.
            session.add(User(identifier=OTHER_ID, display_name=OTHER_NAME,
                             source=UserSource.splitwise, splitwise_user_id=OTHER_SW))
            await session.commit()
            again = await importer._resolve_identifier(
                session, splitwise_user_id=OTHER_SW, first_name="Ignored",
                email="someone-else-zzz@example.com", user_map={})
            assert again == OTHER_ID

            # No duplicate user was minted from the first participant's first name.
            assert await session.scalar(
                select(func.count()).select_from(User).where(User.identifier == "alice")) == 0
        finally:
            await _cleanup(session)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
