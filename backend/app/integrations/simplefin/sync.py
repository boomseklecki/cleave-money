"""SimpleFIN sync orchestration.

Mirrors plaid/sync.py, but SimpleFIN has no cursor and no `removed` list - it's a date-window poll:
  - initial backfill pages BACKWARD in 90-day windows (SimpleFIN's per-request cap) to the same depth Plaid
    uses (`plaid_transactions_days_requested`), stopping when a window yields no transactions - giving history
    parity with a freshly-linked Plaid item;
  - incremental syncs pull one short overlapping window;
  - pending rows that vanish from the fetched window are reaped (no `removed` list to lean on).
The SimpleFIN client is sync (`requests`); calls are wrapped in `asyncio.to_thread` like the Plaid layer.
"""
import asyncio
from datetime import UTC, date, datetime, timedelta
from uuid import UUID

from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.integrations import logos
from app.integrations.simplefin import mapper
from app.integrations.simplefin.client import SimpleFinError
from app.integrations.storage import minio_client
from app.models import Account, SimpleFinConnection, Transaction, TransactionSource
from app.services import spend as spend_svc

_WINDOW_DAYS = 90               # SimpleFIN caps each /accounts request at 90 days
_INCREMENTAL_OVERLAP_DAYS = 5   # re-pull recent rows to catch late edits + pending->posted
_DEFAULT_BACKFILL_DAYS = 730    # fallback depth if Plaid's day count is 0/omitted


def _epoch(dt: datetime) -> int:
    return int(dt.timestamp())


def is_stale(conn: SimpleFinConnection, threshold_minutes: int) -> bool:
    """True if the connection is due for a live sync - never synced, or older than the threshold. Gating on
    this in BOTH the scheduler and the manual-sync route keeps total GET /accounts requests well under
    SimpleFIN's ~24/day quota; exceeding it doesn't just throttle - it DISABLES the access token."""
    if conn.last_synced_at is None:
        return True
    return datetime.now(tz=UTC) - conn.last_synced_at >= timedelta(minutes=threshold_minutes)


def _error_messages(page: dict) -> list[str]:
    """SimpleFIN returns structured errors/warnings in a successful body (rate-limit warnings land here BEFORE
    the token is disabled) - the docs say always show them. Handle both `errors` (legacy) and `errlist` (v2),
    each a list of strings or {code, msg} objects."""
    out: list[str] = []
    for key in ("errors", "errlist"):
        for item in (page.get(key) or []):
            out.append(item if isinstance(item, str) else str(item.get("msg") or item))
    return out


async def _fetch_windows(client, access_url: str, since: datetime | None) -> dict:
    """Fetch the Account Set for the needed date range. `since` set (incremental) = one overlapping window;
    `since` None (first sync) = page backward 90 days at a time to the Plaid backfill depth, stopping once a
    window returns no transactions for any account. Returns the merged accounts + the earliest date fetched
    (`since_date`, used to bound the pending reap)."""
    now = datetime.now(tz=UTC)
    if since is not None:
        start = since - timedelta(days=_INCREMENTAL_OVERLAP_DAYS)
        page = await asyncio.to_thread(client.fetch_account_set, access_url, _epoch(start))
        return {"accounts": page.get("accounts", []), "since_date": start.date(),
                "warnings": _error_messages(page)}

    depth_days = settings.plaid_transactions_days_requested or _DEFAULT_BACKFILL_DAYS
    earliest = now - timedelta(days=depth_days)
    merged: dict[str, dict] = {}
    warnings: list[str] = []
    window_end = now
    reached = now
    while window_end > earliest:
        window_start = max(window_end - timedelta(days=_WINDOW_DAYS), earliest)
        page = await asyncio.to_thread(
            client.fetch_account_set, access_url, _epoch(window_start), _epoch(window_end))
        warnings.extend(_error_messages(page))
        any_txns = False
        for acct in page.get("accounts", []):
            slot = merged.setdefault(acct["id"], {**acct, "transactions": []})  # balance from the newest window
            txns = acct.get("transactions") or []
            if txns:
                any_txns = True
            slot["transactions"].extend(txns)
        reached = window_start
        window_end = window_start
        if not any_txns:
            break  # data exhausted for this connection
    return {"accounts": list(merged.values()), "since_date": reached.date(),
            "warnings": list(dict.fromkeys(warnings))}


async def _upsert_account(session: AsyncSession, conn_id: UUID, owner_identifier: str | None,
                          fields: dict) -> tuple[UUID, bool, date | None]:
    """Returns (account_id, feed, boundary): `feed` is False when this is a merged account whose primary_source
    isn't SimpleFIN - recognized (so no duplicate) but left to the owning source; `boundary` = merged_from_date
    (the caller skips txns dated <= it, so the preserved pre-merge history isn't re-imported)."""
    existing = (await session.execute(select(
        Account.id, Account.primary_source, Account.merged_from_date
    ).where(Account.simplefin_connection_id == conn_id,
            Account.simplefin_account_id == fields["simplefin_account_id"]))).first()
    if existing is not None and existing[1] is not None and existing[1] != TransactionSource.simplefin:
        return existing[0], False, None  # suppressed: another source feeds this merged account
    values = {
        "simplefin_connection_id": conn_id,
        "simplefin_account_id": fields["simplefin_account_id"],
        "owner_identifier": owner_identifier,
        "name": fields["name"],
        "mask": fields.get("mask"),
        "currency": fields["currency"],
        "balance": fields["balance"],
        "available_balance": fields["available_balance"],
        "institution_name": fields["institution_name"],
        "institution_domain": fields["institution_domain"],
    }
    update_cols = {k: values[k] for k in ("owner_identifier", "name", "mask", "currency", "balance",
                                          "available_balance", "institution_name", "institution_domain")}
    update_cols["updated_at"] = func.now()  # on_conflict bypasses onupdate; track last sync (see plaid/sync)
    stmt = (
        pg_insert(Account)
        .values(**values)
        .on_conflict_do_update(
            index_elements=[Account.simplefin_connection_id, Account.simplefin_account_id],
            index_where=Account.simplefin_connection_id.isnot(None),
            set_=update_cols,
        )
        .returning(Account.id)
    )
    account_id = (await session.execute(stmt)).scalar_one()
    return account_id, True, (existing[2] if existing is not None else None)


