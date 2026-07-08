"""In-process scheduled-backup loop.

Started unconditionally from the FastAPI lifespan; it polls a fixed tick and re-reads `backup_interval_hours`
from the server settings each cycle (`<= 0` = paused). It fires off a **persisted** last-run marker
(`backup_last_run_at` in server_settings), so a redeploy doesn't reset the interval. Each run creates a
`scheduled` backup and prunes per the retention policy. Failures are logged, never raised; the marker is
recorded only on success. Cancelled cleanly on shutdown.
"""
import asyncio
import logging
from datetime import datetime, timedelta, timezone

from app import server_settings
from app.db import async_session
from app.services import backups

log = logging.getLogger(__name__)

_POLL_SECONDS = 60
_MARKER = "backup_last_run_at"


async def run_scheduler() -> None:
    while True:
        await asyncio.sleep(_POLL_SECONDS)
        try:
            async with async_session() as session:
                interval = await server_settings.get(session, "backup_interval_hours")
                last = await server_settings.get_timestamp(session, _MARKER)
            if interval <= 0:
                continue
            now = datetime.now(timezone.utc)
            if last is not None and now - last < timedelta(hours=interval):
                continue
            info = await backups.create(label="scheduled", kind=backups.KIND_SCHEDULED)
            deleted = await backups.prune()
            async with async_session() as session:
                await server_settings.set_timestamp(session, _MARKER, now)  # record only on success
                await session.commit()
            log.info("Scheduled backup %s created; pruned %d.", info.name, len(deleted))
            # Off-device tier: push a copy to the configured restic repo. Isolated so an offsite failure
            # (bad target/creds/network) never fails the local backup - record the outcome for the admin UI.
            enabled, _target = await backups.offsite_config()
            if enabled:
                try:
                    target = await backups.offsite_push(label="scheduled")
                    await backups.record_offsite_result(True, "")
                    log.info("Off-device backup pushed to %s.", target)
                except Exception as exc:  # noqa: BLE001 - surface via status marker, don't fail the loop
                    await backups.record_offsite_result(False, str(exc))
                    log.exception("Off-device backup push failed.")
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Scheduled backup failed; will retry next interval.")
