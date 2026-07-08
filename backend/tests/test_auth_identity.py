"""resolve_user: create, find-by-sub, and link-by-email across providers."""
from sqlalchemy import delete, select

from app.auth.identity import resolve_user
from app.db import async_session
from app.models import User

EMAIL = "identitytest@example.com"


async def _purge():
    async with async_session() as session:
        await session.execute(
            delete(User).where((User.email == EMAIL) | (User.identifier.like("identitytest%")))
        )
        await session.commit()


async def test_create_then_find_by_sub():
    await _purge()
    try:
        async with async_session() as session:
            first = await resolve_user(
                session, provider="google", sub="g-sub-create", email=EMAIL,
                name="Identity Test", avatar="http://x/a.png",
            )
            first_id = first.id
            assert first.source.value == "app"
            assert first.google_sub == "g-sub-create"
        async with async_session() as session:
            again = await resolve_user(
                session, provider="google", sub="g-sub-create", email=EMAIL, name=None, avatar=None
            )
            assert again.id == first_id  # same sub -> same user, no duplicate
    finally:
        await _purge()


async def test_link_second_provider_by_email():
    await _purge()
    try:
        async with async_session() as session:
            g_user = await resolve_user(
                session, provider="google", sub="g-sub-link", email=EMAIL, name="Identity Test",
                avatar=None,
            )
            g_id = g_user.id
        async with async_session() as session:
            a_user = await resolve_user(
                session, provider="apple", sub="a-sub-link", email=EMAIL, name="Identity Test",
                avatar=None,
            )
            assert a_user.id == g_id  # linked by email -> one user
            assert a_user.google_sub == "g-sub-link"
            assert a_user.apple_sub == "a-sub-link"
        # exactly one row for this email
        async with async_session() as session:
            rows = await session.scalars(select(User).where(User.email == EMAIL))
            assert len(list(rows)) == 1
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
