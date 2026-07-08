import asyncio
import logging
from datetime import date as date_type
from datetime import datetime
from decimal import Decimal
from types import SimpleNamespace
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app import server_settings
from app.auth import require_auth
from app.auth.scope import assert_group_member, assert_transaction_readable
from app.config import settings
from app.db import get_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import writer as sw_writer
from app.integrations.splitwise.mapper import SETTLEUP_CATEGORY
from app.integrations.storage import minio_client
from app.models import (
    BackendType, Expense, ExpenseItem, ExpenseOverride, Group, GroupMember, Split, Transaction,
)
from app.services import notify as notify_svc
from app.schemas.expense import (
    ExpenseCreate,
    ExpenseOverrideUpdate,
    ExpenseResponse,
    ExpenseTransactionLink,
    ExpenseUpdate,
)
from app.utils import ensure_utc

log = logging.getLogger(__name__)

router = APIRouter(tags=["expenses"])

_TOLERANCE = Decimal("0.01")


async def _sync_to_splitwise(session, expense, group, op: str, sw_id: str | None = None,
                             caller: str | None = None) -> str | None:
    """Push a create/update/delete to the expense's Splitwise group (push-first).
    Maps failures: no token -> 409, missing Splitwise user id -> 422, upstream -> 502."""
    if not group.splitwise_group_id:
        raise HTTPException(status_code=400, detail="Splitwise group is missing splitwise_group_id")
    try:
        token = await sw_writer.select_token(session, expense, caller)
    except sw_writer.NoSplitwiseToken:
        raise HTTPException(
            status_code=409,
            detail="No Splitwise token stored; authorize via /auth/splitwise/login first",
        )
    client = sw_client.make_client(token.access_token)
    try:
        if op == "create":
            return await sw_writer.push_create(session, expense, group, client)
        if op == "update":
            return await sw_writer.push_update(session, expense, group, client)
        await sw_writer.push_delete(client, sw_id)
        return None
    except KeyError as exc:
        raise HTTPException(
            status_code=422, detail=f"No Splitwise user id for participant '{exc.args[0]}'"
        )
    except Exception as exc:  # SDK / upstream Splitwise error
        raise HTTPException(status_code=502, detail=f"Splitwise rejected the request: {exc}")


async def _push_splitwise_delete_by_swid(session, expense, sw_id: str, caller: str | None) -> None:
    """Delete a live Splitwise expense by id, INDEPENDENT of the local group's backend - the expense may sit
    in a self-hosted group (moved there, or a stale-id row) yet still exist on Splitwise. Selects the caller's
    /payer's token (no splitwise_group_id needed, unlike `_sync_to_splitwise`)."""
    try:
        token = await sw_writer.select_token(session, expense, caller)
    except sw_writer.NoSplitwiseToken:
        raise HTTPException(
            status_code=409,
            detail="No Splitwise token stored; authorize via /auth/splitwise/login first",
        )
    client = sw_client.make_client(token.access_token)
    try:
        await sw_writer.push_delete(client, sw_id)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Splitwise rejected the request: {exc}")


def _validate_splits(amount: Decimal, splits) -> None:
    """Splits must balance against the amount within a cent. Duck-typed on
    .paid_share / .owed_share so both SplitInput and Split ORM rows work."""
    if not splits:
        return
    paid = sum((s.paid_share for s in splits), Decimal(0))
    owed = sum((s.owed_share for s in splits), Decimal(0))
    if abs(paid - amount) > _TOLERANCE or abs(owed - amount) > _TOLERANCE:
        raise HTTPException(
            status_code=422,
            detail=f"Splits must balance: paid_share sum={paid}, owed_share sum={owed}, amount={amount}",
        )


def _split_rows(splits) -> list[Split]:
    return [
        Split(
            user_identifier=s.user_identifier,
            paid_share=s.paid_share,
            owed_share=s.owed_share,
        )
        for s in splits
    ]


def _item_rows(items, created_by: str | None = None) -> list[ExpenseItem]:
    return [
        ExpenseItem(name=i.name, quantity=i.quantity, price=i.price, category=i.category,
                    owner_identifier=i.owner_identifier, created_by=created_by)
        for i in items
    ]


