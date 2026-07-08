"""Plaid transaction sync orchestration.

`accumulate_sync` (the cursor pagination loop) takes an injectable page-fetcher so
it can be tested with a fake; `apply_sync` does the DB upserts/deletes.
"""
import asyncio
from datetime import date
from uuid import UUID

from sqlalchemy import delete, func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations import logos
from app.integrations.plaid import mapper
from app.integrations.storage import minio_client
from app.models import (
    Account, Expense, PlaidItem, Transaction, TransactionItem, TransactionOverride, TransactionSource,
)
from app.services import spend as spend_svc

_INSTITUTION_FIELDS = (
    "institution_name", "institution_domain", "institution_color", "institution_status",
)


def accumulate_sync(fetch_page, access_token: str, cursor: str | None) -> dict:
    """Page through /transactions/sync until has_more is false."""
    added: list[dict] = []
    modified: list[dict] = []
    removed: list[str] = []
    while True:
        page = fetch_page(access_token, cursor)
        added.extend(page["added"])
        modified.extend(page["modified"])
        removed.extend(page["removed"])
        cursor = page["next_cursor"]
        if not page["has_more"]:
            break
    return {"added": added, "modified": modified, "removed": removed, "cursor": cursor}


async def _upsert_account(
    session: AsyncSession, item_id: UUID, fields: dict, owner_identifier: str | None = None,
    institution: dict | None = None,
) -> tuple[UUID, bool, date | None]:
    """Upsert one account. Returns (account_id, feed, boundary): `feed` is False when this is a merged account
    whose primary_source isn't Plaid - we recognize it (return its id so we don't create a duplicate) but leave
    its balance/name to the owning source; `boundary` = merged_from_date (the caller skips txns dated <= it)."""
    existing = (await session.execute(select(
        Account.id, Account.primary_source, Account.merged_from_date
    ).where(Account.plaid_account_id == fields["plaid_account_id"]))).first()
    if existing is not None and existing[1] is not None and existing[1] != TransactionSource.plaid:
        return existing[0], False, None  # suppressed: another source feeds this merged account
    inst = {k: (institution or {}).get(k) for k in _INSTITUTION_FIELDS}  # denormalized branding
    values = {**fields, "plaid_item_id": item_id, "owner_identifier": owner_identifier, **inst}
    update_cols = {
        k: values[k]
        for k in ("name", "type", "mask", "balance", "available_balance", "currency", "plaid_item_id",
                  "owner_identifier", *_INSTITUTION_FIELDS)
    }
    # on_conflict_do_update bypasses SQLAlchemy's onupdate, so bump updated_at explicitly - this is what the
    # app's "Updated ... ago" reads, so it should track the last sync.
    update_cols["updated_at"] = func.now()
    stmt = (
        pg_insert(Account)
        .values(**values)
        .on_conflict_do_update(index_elements=[Account.plaid_account_id], set_=update_cols)
        .returning(Account.id)
    )
    account_id = (await session.execute(stmt)).scalar_one()
    return account_id, True, (existing[2] if existing is not None else None)


async def _upsert_transaction(
    session: AsyncSession, account_map: dict, fields: dict, owner_identifier: str | None = None
) -> None:
    values = {
        "account_id": account_map.get(fields["plaid_account_id"]),
        "plaid_transaction_id": fields["plaid_transaction_id"],
        "source": TransactionSource.plaid,
        "description": fields["description"],
        "amount": fields["amount"],
        "currency": fields["currency"],
        "date": fields["date"],
        "category": fields["category"],
        "pending": fields["pending"],
        "pending_transaction_id": fields.get("pending_transaction_id"),
        "owner_identifier": owner_identifier,
    }
    update_cols = {
        k: values[k]
        for k in ("account_id", "description", "amount", "currency", "date", "category",
                  "pending", "pending_transaction_id", "owner_identifier")
    }
    update_cols["updated_at"] = func.now()  # on_conflict bypasses onupdate; track last sync (see _upsert_account)
    stmt = (
        pg_insert(Transaction)
        .values(**values)
        .on_conflict_do_update(
            index_elements=[Transaction.plaid_transaction_id], set_=update_cols
        )
    )
    await session.execute(stmt)


async def _carry_pending_data(session: AsyncSession, transactions: list[dict]) -> None:
    """When a pending charge posts, Plaid re-IDs the posted row and lists the pending id in `removed` (deleted
    next, with an `ON DELETE CASCADE`/`SET NULL` that would drop the pending row's user data). Plaid's
    `pending_transaction_id` links the posted row back to the pending one, so carry that user data forward
    first: per-user overrides (category + budget toggles), receipt items, and any expense link."""
    links = [
        (t["pending_transaction_id"], t["plaid_transaction_id"])
        for t in transactions if t.get("pending_transaction_id")
    ]
    for pending_plaid_id, posted_plaid_id in links:
        by_plaid = dict((await session.execute(
            select(Transaction.plaid_transaction_id, Transaction.id).where(
                Transaction.plaid_transaction_id.in_([pending_plaid_id, posted_plaid_id])))).all())
        old_id, new_id = by_plaid.get(pending_plaid_id), by_plaid.get(posted_plaid_id)
        if not old_id or not new_id or old_id == new_id:
            continue  # pending already reaped in a prior sync, or posted not found → nothing to carry
        # Overrides are per-user (unique on owner+txn): re-point only owners who haven't already overridden
        # the posted row, so we never clobber a categorization the user set after it posted.
        taken = set((await session.scalars(select(TransactionOverride.owner_identifier).where(
            TransactionOverride.transaction_id == new_id))).all())
        for o in (await session.scalars(select(TransactionOverride).where(
                TransactionOverride.transaction_id == old_id))).all():
            if o.owner_identifier not in taken:
                o.transaction_id = new_id
        # Items + expense link have no per-user uniqueness → plain bulk re-point.
        await session.execute(update(TransactionItem)
                              .where(TransactionItem.transaction_id == old_id).values(transaction_id=new_id))
        await session.execute(update(Expense)
                              .where(Expense.transaction_id == old_id).values(transaction_id=new_id))
    await session.flush()  # land the re-points before the `removed` DELETE / its cascade


