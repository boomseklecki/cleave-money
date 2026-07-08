"""Download original Splitwise receipt images into MinIO as native Receipt rows.

Splitwise receipts live behind an authenticated API URL, so they can't be loaded by the app and are
lost when a group is converted to local. This persists a local copy (mirrors the receipt upload path).
"""
import asyncio
import logging
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import settings
from app.integrations.splitwise import client as sw_client
from app.integrations.storage import minio_client
from app.models import Expense, Receipt

log = logging.getLogger(__name__)

# Politeness throttle for the bulk/backfill receipt pulls so we don't hammer Splitwise's image host.
RECEIPT_FETCH_DELAY = 0.4   # seconds between fetches
BACKFILL_MAX_PER_RUN = 50   # cap for one scheduled backfill pass (the one-time button is uncapped)

# Serialize the two backfill triggers (scheduled sync + the manual download-all) so they can't both pass the
# per-expense receipt check and double-insert. Skip-if-running (both are opportunistic + idempotent): a run
# that finds a backfill already in progress just returns, rather than stalling the scheduler behind it.
_backfill_lock = asyncio.Lock()


async def pending_receipt_expense_ids(
    session: AsyncSession, group_ids: list[UUID], limit: int | None = None
) -> list[UUID]:
    """Expense ids in `group_ids` that have a Splitwise receipt URL but no downloaded `Receipt` yet, newest
    transaction first (so the bulk/backfill pulls the most recent receipts first). Empty when no groups."""
    if not group_ids:
        return []
    stmt = (
        select(Expense.id)
        .where(
            Expense.group_id.in_(group_ids),
            Expense.splitwise_receipt_url.is_not(None),
            ~select(Receipt.id).where(Receipt.expense_id == Expense.id).exists(),
        )
        .order_by(Expense.date.desc())
    )
    if limit is not None:
        stmt = stmt.limit(limit)
    return list(await session.scalars(stmt))


async def download_pending(
    session: AsyncSession, expense_ids: list[UUID], access_token: str, rate_delay: float = RECEIPT_FETCH_DELAY
) -> int:
    """Download receipts for the given expense ids, best-effort + rate-limited, committing every ~10 so a
    timeout/restart keeps progress. Re-checks each expense (skips one that gained a receipt meanwhile).
    Returns the count downloaded."""
    if _backfill_lock.locked():  # another backfill is already running (asyncio: safe, no await before acquire)
        log.info("receipt backfill already in progress; skipping this run")
        return 0
    async with _backfill_lock:
        downloaded = 0
        for i, eid in enumerate(expense_ids):
            expense = await session.scalar(
                select(Expense).where(Expense.id == eid).options(selectinload(Expense.receipts)))
            if expense is None or expense.receipts or not expense.splitwise_receipt_url:
                continue
            if await download_to_minio(session, expense_id=eid,
                                       receipt_url=expense.splitwise_receipt_url, access_token=access_token):
                downloaded += 1
            if (i + 1) % 10 == 0:
                await session.commit()
            await asyncio.sleep(rate_delay)
        await session.commit()
        return downloaded


async def download_to_minio(
    session: AsyncSession, *, expense_id: UUID, receipt_url: str, access_token: str
) -> bool:
    """Fetch the receipt's original-size image with the OAuth token and store it in MinIO as a Receipt
    attached to `expense_id`. Best-effort: returns True on success, False on any failure (so one bad
    receipt never aborts a batch). Adds the row to the session; the caller commits."""
    url = sw_client.receipt_url_with_size(receipt_url, "original")
    try:
        content, content_type = await asyncio.to_thread(
            sw_client.fetch_receipt_bytes, access_token, url
        )
    except Exception:
        return False
    await asyncio.to_thread(minio_client.ensure_bucket)
    object_key = minio_client.build_object_key(expense_id, content_type)
    await asyncio.to_thread(minio_client.put_object, object_key, content, content_type)
    session.add(
        Receipt(
            expense_id=expense_id,
            bucket=settings.minio_bucket,
            object_key=object_key,
            content_type=content_type,
        )
    )
    return True
