"""Per-owner notification preference tokens (push/feed mutes): owner-scoped GET/PUT with replace-set
semantics. DB-backed, calling the router functions directly."""
from sqlalchemy import delete

from app.db import async_session
from app.models import NotificationMute
from app.routers.notification_mutes import get_notification_prefs, put_notification_prefs
from app.schemas.notification_mute import NotificationPrefs

ALICE, BOB = "nprefs-alice", "nprefs-bob"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(NotificationMute).where(
            NotificationMute.owner_identifier.in_([ALICE, BOB])))
        await s.commit()


async def test_put_then_get_roundtrips_and_replaces():
    await _purge()
    try:
        async with async_session() as s:
            out = await put_notification_prefs(
                NotificationPrefs(tokens=["push:source:splitwise", "feed:connection_request"]),
                caller=ALICE, session=s)
        assert set(out.tokens) == {"push:source:splitwise", "feed:connection_request"}
        async with async_session() as s:
            got = await get_notification_prefs(caller=ALICE, session=s)
        assert set(got.tokens) == {"push:source:splitwise", "feed:connection_request"}
        # PUT replaces (not appends) - and blank/dup tokens are dropped.
        async with async_session() as s:
            await put_notification_prefs(
                NotificationPrefs(tokens=["push:expense_added", "push:expense_added", "  "]),
                caller=ALICE, session=s)
        async with async_session() as s:
            got = await get_notification_prefs(caller=ALICE, session=s)
        assert got.tokens == ["push:expense_added"]
    finally:
        await _purge()


async def test_owner_scoped():
    await _purge()
    try:
        async with async_session() as s:
            await put_notification_prefs(NotificationPrefs(tokens=["push:source:splitwise"]),
                                         caller=ALICE, session=s)
        async with async_session() as s:
            theirs = await get_notification_prefs(caller=BOB, session=s)
        assert theirs.tokens == []                                  # Bob doesn't see Alice's
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