def _apply_items(expense: Expense, items, editor: str | None) -> None:
    """Upsert items by id so added-by/added-on survive edits: existing items keep their identity
    (stamping updated_by only when a field changed), new items (id nil) are stamped with created_by,
    and items absent from the payload are dropped (delete-orphan)."""
    existing = {it.id: it for it in expense.items}
    result: list[ExpenseItem] = []
    for i in items:
        current = existing.get(i.id) if i.id is not None else None
        if current is not None:
            changed = (
                current.name != i.name or current.quantity != i.quantity
                or current.price != i.price or current.category != i.category
                or current.owner_identifier != i.owner_identifier
            )
            current.name = i.name
            current.quantity = i.quantity
            current.price = i.price
            current.category = i.category
            current.owner_identifier = i.owner_identifier
            if changed:
                current.updated_by = editor
            result.append(current)
        else:
            result.append(_item_rows([i], created_by=editor)[0])
    expense.items = result


_EXPENSE_OVERRIDE_FIELDS = ("include_in_spending", "include_in_cash_flow", "note")


async def _attach_expense_overrides(
    session: AsyncSession, caller: str | None, expenses: list[Expense]
) -> None:
    """Populate each expense's per-user budget flags from the caller's `expense_overrides` row (none in open
    mode); sets transient attributes the response serializes via `from_attributes`."""
    ids = [e.id for e in expenses]
    by_id: dict[UUID, ExpenseOverride] = {}
    if caller is not None and ids:
        rows = await session.scalars(
            select(ExpenseOverride).where(
                ExpenseOverride.owner_identifier == caller, ExpenseOverride.expense_id.in_(ids)
            )
        )
        by_id = {o.expense_id: o for o in rows}
    for e in expenses:
        o = by_id.get(e.id)
        for field in _EXPENSE_OVERRIDE_FIELDS:
            setattr(e, field, getattr(o, field) if o is not None else None)


async def _load_detail(
    session: AsyncSession, expense_id: UUID, caller: str | None = None
) -> Expense | None:
    stmt = (
        select(Expense)
        .where(Expense.id == expense_id)
        .options(
            selectinload(Expense.splits),
            selectinload(Expense.items),
            selectinload(Expense.receipts),
        )
    )
    expense = await session.scalar(stmt)
    if expense is not None:
        await _attach_expense_overrides(session, caller, [expense])
    return expense


async def _get_group_or_404(session: AsyncSession, group_id: UUID) -> Group:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    return group