async def _upsert_transaction(session: AsyncSession, account_id: UUID, currency: str, fields: dict,
                              owner_identifier: str | None) -> None:
    values = {
        "account_id": account_id,
        "external_transaction_id": fields["external_transaction_id"],
        "source": TransactionSource.simplefin,
        "description": fields["description"],
        "amount": fields["amount"],
        "currency": currency,
        "date": fields["date"],
        "pending": fields["pending"],
        "owner_identifier": owner_identifier,
    }
    # Never touch category (SimpleFIN has none - the on-device resolver owns it) or user-override tables.
    update_cols = {k: values[k] for k in ("description", "amount", "currency", "date", "pending",
                                          "owner_identifier")}
    update_cols["updated_at"] = func.now()
    stmt = (
        pg_insert(Transaction)
        .values(**values)
        .on_conflict_do_update(
            index_elements=[Transaction.account_id, Transaction.external_transaction_id],
            index_where=Transaction.external_transaction_id.isnot(None),
            set_=update_cols,
        )
    )
    await session.execute(stmt)


async def _reap_stale_pending(session: AsyncSession, seen_by_account: dict[UUID, set[str]],
                              since_date: date) -> int:
    """A pending charge that posts under a new id (or is canceled) vanishes from the fetched window. Within the
    window we DID fetch, any SimpleFIN pending row we didn't see this run is gone - delete it. Bounded to
    pending rows (few, recent), so the in-Python membership check stays cheap."""
    reaped = 0
    for account_id, seen_ids in seen_by_account.items():
        rows = (await session.execute(select(Transaction.id, Transaction.external_transaction_id).where(
            Transaction.account_id == account_id,
            Transaction.source == TransactionSource.simplefin,
            Transaction.pending.is_(True),
            Transaction.date >= since_date))).all()
        stale = [tid for tid, ext in rows if ext not in seen_ids]
        if stale:
            await session.execute(delete(Transaction).where(Transaction.id.in_(stale)))
            reaped += len(stale)
    return reaped


async def apply_sync(session: AsyncSession, conn: SimpleFinConnection, fetched: dict) -> dict:
    accounts = fetched.get("accounts", [])
    seen_by_account: dict[UUID, set[str]] = {}
    n_txns = 0
    for acct in accounts:
        af = mapper.map_account(acct)
        account_id, feed, boundary = await _upsert_account(session, conn.id, conn.user_identifier, af)
        if not feed:
            continue  # suppressed: another source feeds this merged account
        seen = seen_by_account.setdefault(account_id, set())
        for t in acct.get("transactions") or []:
            tf = mapper.map_transaction(t)
            if boundary is not None and tf["date"] <= boundary:
                continue  # feed-forward: preserve the pre-merge history from the other source
            await _upsert_transaction(session, account_id, af["currency"], tf, conn.user_identifier)
            seen.add(tf["external_transaction_id"])
            n_txns += 1
    reaped = await _reap_stale_pending(session, seen_by_account, fetched.get("since_date") or date.min)

    # Surface any SimpleFIN warnings (e.g. approaching the request quota) on the connection so the app can show
    # them - the docs say always display these, and heeding a quota warning avoids the token being disabled.
    warnings = fetched.get("warnings") or []
    conn.last_synced_at = datetime.now(tz=UTC)
    conn.status = "WARNING" if warnings else "HEALTHY"
    conn.error = "; ".join(warnings)[:512] or None
    await session.commit()

    # Evaluate this owner's solo spend budgets after the commit (best-effort, self-isolated) - as Plaid does.
    if conn.user_identifier:
        await spend_svc.evaluate_budget_push(session, {conn.user_identifier})

    return {"accounts": len(accounts), "transactions": n_txns, "reaped": reaped, "warnings": warnings}


async def _prewarm_logos(fetched: dict) -> None:
    """Best-effort: seed the /logos favicon for each institution domain so the app's first request is a cache
    hit. Branding is per-account (SimpleFIN `org.domain`), unlike Plaid's per-item institution."""
    domains = {(a.get("org") or {}).get("domain") for a in fetched.get("accounts", [])}
    for domain in domains:
        if not domain:
            continue
        try:
            favicon = await asyncio.to_thread(logos.fetch_favicon, domain)
            if favicon:
                await asyncio.to_thread(minio_client.put_object, logos.object_key(domain), favicon, "image/png")
        except Exception:
            pass  # logo seeding is best-effort; the favicon proxy still resolves on demand


async def sync_connection(session: AsyncSession, conn: SimpleFinConnection, client) -> dict:
    """Fetch + apply one connection. On a credential/payment error, record it on the connection and re-raise
    so the caller can isolate it (mirrors the Plaid per-item try/except)."""
    try:
        fetched = await _fetch_windows(client, conn.access_url, conn.last_synced_at)
    except SimpleFinError as exc:
        conn.status = "NEEDS_REAUTH" if exc.reauth else "PAYMENT_REQUIRED" if exc.payment else "ERROR"
        conn.error = str(exc)[:512]
        await session.commit()
        raise
    result = await apply_sync(session, conn, fetched)
    await _prewarm_logos(fetched)
    return result