async def apply_sync(
    session: AsyncSession, item: PlaidItem, accounts: list[dict], sync_result: dict
) -> dict:
    institution = {k: getattr(item, k) for k in _INSTITUTION_FIELDS}  # denormalize the item's branding
    account_map: dict[str, UUID] = {}
    feed_info: dict[UUID, tuple[bool, date | None]] = {}  # account_id -> (Plaid feeds it?, feed-forward boundary)
    for account in accounts:
        fields = mapper.map_account(account)
        account_id, feed, boundary = await _upsert_account(
            session, item.id, fields, owner_identifier=item.user_identifier, institution=institution
        )
        account_map[fields["plaid_account_id"]] = account_id
        feed_info[account_id] = (feed, boundary)

    for transaction in sync_result["added"] + sync_result["modified"]:
        fields = mapper.map_transaction(transaction)
        feed, boundary = feed_info.get(account_map.get(fields["plaid_account_id"]), (True, None))
        if not feed:
            continue  # suppressed: another source feeds this merged account
        if boundary is not None and fields["date"] <= boundary:
            continue  # feed-forward: preserve the pre-merge history from the other source
        await _upsert_transaction(session, account_map, fields, owner_identifier=item.user_identifier)

    # Carry pending-row user data onto the just-posted rows before the pending rows are removed below.
    await _carry_pending_data(session, sync_result["added"] + sync_result["modified"])

    if sync_result["removed"]:
        await session.execute(
            delete(Transaction).where(
                Transaction.plaid_transaction_id.in_(sync_result["removed"])
            )
        )

    item.transactions_cursor = sync_result["cursor"]
    await session.commit()

    # After the sync is durably committed, evaluate this owner's solo spend budgets and fire a
    # nearing/over push (once per month). Self-isolated + best-effort - never affects the sync result.
    if item.user_identifier:
        await spend_svc.evaluate_budget_push(session, {item.user_identifier})

    return {
        "accounts": len(accounts),
        "added": len(sync_result["added"]),
        "modified": len(sync_result["modified"]),
        "removed": len(sync_result["removed"]),
    }


async def resolve_institution(item: PlaidItem, client) -> None:
    """Fetch the item's institution branding from Plaid and cache it on the item (best-effort). Also pre-warms
    MinIO with both logo variants so the app can offer a per-bank Icon/Logo choice: the favicon at
    `logos/{domain}.img` (the default avatar - square marks read better) and Plaid's full logo at
    `logos/{domain}.plaid.img` (served via `/logos/{domain}?variant=plaid`). Pre-warming means the app's first
    `/logos/{domain}` request is an immediate cache hit."""
    info = await asyncio.to_thread(client.get_institution, item.access_token)
    if not info:
        return
    item.institution_id = info.get("institution_id") or item.institution_id
    item.institution_name = info.get("name") or item.institution_name
    item.institution_domain = info.get("domain") or item.institution_domain
    item.institution_color = info.get("primary_color") or item.institution_color
    item.institution_status = info.get("status") or item.institution_status
    domain = item.institution_domain
    if domain:
        favicon = await asyncio.to_thread(logos.fetch_favicon, domain)
        # Seed both variants so the app can switch this bank between Icon (favicon) and Logo (Plaid's).
        # The default key is favicon-first, falling back to Plaid's logo when no favicon is available.
        plaid_logo = info.get("logo_bytes")
        for data, variant in ((favicon or plaid_logo, None), (plaid_logo, "plaid")):
            if not data:
                continue
            try:
                key = logos.object_key(domain, variant)
                await asyncio.to_thread(minio_client.put_object, key, data, "image/png")
            except Exception:
                pass  # logo seeding is best-effort; the favicon proxy still resolves on demand


async def sync_item(session: AsyncSession, item: PlaidItem, client) -> dict:
    # Resolve the institution's branding once (items linked before this, or before it resolved, have a null
    # institution_id). Best-effort - a failed lookup just leaves the fields null.
    if not item.institution_id:
        await resolve_institution(item, client)
    accounts = await asyncio.to_thread(client.get_accounts, item.access_token)
    sync_result = await asyncio.to_thread(
        accumulate_sync, client.fetch_transactions_page, item.access_token, item.transactions_cursor
    )
    return await apply_sync(session, item, accounts, sync_result)
