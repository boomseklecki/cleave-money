import asyncio
import logging
from datetime import date as date_type
from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app import server_settings
from app.auth import require_auth
from app.auth.scope import assert_owner, assert_transaction_readable, audience
from app.config import settings
from app.db import get_session
from app.models import (
    Account,
    AccountOverride,
    Expense,
    Receipt,
    Transaction,
    TransactionItem,
    TransactionOverride,
    User,
)
from app.models.enums import ShareLevel, TransactionSource
from app.schemas.account import ACCOUNT_KINDS, AccountCreate, AccountResponse, AccountUpdate
from app.services import notify as notify_svc
from app.schemas.transaction import (
    TransactionCreate,
    TransactionItemInput,
    TransactionOverrideUpdate,
    TransactionResponse,
    TransactionUpdate,
)
from app.utils import ensure_utc
from app.integrations.storage import minio_client

log = logging.getLogger(__name__)

router = APIRouter(tags=["accounts"])


async def _purge_receipt_objects(session: AsyncSession, txn_where) -> None:
    """Best-effort MinIO cleanup of receipts hanging off the matched transactions (the DB rows cascade on
    transaction/account delete, but the objects don't - mirrors groups._remove_group_receipts). Gather the
    object keys with a JOIN before the cascade fires, then remove each without blocking the delete."""
    keys = await session.scalars(
        select(Receipt.object_key)
        .join(Transaction, Receipt.transaction_id == Transaction.id)
        .where(txn_where))
    for key in keys:
        try:
            await asyncio.to_thread(minio_client.remove, key)
        except Exception:
            log.warning("receipt object cleanup failed (key=%s)", key, exc_info=True)  # don't block the delete


@router.get("/accounts", response_model=list[AccountResponse])
async def list_accounts(
    updated_since: datetime | None = None,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Account]:
    stmt = select(Account)
    if caller is not None:
        stmt = stmt.where(Account.owner_identifier == caller)
    if updated_since is not None:
        stmt = stmt.where(Account.updated_at >= ensure_utc(updated_since))
    rows = list(await session.scalars(stmt.order_by(Account.name)))
    await _attach_account_overrides(session, caller, rows)
    for a in rows:  # own accounts: not shared-in
        a.shared_by = a.shared_by_identifier = None

    # Plus accounts a partner has shared with the caller (balances or full), read-only.
    shared = await _shared_in_accounts(session, caller)
    return rows + shared


async def _shared_in_accounts(session: AsyncSession, caller: str | None) -> list[Account]:
    """Accounts owned by the caller's accepted partners with a non-private `share_level`, tagged with the
    owner's display name (read-only to the caller; no per-caller overrides in v1)."""
    aud = await audience(session, caller)
    if not aud:
        return []
    rows = list(await session.scalars(
        select(Account).where(
            Account.owner_identifier.in_(aud), Account.share_level != ShareLevel.private
        ).order_by(Account.name)
    ))
    owners = {u.identifier: u for u in await session.scalars(
        select(User).where(User.identifier.in_({a.owner_identifier for a in rows})))}
    for a in rows:
        for field in _OVERRIDE_FIELDS:  # shared-in accounts show base values (no caller override)
            setattr(a, field, None)
        owner = owners.get(a.owner_identifier)
        a.shared_by = owner.display_name if owner else a.owner_identifier
        a.shared_by_identifier = a.owner_identifier
    return rows


_OVERRIDE_FIELDS = ("display_name", "kind", "include_in_spending", "include_in_cash_flow")


async def _attach_account_overrides(
    session: AsyncSession, caller: str | None, accounts: list[Account]
) -> None:
    """Populate each account's per-user override fields (display_name/kind/include_*) from the caller's
    `account_overrides` row (none in open mode). The columns moved to `account_overrides`; this sets transient
    attributes the response serializes via `from_attributes`."""
    ids = [a.id for a in accounts]
    by_id: dict = {}
    if caller is not None and ids:
        rows = await session.scalars(
            select(AccountOverride).where(
                AccountOverride.owner_identifier == caller, AccountOverride.account_id.in_(ids)
            )
        )
        by_id = {o.account_id: o for o in rows}
    for a in accounts:
        override = by_id.get(a.id)
        for field in _OVERRIDE_FIELDS:
            setattr(a, field, getattr(override, field) if override is not None else None)


