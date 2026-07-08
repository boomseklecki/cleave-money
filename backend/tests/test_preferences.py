"""Per-owner preferences store: upsert + list are scoped to the caller. DB-backed (runs in the test env)."""
from sqlalchemy import delete

from app.db import async_session
from app.models import UserPreference
from app.routers.preferences import list_preferences, upsert_preference
from app.schemas.user_preference import PreferenceUpsert


async def _cleanup(session, *owners):
    await session.execute(delete(UserPreference).where(UserPreference.owner_identifier.in_(owners)))
    await session.commit()


async def test_upsert_then_list_returns_value():
    async with async_session() as s:
        await _cleanup(s, "alice")
        await upsert_preference("categories.v1", PreferenceUpsert(value='{"v":1}'), caller="alice", session=s)
        rows = await list_preferences(caller="alice", session=s)
        assert [(r.key, r.value) for r in rows] == [("categories.v1", '{"v":1}')]
        # Upsert replaces the value for the same (owner, key).
        await upsert_preference("categories.v1", PreferenceUpsert(value='{"v":2}'), caller="alice", session=s)
        rows = await list_preferences(caller="alice", session=s)
        assert [r.value for r in rows] == ['{"v":2}']
        await _cleanup(s, "alice")


async def test_scoped_per_owner():
    async with async_session() as s:
        await _cleanup(s, "alice", "bob")
        await upsert_preference("categories.v1", PreferenceUpsert(value='{"who":"alice"}'),
                                caller="alice", session=s)
        # Bob sees none of Alice's preferences.
        assert await list_preferences(caller="bob", session=s) == []
        # Open mode (no caller) returns an empty list.
        assert await list_preferences(caller=None, session=s) == []
        await _cleanup(s, "alice", "bob")


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
