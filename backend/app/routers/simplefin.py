import asyncio
import logging
from collections import defaultdict
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app import server_settings
from app.auth import require_auth
from app.auth.scope import assert_owner
from app.db import get_session
from app.integrations.simplefin import client as sf_client
from app.integrations.simplefin import sync as sf_sync
from app.integrations.simplefin.client import SimpleFinError
from app.integrations.storage import minio_client
from app.models import Account, Receipt, SimpleFinConnection, Transaction, TransactionSource
from app.schemas.simplefin import (
    SimpleFinAccountMatch,
    SimpleFinCandidate,
    SimpleFinConnectionResponse,
    SimpleFinConnectRequest,
    SimpleFinConnectResponse,
    SimpleFinMaskRequest,
    SimpleFinMergeRequest,
    SimpleFinSyncRequest,
    SimpleFinSyncResponse,
)

log = logging.getLogger(__name__)

router = APIRouter(prefix="/simplefin", tags=["simplefin"])


async def _enabled_or_404(session: AsyncSession) -> None:
    if not await server_settings.get(session, "simplefin_enabled"):
        raise HTTPException(status_code=404, detail="SimpleFIN is not enabled on this server")


async def _match_candidates(session: AsyncSession, owner: str | None,
                            accounts: list[Account]) -> list[SimpleFinAccountMatch]:
    """For each just-connected SimpleFIN account, the existing non-SimpleFIN accounts at the same institution
    (domain canonicalized through the shared catalog) that it might duplicate - `strong` when the last-4 mask
    also matches. Drives the resolve sheet; the user decides (merge into one, choosing the feed, or keep new).
    We never auto-merge."""
    domains = {a.institution_domain for a in accounts if a.institution_domain}
    if not domains:
        return []
    rows = (await session.execute(select(
        Account.id, Account.name, Account.institution_name, Account.institution_domain, Account.mask,
        Account.plaid_account_id,
    ).where(
        Account.owner_identifier == owner,
        Account.simplefin_connection_id.is_(None),  # a Plaid or OFX/manual account, not another SimpleFIN one
        Account.institution_domain.in_(domains)))).all()
    by_domain: dict[str, list] = defaultdict(list)
    for r in rows:
        by_domain[r.institution_domain].append(r)
    matches: list[SimpleFinAccountMatch] = []
    for a in accounts:
        cands = by_domain.get(a.institution_domain)
        if not cands:
            continue
        matches.append(SimpleFinAccountMatch(
            account_id=a.id, name=a.name, institution_domain=a.institution_domain, mask=a.mask,
            candidates=[SimpleFinCandidate(
                account_id=c.id, name=c.name, institution_name=c.institution_name,
                institution_domain=c.institution_domain, mask=c.mask,
                source="plaid" if c.plaid_account_id else "manual",
                strong=bool(a.mask and c.mask and a.mask == c.mask),
            ) for c in cands]))
    return matches


