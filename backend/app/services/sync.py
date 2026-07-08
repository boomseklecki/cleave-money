"""All-tenant data sync (Plaid + Splitwise), for the periodic scheduler.

Mirrors what the app's refresh buttons do, but server-side and for every linked item/token, with no request
context. Per-item/per-token failures are isolated and logged so one bad integration doesn't abort the rest.
"""
import logging
from datetime import datetime, timezone

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app import server_settings
from app.auth.scope import caller_group_ids
from app.config import settings
from app.integrations.plaid import client as plaid_client
from app.integrations.plaid import sync as plaid_sync
from app.integrations.simplefin import client as sf_client
from app.integrations.simplefin import sync as sf_sync
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import importer
from app.integrations.splitwise import receipts as sw_receipts
from app.models import Group, PlaidItem, SimpleFinConnection, SplitwiseToken

log = logging.getLogger(__name__)


async def sync_all_plaid(session: AsyncSession) -> int:
    """Cursor-incremental sync of every linked Plaid item. Returns the number of items synced."""
    item_ids = (await session.scalars(select(PlaidItem.id))).all()
    if not item_ids:
        return 0
    client = plaid_client.make_client()
    synced = 0
    for item_id in item_ids:
        # Lock the item for the sync so a concurrent user-triggered /plaid/sync can't process it at the same
        # time (cursor read-modify-write → redundant Plaid calls / page reprocessing). skip_locked: if a user
        # sync already holds it, skip it this tick rather than stall the scheduler; it's picked up next pass.
        # The lock releases when sync_item commits (or we roll back on failure below).
        item = await session.scalar(
            select(PlaidItem).where(PlaidItem.id == item_id).with_for_update(skip_locked=True))
        if item is None:
            continue
        try:
            await plaid_sync.sync_item(session, item, client)
            synced += 1
        except Exception:
            await session.rollback()  # release the lock + reset the tx so the next item isn't poisoned
            log.exception("Scheduled Plaid sync failed for item %s", item_id)
    return synced


async def sync_all_simplefin(session: AsyncSession) -> int:
    """Date-window sync of every SimpleFIN connection due for a refresh. Gated on staleness: SimpleFIN DISABLES
    the access token past ~24 requests/day, so a connection synced within refresh_simplefin_stale_minutes is
    skipped this tick (picked up once it ages out). Returns the number synced."""
    threshold = int(await server_settings.get(session, "refresh_simplefin_stale_minutes"))
    conn_ids = (await session.scalars(select(SimpleFinConnection.id))).all()
    if not conn_ids:
        return 0
    client = sf_client.make_client()
    synced = 0
    for conn_id in conn_ids:
        # skip_locked so a user-triggered /simplefin/sync holding the row doesn't stall the scheduler.
        conn = await session.scalar(
            select(SimpleFinConnection).where(SimpleFinConnection.id == conn_id).with_for_update(skip_locked=True))
        if conn is None or not sf_sync.is_stale(conn, threshold):
            continue
        try:
            await sf_sync.sync_connection(session, conn, client)
            synced += 1
        except Exception:
            await session.rollback()  # release the lock + reset the tx so the next connection isn't poisoned
            log.exception("Scheduled SimpleFIN sync failed for connection %s", conn_id)
    return synced


async def sync_all_splitwise(session: AsyncSession) -> int:
    """Incremental sync of every stored Splitwise token (groups + users + expenses), advancing each token's
    cursor. Returns the number of tokens synced."""
    # Iterate detached value tuples (not ORM instances): a per-token rollback expires every loaded instance,
    # so holding ORM rows across the loop would break the next token's attribute access on the async session.
    tokens = (await session.execute(select(
        SplitwiseToken.user_identifier, SplitwiseToken.access_token, SplitwiseToken.expenses_synced_at))).all()
    synced = 0
    for owner, access_token, expenses_synced_at in tokens:
        try:
            client = sw_client.make_client(access_token)
            updated_after = expenses_synced_at.isoformat() if expenses_synced_at else None
            started = datetime.now(timezone.utc)
            await importer.sync_groups(session, client, settings.splitwise_user_map)
            await importer.sync_users(session, client, settings.splitwise_user_map)
            await importer.sync_expenses(
                session, client, settings.splitwise_user_map, updated_after=updated_after, dry_run=False
            )
            await session.execute(update(SplitwiseToken)
                                  .where(SplitwiseToken.user_identifier == owner)
                                  .values(expenses_synced_at=started))
            await session.commit()
            synced += 1
        except Exception:
            await session.rollback()
            log.exception("Scheduled Splitwise sync failed for token %s", owner)
            continue
        # Notifications are a separate best-effort step (sync_notifications commits on its own, and pushes new
        # partner activity) - its failure must not roll back the expense cursor just committed above.
        try:
            retention = int(await server_settings.get(session, "notifications_retention_count"))
            await importer.sync_notifications(
                session, client, owner, retention=retention, access_token=access_token, push=True)
        except Exception:
            await session.rollback()
            log.exception("Scheduled Splitwise notification sync failed for token %s", owner)
    return synced


async def sync_notifications_all(session: AsyncSession) -> int:
    """Fast, notifications-only fan-out: pull each Splitwise token's recent notifications (and push new
    partner activity) WITHOUT the expensive groups/users/expenses sync. Per-token isolation (rollback +
    continue). Returns the number of tokens synced."""
    # Detached value tuples (see sync_all_splitwise): a per-token rollback expires loaded ORM instances.
    tokens = (await session.execute(
        select(SplitwiseToken.user_identifier, SplitwiseToken.access_token))).all()
    retention = int(await server_settings.get(session, "notifications_retention_count"))
    synced = 0
    for owner, access_token in tokens:
        try:
            client = sw_client.make_client(access_token)
            await importer.sync_notifications(
                session, client, owner, retention=retention, access_token=access_token, push=True)
            synced += 1
        except Exception:
            await session.rollback()
            log.exception("Notifications poll failed for token %s", owner)
    return synced


async def backfill_splitwise_receipts(
    session: AsyncSession, max_per_run: int = sw_receipts.BACKFILL_MAX_PER_RUN
) -> int:
    """Opportunistic, bounded, rate-limited receipt backfill during the scheduled sync, so new Splitwise
    receipts trickle into MinIO without a manual tap. Gated by `splitwise_receipt_backfill_enabled`; per token,
    newest-first, capped at `max_per_run`. Per-token isolation (rollback + continue). Returns the count."""
    if not await server_settings.get(session, "splitwise_receipt_backfill_enabled"):
        return 0
    tokens = (await session.scalars(select(SplitwiseToken))).all()
    total = 0
    for token in tokens:
        try:
            group_ids = await caller_group_ids(session, token.user_identifier)
            if not group_ids and len(tokens) == 1:   # single-tenant: id may not match memberships → all groups
                group_ids = list(await session.scalars(select(Group.id)))
            ids = await sw_receipts.pending_receipt_expense_ids(session, group_ids, limit=max_per_run)
            total += await sw_receipts.download_pending(session, ids, token.access_token)
        except Exception:
            await session.rollback()
            log.exception("Scheduled receipt backfill failed for token %s", token.user_identifier)
    return total


async def sync_all(session: AsyncSession) -> dict:
    plaid_items = await sync_all_plaid(session)
    simplefin_connections = await sync_all_simplefin(session)
    splitwise_tokens = await sync_all_splitwise(session)
    receipts = await backfill_splitwise_receipts(session)
    return {"plaid_items": plaid_items, "simplefin_connections": simplefin_connections,
            "splitwise_tokens": splitwise_tokens, "receipts": receipts}
