"""In-process fast notifications-only poll.

A lighter sibling of `sync_scheduler`: every tick it re-reads `notifications_poll_minutes` (server settings;
`<= 0` = off) and, when that interval has elapsed since the persisted `notifications_last_poll_at` marker,
pulls *only* each Splitwise token's recent notifications (and pushes new partner activity) - skipping the
expensive groups/users/expenses sync. This makes partner-activity pushes near-real-time instead of waiting for
the slow full-sync interval. Failures are logged, never raised; the marker is recorded only on success.
Cancelled cleanly on shutdown.
"""
import asyncio
import logging
from datetime import datetime, timedelta, timezone

from app import server_settings
from app.db import async_session
from app.services import sync

log = logging.getLogger(__name__)

_POLL_SECONDS = 60
_MARKER = "notifications_last_poll_at"


async def run_scheduler() -> None:
    while True:
        await asyncio.sleep(_POLL_SECONDS)
        try:
            async with async_session() as session:
                minutes = await server_settings.get(session, "notifications_poll_minutes")
                last = await server_settings.get_timestamp(session, _MARKER)
            if minutes <= 0:
                continue
            now = datetime.now(timezone.utc)
            if last is not None and now - last < timedelta(minutes=minutes):
                continue
            async with async_session() as session:
                count = await sync.sync_notifications_all(session)
            async with async_session() as session:
                await server_settings.set_timestamp(session, _MARKER, now)  # record only on success
                await session.commit()
            log.info("Notifications poll: %s Splitwise tokens.", count)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Notifications poll failed; will retry next tick.")
