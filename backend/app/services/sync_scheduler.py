"""In-process periodic data-sync loop.

Started unconditionally from the FastAPI lifespan; it polls a fixed tick and re-reads `sync_interval_hours`
from the server settings each cycle (so an admin change takes effect within a tick; `<= 0` = paused). It fires
off a **persisted** last-run marker (`sync_last_run_at` in server_settings), so a redeploy doesn't reset the
interval - and a never-synced server syncs shortly after first boot. Each run does a full Plaid + Splitwise
sync. Failures are logged, never raised; the marker is recorded only on success, so a failed sync retries next
tick. Cancelled cleanly on shutdown.
"""
import asyncio
import logging
from datetime import datetime, timedelta, timezone

from app import server_settings
from app.db import async_session
from app.services import sync

log = logging.getLogger(__name__)

_POLL_SECONDS = 60
_MARKER = "sync_last_run_at"


async def run_scheduler() -> None:
    while True:
        await asyncio.sleep(_POLL_SECONDS)
        try:
            async with async_session() as session:
                interval = await server_settings.get(session, "sync_interval_hours")
                last = await server_settings.get_timestamp(session, _MARKER)
            if interval <= 0:
                continue
            now = datetime.now(timezone.utc)
            if last is not None and now - last < timedelta(hours=interval):
                continue
            async with async_session() as session:
                stats = await sync.sync_all(session)
            async with async_session() as session:
                await server_settings.set_timestamp(session, _MARKER, now)  # record only on success
                await session.commit()
            log.info("Scheduled sync: %s Plaid items, %s Splitwise tokens.",
                     stats["plaid_items"], stats["splitwise_tokens"])
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Scheduled sync failed; will retry next interval.")