@router.post("/connect", response_model=SimpleFinConnectResponse)
async def connect(
    body: SimpleFinConnectRequest,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> SimpleFinConnectResponse:
    await _enabled_or_404(session)
    client = sf_client.make_client()
    try:
        access_url = await asyncio.to_thread(client.claim, body.setup_token)
    except SimpleFinError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    conn = SimpleFinConnection(access_url=access_url, user_identifier=caller)
    session.add(conn)
    await session.flush()  # assign conn.id before the initial sync
    conn_id = conn.id

    warnings: list[str] = []
    try:
        result = await sf_sync.sync_connection(session, conn, client)  # initial backfill; commits
        warnings = list(result.get("warnings") or [])
    except SimpleFinError:
        pass  # sync_connection recorded status/error on the connection and committed it

    conn = await session.get(SimpleFinConnection, conn_id)  # re-load post-commit for status/error
    rows = list(await session.scalars(
        select(Account).where(Account.simplefin_connection_id == conn_id).order_by(Account.created_at)))
    matches = await _match_candidates(session, caller, rows)
    return SimpleFinConnectResponse(
        connection_id=conn_id, status=conn.status, error=conn.error, accounts=rows,
        warnings=warnings, matches=matches)


@router.post("/sync", response_model=SimpleFinSyncResponse)
async def run_sync(
    body: SimpleFinSyncRequest | None = None,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> SimpleFinSyncResponse:
    # Quota guard: SimpleFIN disables the token past ~24 requests/day, so skip any connection synced within
    # the staleness window instead of hitting the API - the app also gates this client-side (SmartRefresh).
    threshold = int(await server_settings.get(session, "refresh_simplefin_stale_minutes"))
    stmt = select(SimpleFinConnection.id)
    if caller is not None:
        stmt = stmt.where(SimpleFinConnection.user_identifier == caller)
    if body and body.connection_id:
        stmt = stmt.where(SimpleFinConnection.id == body.connection_id)
    conn_ids = (await session.scalars(stmt)).all()
    if not conn_ids:
        # A specific connection that doesn't exist is a 404; "sync all" with none linked is a graceful no-op
        # (the client runs this before reloading accounts, like the Plaid path).
        if body and body.connection_id:
            raise HTTPException(status_code=404, detail="SimpleFIN connection not found")
        return SimpleFinSyncResponse(
            connections_synced=0, skipped_fresh=0, accounts=0, transactions=0, reaped=0)

    client = sf_client.make_client()
    totals = {"accounts": 0, "transactions": 0, "reaped": 0}
    warnings: list[str] = []
    synced = skipped = 0
    for conn_id in conn_ids:
        conn = await session.scalar(
            select(SimpleFinConnection).where(SimpleFinConnection.id == conn_id).with_for_update())
        if conn is None:  # deleted between the id scan and the lock
            continue
        if not sf_sync.is_stale(conn, threshold):
            skipped += 1
            continue
        try:
            stats = await sf_sync.sync_connection(session, conn, client)
        except Exception:
            await session.rollback()  # release the lock + reset the tx (status was recorded pre-raise)
            log.exception("SimpleFIN sync failed for connection %s; skipping", conn_id)
            continue
        synced += 1
        for key in totals:
            totals[key] += stats.get(key, 0)
        warnings += stats.get("warnings") or []
    return SimpleFinSyncResponse(
        connections_synced=synced, skipped_fresh=skipped, warnings=list(dict.fromkeys(warnings)), **totals)


@router.get("/connections", response_model=list[SimpleFinConnectionResponse])
async def list_connections(
    caller: str | None = Depends(require_auth), session: AsyncSession = Depends(get_session)
) -> list[SimpleFinConnection]:
    stmt = select(SimpleFinConnection).options(selectinload(SimpleFinConnection.accounts))
    if caller is not None:
        stmt = stmt.where(SimpleFinConnection.user_identifier == caller)
    return list(await session.scalars(stmt.order_by(SimpleFinConnection.created_at)))


@router.delete("/connections/{connection_id}", status_code=204)
async def delete_connection(
    connection_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    # Unlink: delete locally - cascades the connection's accounts; also delete those accounts' transactions
    # (items + overrides cascade) so unlink removes all the connection's data. No remote revoke: SimpleFIN
    # access is revoked by the user at the Bridge; we just drop the stored Access URL.
    conn = await session.get(SimpleFinConnection, connection_id)
    if conn is None:
        raise HTTPException(status_code=404, detail="SimpleFIN connection not found")
    assert_owner(conn.user_identifier, caller)
    conn_accounts = select(Account.id).where(Account.simplefin_connection_id == connection_id)
    keys = await session.scalars(
        select(Receipt.object_key)
        .join(Transaction, Receipt.transaction_id == Transaction.id)
        .where(Transaction.account_id.in_(conn_accounts)))
    for key in keys:
        try:
            await asyncio.to_thread(minio_client.remove, key)
        except Exception:
            log.warning("receipt object cleanup failed (key=%s)", key, exc_info=True)  # don't block unlink
    await session.execute(delete(Transaction).where(Transaction.account_id.in_(conn_accounts)))
    await session.delete(conn)
    await session.commit()


@router.post("/merge", status_code=204)
async def merge(
    body: SimpleFinMergeRequest,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Fold a just-connected SimpleFIN account into an existing one, keeping the existing account as the home.
    `primary_source` picks the feed going forward; existing history is preserved and the primary only imports
    transactions AFTER the boundary (the target's last existing txn date) - uniform feed-forward, no
    cross-source transaction dedup. The other linked sources are then recognized-but-suppressed by the syncs."""
    incoming = await session.get(Account, body.incoming_account_id)
    target = await session.get(Account, body.target_account_id)
    if incoming is None or target is None:
        raise HTTPException(status_code=404, detail="Account not found")
    assert_owner(incoming.owner_identifier, caller)
    assert_owner(target.owner_identifier, caller)
    if incoming.simplefin_connection_id is None:
        raise HTTPException(status_code=400, detail="The incoming account is not a SimpleFIN account")
    if incoming.id == target.id:
        raise HTTPException(status_code=400, detail="Cannot merge an account into itself")

    sf_conn_id, sf_acct_id, sf_mask = (
        incoming.simplefin_connection_id, incoming.simplefin_account_id, incoming.mask)
    # Boundary = the target's last existing transaction date (preserve everything up to here).
    boundary = await session.scalar(
        select(func.max(Transaction.date)).where(Transaction.account_id == target.id))

    if body.primary_source == TransactionSource.simplefin:
        # SimpleFIN feeds forward: drop its pre-boundary copies (target's history already covers that period),
        # move the rest onto the target.
        if boundary is not None:
            await session.execute(delete(Transaction).where(
                Transaction.account_id == incoming.id, Transaction.date <= boundary))
        await session.execute(update(Transaction).where(
            Transaction.account_id == incoming.id).values(account_id=target.id))
    else:
        # The target's existing source stays authoritative -> discard SimpleFIN's backfilled copies entirely.
        await session.execute(delete(Transaction).where(Transaction.account_id == incoming.id))

    await session.delete(incoming)          # remove the duplicate row (+ its SimpleFIN linkage)...
    await session.flush()                   # ...before the target adopts that same linkage (unique index)
    target.simplefin_connection_id = sf_conn_id
    target.simplefin_account_id = sf_acct_id
    target.primary_source = body.primary_source
    target.merged_from_date = boundary
    if sf_mask and not target.mask:         # adopt the SimpleFIN-derived last-4 if the target lacked one
        target.mask = sf_mask
    await session.commit()


@router.post("/accounts/{account_id}/mask", status_code=204)
async def set_mask(
    account_id: UUID,
    body: SimpleFinMaskRequest,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Set/clear the last-4 mask on an account (SimpleFIN has no mask field, so the user can type it) - it
    shows on the row and tightens future cross-source matching."""
    account = await session.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Account not found")
    assert_owner(account.owner_identifier, caller)
    account.mask = ((body.mask or "").strip()[-4:]) or None
    await session.commit()
