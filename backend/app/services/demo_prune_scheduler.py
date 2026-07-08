"""In-process demo-cleanup loop.

Started unconditionally from the FastAPI lifespan; it only does work when `DEMO_MODE` is on. Every hour it
prunes ephemeral `demo-*` guest users (and their seeded data) older than the retention window, bounding the
demo backend's growth against scripted abuse of the open `/auth/demo` faucet. Failures are logged, never
raised. Cancelled cleanly on shutdown.
"""
import asyncio
import logging
from datetime import timedelta

from app.cli.prune_demo import prune_demo_guests
from app.config import settings
from app.db import async_session

log = logging.getLogger(__name__)

_POLL_SECONDS = 3600
_RETENTION = timedelta(days=7)  # keep a guest's seeded demo across days (matches the CLI default)


async def run_scheduler() -> None:
    while True:
        await asyncio.sleep(_POLL_SECONDS)
        if not settings.demo_mode:
            continue
        try:
            async with async_session() as session:
                count = await prune_demo_guests(session, _RETENTION)
                await session.commit()
            if count:
                log.info("Demo prune: removed %d guest(s) older than %s.", count, _RETENTION)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Demo prune failed; will retry next interval.")