@router.post("/accounts", response_model=AccountResponse, status_code=201)
async def create_account(
    body: AccountCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Account:
    account = Account(
        name=body.name,
        type=body.type,
        balance=body.balance,
        currency=body.currency or str(await server_settings.get(session, "default_currency")),
        owner_identifier=caller,
    )
    session.add(account)
    await session.commit()
    await session.refresh(account)
    await _attach_account_overrides(session, caller, [account])
    account.shared_by = account.shared_by_identifier = None
    return account


@router.patch("/accounts/{account_id}", response_model=AccountResponse)
async def update_account(
    account_id: UUID,
    body: AccountUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Account:
    """Set the caller's per-user account overrides (display name, kind, Goals-analytics inclusion flags) in
    `account_overrides`, keyed by owner + account. Plaid sync only touches name/type/balance/currency/mask, so
    these survive a re-sync."""
    account = await session.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Account not found")
    assert_owner(account.owner_identifier, caller)
    fields = body.model_dump(exclude_unset=True)
    # share_level is a real account column the owner sets directly (not a per-user override).
    if "share_level" in fields:
        level = fields.pop("share_level")
        was_private = account.share_level == ShareLevel.private
        try:
            account.share_level = ShareLevel(level)
        except ValueError:
            raise HTTPException(status_code=422, detail="share_level must be private/balances/full")
        await session.commit()
        await session.refresh(account)
        if was_private and account.share_level != ShareLevel.private:
            actor = await notify_svc.display_name(session, caller)
            await notify_svc.notify(session, await audience(session, caller), "account_shared",
                                    f"{actor} shared an account: {account.name}", actor=caller,
                                    entity_type="account", entity_id=str(account.id))
    if "display_name" in fields:
        # Empty/whitespace resets to Plaid's name.
        name = (fields["display_name"] or "").strip()
        fields["display_name"] = name or None
    if fields.get("kind") is not None and fields["kind"] not in ACCOUNT_KINDS:
        raise HTTPException(status_code=422, detail=f"kind must be one of {sorted(ACCOUNT_KINDS)}")
    if caller is not None and fields:  # open mode has no per-user override to key on
        override = await session.scalar(
            select(AccountOverride).where(
                AccountOverride.owner_identifier == caller, AccountOverride.account_id == account_id
            )
        )
        if override is None:
            override = AccountOverride(owner_identifier=caller, account_id=account_id)
            session.add(override)
        for field, value in fields.items():  # only the provided fields (exclude_unset) change
            setattr(override, field, value)
        # Drop the row once every override is cleared.
        if all(getattr(override, field) is None for field in _OVERRIDE_FIELDS):
            await session.delete(override)
        await session.commit()
        await session.refresh(account)  # reload the real columns after commit-expire
    await _attach_account_overrides(session, caller, [account])
    account.shared_by = account.shared_by_identifier = None
    return account


@router.delete("/accounts/{account_id}", status_code=204)
async def delete_account(
    account_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    account = await session.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Account not found")
    assert_owner(account.owner_identifier, caller)
    # Delete the account's transactions too (their items + per-user overrides cascade via FK) - a real
    # "delete all data for this account", not orphaning them with a null account_id.
    await _purge_receipt_objects(session, Transaction.account_id == account_id)  # objects don't cascade
    await session.execute(delete(Transaction).where(Transaction.account_id == account_id))
    await session.delete(account)
    await session.commit()


@router.get("/transactions", response_model=list[TransactionResponse])
async def list_transactions(
    account_id: UUID | None = None,
    since: date_type | None = None,
    until: date_type | None = None,
    updated_since: datetime | None = None,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Transaction]:
    # A `full`-shared partner account can be read by account_id (read-only); the unscoped list stays
    # caller-owned so shared data never enters the viewer's main list/analytics. Balances-only / private → 403.
    shared_full = False
    if caller is not None and account_id is not None:
        account = await session.get(Account, account_id)
        if account is not None and account.owner_identifier != caller:
            aud = await audience(session, caller)
            if account.owner_identifier in aud and account.share_level == ShareLevel.full:
                shared_full = True
            else:
                raise HTTPException(status_code=403, detail="Not permitted for this account.")

    stmt = select(Transaction).options(
        selectinload(Transaction.items), selectinload(Transaction.receipts)
    )
    if caller is not None and not shared_full:
        stmt = stmt.where(Transaction.owner_identifier == caller)
    if account_id is not None:
        stmt = stmt.where(Transaction.account_id == account_id)
    if since is not None:
        stmt = stmt.where(Transaction.date >= since)
    if until is not None:
        stmt = stmt.where(Transaction.date <= until)
    if updated_since is not None:
        stmt = stmt.where(Transaction.updated_at >= ensure_utc(updated_since))
    stmt = stmt.order_by(Transaction.date.desc(), Transaction.created_at.desc()).limit(limit).offset(offset)
    rows = list(await session.scalars(stmt))
    await _attach_overrides(session, caller, rows)
    return rows


# Override columns -> response. `category` surfaces as `category_override`; include flags + refined pass through.
_TXN_OVERRIDE_FIELDS = ("category", "include_in_spending", "include_in_cash_flow", "refined_category", "note")


async def _attach_overrides(
    session: AsyncSession, caller: str | None, transactions: list[Transaction]
) -> None:
    """Populate each transaction's per-user override fields (`category_override`, `include_in_spending`,
    `include_in_cash_flow`) from the caller's `transaction_overrides` row (none in open mode); sets transient
    attributes the response serializes via `from_attributes`."""
    ids = [t.id for t in transactions]
    by_id: dict[UUID, TransactionOverride] = {}
    if caller is not None and ids:
        rows = await session.scalars(
            select(TransactionOverride).where(
                TransactionOverride.owner_identifier == caller,
                TransactionOverride.transaction_id.in_(ids),
            )
        )
        by_id = {o.transaction_id: o for o in rows}
    # Reverse link: the expense (if any) pointing at each transaction, so the client can resolve the linked
    # expense without scanning its local cache. Ungated by caller (works in open + scoped mode).
    linked_by_txn: dict[UUID, UUID] = {}
    if ids:
        pairs = await session.execute(
            select(Expense.transaction_id, Expense.id).where(Expense.transaction_id.in_(ids))
        )
        linked_by_txn = {tid: eid for tid, eid in pairs.all()}
    for t in transactions:
        o = by_id.get(t.id)
        t.category_override = o.category if o is not None else None
        t.include_in_spending = o.include_in_spending if o is not None else None
        t.include_in_cash_flow = o.include_in_cash_flow if o is not None else None
        t.refined_category = o.refined_category if o is not None else None
        t.note = o.note if o is not None else None
        t.linked_expense_id = linked_by_txn.get(t.id)


async def _load_transaction(
    session: AsyncSession, transaction_id: UUID, caller: str | None = None
) -> Transaction | None:
    """Load a transaction with its items eagerly (async sessions can't lazy-load after the awaited query),
    and attach the caller's category override."""
    stmt = (
        select(Transaction)
        .options(selectinload(Transaction.items), selectinload(Transaction.receipts))
        .where(Transaction.id == transaction_id)
    )
    transaction = await session.scalar(stmt)
    if transaction is not None:
        await _attach_overrides(session, caller, [transaction])
    return transaction


@router.get("/transactions/{transaction_id}", response_model=TransactionResponse)
async def get_transaction(
    transaction_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Transaction:
    transaction = await _load_transaction(session, transaction_id, caller)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    await assert_transaction_readable(session, transaction, caller)
    return transaction


@router.patch("/transactions/{transaction_id}", response_model=TransactionResponse)
async def update_transaction(
    transaction_id: UUID,
    body: TransactionUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Transaction:
    """Set (or clear, with null) the caller's per-user category override in `transaction_overrides`, keyed by
    owner + transaction. The row also carries budget-inclusion flags (set via /override) and is dropped only
    once every field is null. Plaid sync only touches description/amount/currency/date/category/pending, so
    this survives a re-sync."""
    transaction = await session.get(Transaction, transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    assert_owner(transaction.owner_identifier, caller)
    if caller is not None:  # open mode has no per-user override to key on
        await _apply_txn_override(session, caller, transaction_id, category=body.category_override,
                                  set_category=True)
        await session.commit()
    return await _load_transaction(session, transaction_id, caller)


@router.patch("/transactions/{transaction_id}/override", response_model=TransactionResponse)
async def update_transaction_override(
    transaction_id: UUID,
    body: TransactionOverrideUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Transaction:
    """Set the caller's per-user budget overrides (include in spending / cash flow) on the transaction,
    keyed by owner + transaction. Only provided fields change (exclude_unset); coexists with the category
    override and never touches balances."""
    transaction = await session.get(Transaction, transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    assert_owner(transaction.owner_identifier, caller)
    if caller is not None:
        await _apply_txn_override(session, caller, transaction_id, **body.model_dump(exclude_unset=True))
        await session.commit()
    return await _load_transaction(session, transaction_id, caller)


async def _apply_txn_override(
    session: AsyncSession, caller: str, transaction_id: UUID, *, set_category: bool = False, **fields
) -> None:
    """Upsert the caller's (owner, transaction) override row with the provided fields (`category` is only
    written when `set_category` so the include-flag endpoint doesn't clear it), then drop the row once every
    field is null."""
    override = await session.scalar(
        select(TransactionOverride).where(
            TransactionOverride.owner_identifier == caller,
            TransactionOverride.transaction_id == transaction_id,
        )
    )
    if override is None:
        override = TransactionOverride(owner_identifier=caller, transaction_id=transaction_id)
        session.add(override)
    if set_category:
        override.category = fields.get("category")
    for field in ("include_in_spending", "include_in_cash_flow", "refined_category", "note"):
        if field in fields:
            setattr(override, field, fields[field])
    if all(getattr(override, field) is None for field in _TXN_OVERRIDE_FIELDS):
        await session.delete(override)


def _apply_transaction_items(
    transaction: Transaction, items: list[TransactionItemInput], editor: str | None
) -> None:
    """Upsert items by id so added-by/added-on survive edits: existing items keep their identity
    (stamping updated_by only when a field changed), new items (id nil) are stamped with created_by,
    and items absent from the payload are dropped (delete-orphan). Mirrors the expense version."""
    existing = {it.id: it for it in transaction.items}
    result: list[TransactionItem] = []
    for i in items:
        current = existing.get(i.id) if i.id is not None else None
        if current is not None:
            changed = (
                current.name != i.name or current.quantity != i.quantity
                or current.price != i.price or current.category != i.category
            )
            current.name = i.name
            current.quantity = i.quantity
            current.price = i.price
            current.category = i.category
            if changed:
                current.updated_by = editor
            result.append(current)
        else:
            result.append(TransactionItem(
                name=i.name, quantity=i.quantity, price=i.price, category=i.category, created_by=editor))
    transaction.items = result


@router.put("/transactions/{transaction_id}/items", response_model=TransactionResponse)
async def set_transaction_items(
    transaction_id: UUID,
    body: list[TransactionItemInput],
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Transaction:
    """Replace a transaction's line items (upsert by id, drop-orphan). A separate endpoint from PATCH so
    it never touches the category-override (whose omitted-clears semantics we must not trip)."""
    transaction = await _load_transaction(session, transaction_id, caller)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    assert_owner(transaction.owner_identifier, caller)
    _apply_transaction_items(transaction, body, editor=None)
    await session.commit()
    return await _load_transaction(session, transaction_id, caller)


@router.post("/transactions", response_model=TransactionResponse, status_code=201)
async def create_transaction(
    body: TransactionCreate,
    caller: str | None = Depends(require_auth),
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    session: AsyncSession = Depends(get_session),
) -> Transaction:
    # Idempotency (audit #9): a retried create with the same Idempotency-Key returns the ORIGINAL transaction
    # - no second row. Manual transactions never push to Splitwise, so there is no residual window. Header
    # absent -> today's behavior.
    if idempotency_key is not None:
        prior = await session.scalar(select(Transaction).where(
            Transaction.owner_identifier == caller, Transaction.client_key == idempotency_key))
        if prior is not None:
            return await _load_transaction(session, prior.id, caller)
    transaction = Transaction(
        account_id=body.account_id,
        source=TransactionSource.manual,
        description=body.description,
        amount=body.amount,
        currency=body.currency or str(await server_settings.get(session, "default_currency")),
        date=body.date,
        category=body.category,
        pending=body.pending,
        owner_identifier=caller,
        client_key=idempotency_key,
    )
    # Insert under a savepoint so a genuinely concurrent same-key double-submit resolves to ONE row (the loser
    # trips uq_txn_owner_client_key -> adopt the winner) instead of an unhandled IntegrityError/500. The add
    # happens INSIDE the savepoint so its rollback cleanly discards the losing row and leaves the session
    # usable - mirroring the per-transaction savepoint in statements.py.
    try:
        async with session.begin_nested():
            session.add(transaction)
    except IntegrityError:
        prior = await session.scalar(select(Transaction).where(
            Transaction.owner_identifier == caller, Transaction.client_key == idempotency_key))
        if prior is None:  # shouldn't happen (the conflict implies a winner) - let the caller retry
            raise HTTPException(status_code=409, detail="Concurrent create; please retry")
        return await _load_transaction(session, prior.id, caller)
    await session.commit()
    return await _load_transaction(session, transaction.id, caller)


@router.delete("/transactions/{transaction_id}", status_code=204)
async def delete_transaction(
    transaction_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    transaction = await session.get(Transaction, transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    assert_owner(transaction.owner_identifier, caller)
    await _purge_receipt_objects(session, Transaction.id == transaction_id)  # objects don't cascade
    await session.delete(transaction)
    await session.commit()