async def _assert_linkable_transaction(
    session: AsyncSession, transaction_id: UUID | None, caller: str | None
) -> None:
    """A transaction an expense links to must exist (else 404 - the app's 'already posted' prompt keys off
    this) AND be readable by the caller (else 403 - you can only link a transaction you can see, mirroring the
    transaction read path). The link is a local FK only and never mutates the transaction."""
    if transaction_id is None:
        return
    transaction = await session.get(Transaction, transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    await assert_transaction_readable(session, transaction, caller)


@router.post("/expenses", response_model=ExpenseResponse, status_code=201)
async def create_expense(
    body: ExpenseCreate,
    caller: str | None = Depends(require_auth),
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
    session: AsyncSession = Depends(get_session),
) -> Expense:
    group = await _get_group_or_404(session, body.group_id)
    await assert_group_member(session, body.group_id, caller)
    # Idempotency (audit #9): a retried create with the same Idempotency-Key returns the ORIGINAL expense - 
    # no second row, and (crucially) no second Splitwise push_create. Header absent -> today's behavior.
    if idempotency_key is not None:
        prior = await session.scalar(select(Expense).where(
            Expense.created_by == body.created_by, Expense.client_key == idempotency_key))
        if prior is not None:
            return await _load_detail(session, prior.id, caller)
    await _assert_linkable_transaction(session, body.transaction_id, caller)
    if group.backend_type == BackendType.self_hosted:
        _validate_splits(body.amount, body.splits)

    expense = Expense(
        group_id=body.group_id,
        transaction_id=body.transaction_id,
        description=body.description,
        amount=body.amount,
        currency=body.currency or str(await server_settings.get(session, "default_currency")),
        date=body.date,
        category=body.category,
        notes=body.notes,
        created_by=body.created_by,
        client_key=idempotency_key,
    )
    expense.splits = _split_rows(body.splits)
    expense.items = _item_rows(body.items, created_by=body.created_by)
    if group.backend_type == BackendType.splitwise:
        # Push-first: create on Splitwise and stamp the returned id before committing. ACCEPTED residual
        # window (audit #9 option a): if the push succeeds but the commit below fails - or two same-key
        # requests race and both reach this push before either commits - a second Splitwise expense can be
        # created. It is knowingly accepted: the next Splitwise sync imports the orphan so it self-heals; the
        # far more common lost-response retry is already short-circuited above. (Self-hosted has no push, so
        # no residual window.)
        await _sync_to_splitwise(session, expense, group, "create", caller=caller)
    # Insert under a savepoint so a genuinely concurrent same-key double-submit resolves to ONE row (the loser
    # trips uq_expense_creator_client_key -> adopt the winner) instead of an unhandled IntegrityError/500. The
    # add happens INSIDE the savepoint so its rollback cleanly discards the losing row and leaves the session
    # usable - mirroring the per-transaction savepoint in statements.py.
    try:
        async with session.begin_nested():
            session.add(expense)
    except IntegrityError:
        prior = await session.scalar(select(Expense).where(
            Expense.created_by == body.created_by, Expense.client_key == idempotency_key))
        if prior is None:  # shouldn't happen (the conflict implies a winner) - let the caller retry
            raise HTTPException(status_code=409, detail="Concurrent create; please retry")
        return await _load_detail(session, prior.id, caller)
    await session.commit()
    # Notify the other members of a local group (Splitwise groups get Splitwise's own notifications).
    if group.backend_type == BackendType.self_hosted:
        actor = await notify_svc.display_name(session, caller)
        settle = body.category == SETTLEUP_CATEGORY
        await notify_svc.notify(
            session, await notify_svc.group_recipients(session, body.group_id),
            "settle_up" if settle else "expense_added",
            f"{actor} recorded a settle-up" if settle else f"{actor} added “{body.description}”",
            actor=caller, entity_type="expense", entity_id=str(expense.id))
    return await _load_detail(session, expense.id, caller)


@router.get("/expenses", response_model=list[ExpenseResponse])
async def list_expenses(
    group_id: UUID | None = None,
    since: date_type | None = None,
    until: date_type | None = None,
    updated_since: datetime | None = None,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Expense]:
    stmt = select(Expense).options(
        selectinload(Expense.splits),
        selectinload(Expense.items),
        selectinload(Expense.receipts),
    )
    if caller is not None:  # only expenses in groups the caller belongs to
        stmt = stmt.where(
            Expense.group_id.in_(
                select(GroupMember.group_id).where(GroupMember.user_identifier == caller)
            )
        )
    # Exclude expenses of a group that's been superseded by a local import (its expenses live on the clone).
    stmt = stmt.join(Group, Expense.group_id == Group.id).where(Group.superseded_at.is_(None))
    if group_id is not None:
        stmt = stmt.where(Expense.group_id == group_id)
    if since is not None:
        stmt = stmt.where(Expense.date >= since)
    if until is not None:
        stmt = stmt.where(Expense.date <= until)
    if updated_since is not None:
        stmt = stmt.where(Expense.updated_at >= ensure_utc(updated_since))
    stmt = stmt.order_by(Expense.date.desc(), Expense.created_at.desc()).limit(limit).offset(offset)
    rows = await session.scalars(stmt)
    expenses = list(rows)
    await _attach_expense_overrides(session, caller, expenses)
    return expenses


@router.get("/expenses/{expense_id}", response_model=ExpenseResponse)
async def get_expense(
    expense_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Expense:
    expense = await _load_detail(session, expense_id, caller)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)
    return expense


@router.patch("/expenses/{expense_id}", response_model=ExpenseResponse)
async def update_expense(
    expense_id: UUID,
    body: ExpenseUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Expense:
    expense = await _load_detail(session, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)

    original_group = await _get_group_or_404(session, expense.group_id)  # capture before any reassign
    target_group = await _get_group_or_404(session, body.group_id or expense.group_id)
    if body.group_id is not None:  # moving the expense - the caller must also be in the destination
        await assert_group_member(session, body.group_id, caller)
    await _assert_linkable_transaction(session, body.transaction_id, caller)
    # Moving a Splitwise-stamped expense OUT of its Splitwise group into a non-Splitwise group: the Splitwise
    # copy must be deleted + the id cleared, else the next sync re-matches by splitwise_expense_id and resets
    # group_id (reverting the move + clobbering local edits).
    moving_out_of_splitwise = (
        body.group_id is not None and body.group_id != original_group.id
        and original_group.backend_type == BackendType.splitwise
        and target_group.backend_type != BackendType.splitwise
        and expense.splitwise_expense_id is not None)
    new_amount = body.amount if body.amount is not None else expense.amount
    new_splits = _split_rows(body.splits) if body.splits is not None else list(expense.splits)
    if target_group.backend_type == BackendType.self_hosted:
        _validate_splits(new_amount, new_splits)

    # Push to Splitwise BEFORE mutating the tracked expense. Mutating first would dirty the row, and the
    # writer's first query autoflushes - taking UPDATE/DELETE/INSERT row locks that would then be held across
    # the 1–10s outbound HTTP call (idle-in-transaction, blocking a second user's PATCH / the importer). The
    # push instead reads a DETACHED snapshot of the desired new state, so with nothing dirty the autoflush is
    # a no-op and no lock spans the call. Push-first is preserved: an HTTP failure raises here with nothing
    # mutated or committed. Mutations + commit happen after, as a short local-only transaction.
    snapshot = SimpleNamespace(
        amount=new_amount,
        description=body.description if body.description is not None else expense.description,
        currency=body.currency if body.currency is not None else expense.currency,
        date=body.date if body.date is not None else expense.date,
        category=body.category if body.category is not None else expense.category,
        notes=body.notes if body.notes is not None else expense.notes,
        splits=new_splits,
        splitwise_expense_id=expense.splitwise_expense_id)
    created_swid = None
    if target_group.backend_type == BackendType.splitwise:
        # Push the edit; heal a pre-existing phantom (no id yet) by creating instead.
        if snapshot.splitwise_expense_id:
            await _sync_to_splitwise(session, snapshot, target_group, "update", caller=caller)
        else:
            created_swid = await _sync_to_splitwise(session, snapshot, target_group, "create", caller=caller)
    elif moving_out_of_splitwise:
        await _push_splitwise_delete_by_swid(session, snapshot, expense.splitwise_expense_id, caller)

    # Push succeeded - apply the mutations to the tracked entity and commit (no external call in this txn).
    if body.group_id is not None:
        expense.group_id = body.group_id
    if body.description is not None:
        expense.description = body.description
    if body.amount is not None:
        expense.amount = body.amount
    if body.currency is not None:
        expense.currency = body.currency
    if body.date is not None:
        expense.date = body.date
    if body.category is not None:
        expense.category = body.category
    if body.notes is not None:
        expense.notes = body.notes
    if body.updated_by is not None:
        expense.updated_by = body.updated_by
    if body.transaction_id is not None:
        expense.transaction_id = body.transaction_id
    if body.splits is not None:
        expense.splits = new_splits
    if body.items is not None:
        _apply_items(expense, body.items, body.updated_by)
    if created_swid is not None:
        expense.splitwise_expense_id = created_swid  # stamp the id from the heal-create
    if moving_out_of_splitwise:
        expense.splitwise_expense_id = None  # now a purely local expense - stops the resurrect-on-sync

    await session.commit()
    if target_group.backend_type == BackendType.self_hosted:
        actor = await notify_svc.display_name(session, caller)
        await notify_svc.notify(
            session, await notify_svc.group_recipients(session, expense.group_id),
            "expense_edited", f"{actor} edited “{expense.description}”", actor=caller,
            entity_type="expense", entity_id=str(expense.id))
    return await _load_detail(session, expense_id, caller)


@router.put("/expenses/{expense_id}/transaction-link", response_model=ExpenseResponse)
async def link_expense_transaction(
    expense_id: UUID,
    body: ExpenseTransactionLink,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Expense:
    """Link (or unlink, with null) this expense to a bank/manual transaction. A local-only field assigned
    directly - a separate endpoint from PATCH so it never triggers a Splitwise push or touches splits, and
    so null can clear the link (PATCH's transaction_id can only set)."""
    expense = await session.get(Expense, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)
    await _assert_linkable_transaction(session, body.transaction_id, caller)
    expense.transaction_id = body.transaction_id
    await session.commit()
    return await _load_detail(session, expense_id, caller)


async def _hard_delete(session: AsyncSession, expense: Expense) -> None:
    for receipt in expense.receipts:
        try:
            await asyncio.to_thread(minio_client.remove, receipt.object_key)
        except Exception:
            log.warning("receipt object cleanup failed (key=%s)", receipt.object_key, exc_info=True)
    await session.delete(expense)
    await session.commit()


@router.delete("/expenses/{expense_id}", status_code=204)
async def delete_expense(
    expense_id: UUID,
    propagate: bool | None = None,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Permanently delete the expense (hard delete + receipt cleanup). For a Splitwise-linked expense in an
    active group it also deletes it on Splitwise (so balances stay in parity); `propagate=false` keeps the
    Splitwise copy. To exclude an expense from your budget without deleting it, use the per-user override."""
    expense = await _load_detail(session, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)
    group = await session.get(Group, expense.group_id)
    # Capture before the row is gone (local groups only - Splitwise has its own notifications).
    local_recipients = (await notify_svc.group_recipients(session, expense.group_id)
                        if group is not None and group.backend_type == BackendType.self_hosted else set())
    description = expense.description

    if expense.splitwise_expense_id is not None:
        do_propagate = propagate if propagate is not None else (group.superseded_at is None)
        if do_propagate:
            # Propagate on the expense still being live on Splitwise (its splitwise_expense_id), NOT on the
            # local group's backend - a stamped expense in a self-hosted group would otherwise be locally
            # hard-deleted while its Splitwise copy survives + re-imports on the next sync. Group-independent
            # delete since a self-hosted group has no splitwise_group_id.
            await _push_splitwise_delete_by_swid(
                session, expense, expense.splitwise_expense_id, caller)
    await _hard_delete(session, expense)
    if local_recipients:
        actor = await notify_svc.display_name(session, caller)
        await notify_svc.notify(session, local_recipients, "expense_deleted",
                                f"{actor} deleted “{description}”", actor=caller)


@router.patch("/expenses/{expense_id}/override", response_model=ExpenseResponse)
async def update_expense_override(
    expense_id: UUID,
    body: ExpenseOverrideUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Expense:
    """Set the caller's per-user budget overrides (include in spending / cash flow) in `expense_overrides`,
    keyed by owner + expense. Only provided fields change (exclude_unset); null clears that field, and the row
    is dropped once every field is null. Never propagates to Splitwise and never touches balances."""
    expense = await _load_detail(session, expense_id, caller)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)
    if caller is not None:  # open mode has no per-user override to key on
        fields = body.model_dump(exclude_unset=True)
        override = await session.scalar(
            select(ExpenseOverride).where(
                ExpenseOverride.owner_identifier == caller, ExpenseOverride.expense_id == expense_id
            )
        )
        if override is None:
            override = ExpenseOverride(owner_identifier=caller, expense_id=expense_id)
            # Concurrent first-time override for the same (owner, expense) trips
            # uq_expense_override_owner_expense - adopt the winner and apply this request's fields, not a 500.
            try:
                async with session.begin_nested():
                    session.add(override)
            except IntegrityError:
                override = await session.scalar(
                    select(ExpenseOverride).where(
                        ExpenseOverride.owner_identifier == caller, ExpenseOverride.expense_id == expense_id
                    )
                )
        for field, value in fields.items():
            setattr(override, field, value)
        if all(getattr(override, field) is None for field in _EXPENSE_OVERRIDE_FIELDS):
            await session.delete(override)
        await session.commit()
    return await _load_detail(session, expense_id, caller)
