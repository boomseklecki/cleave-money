"""Write a self-hosted expense out to its Splitwise-linked group (two-way sync).

`build_payload` is pure (testable); the orchestration helpers translate a local
Expense + splits into Splitwise calls. Push-first: callers invoke these BEFORE
committing so local state never gets ahead of Splitwise.
"""
import asyncio

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import mapper
from app.models import SplitwiseToken, User


class NoSplitwiseToken(Exception):
    """Raised when no usable Splitwise token is stored for a push."""


def build_payload(expense: dict, splitwise_group_id: str, id_to_swid: dict[str, str],
                  category_id: int | None = None) -> dict:
    """Raises KeyError(identifier) if a participant has no Splitwise user id."""
    users = []
    for split in expense["splits"]:
        identifier = split["user_identifier"]
        swid = id_to_swid.get(identifier)
        if not swid:
            raise KeyError(identifier)
        users.append(
            {
                "user_id": swid,
                "paid_share": str(split["paid_share"]),
                "owed_share": str(split["owed_share"]),
            }
        )
    return {
        "cost": str(expense["amount"]),
        "description": expense["description"],
        "currency_code": expense["currency"],
        "date": expense["date"],
        "group_id": int(splitwise_group_id),
        "users": users,
        # The Splitwise "details" note (None if unset → cleared to "" at the SDK layer).
        "details": expense.get("notes"),
        # Splitwise category_id resolved from our category (None → Splitwise default); settle-ups omit it.
        "category_id": category_id,
        # Settle-ups push as Splitwise *payments* (so they settle balances rather than add a cost).
        "payment": expense.get("category") == mapper.SETTLEUP_CATEGORY,
    }


def _expense_to_dict(expense) -> dict:
    return {
        "amount": expense.amount,
        "description": expense.description,
        "currency": expense.currency,
        "date": expense.date.isoformat(),
        "category": expense.category,
        "notes": expense.notes,
        "splits": [
            {
                "user_identifier": s.user_identifier,
                "paid_share": s.paid_share,
                "owed_share": s.owed_share,
            }
            for s in expense.splits
        ],
    }


async def _resolve_swids(session: AsyncSession, identifiers: list[str]) -> dict[str, str]:
    if not identifiers:
        return {}
    rows = await session.scalars(select(User).where(User.identifier.in_(identifiers)))
    return {u.identifier: u.splitwise_user_id for u in rows if u.splitwise_user_id}


async def select_token_for_caller(session: AsyncSession, caller: str | None) -> SplitwiseToken:
    """The token to push a group-level op with (no expense to key on): the authenticated caller's, else the
    single stored token. Raises NoSplitwiseToken if none usable / ambiguous."""
    if caller:
        token = await session.scalar(
            select(SplitwiseToken).where(SplitwiseToken.user_identifier == caller)
        )
        if token is not None:
            return token
    tokens = (await session.scalars(select(SplitwiseToken))).all()
    if len(tokens) == 1:
        return tokens[0]
    raise NoSplitwiseToken()


async def select_token(session: AsyncSession, expense, caller: str | None = None) -> SplitwiseToken:
    """Prefer the authenticated caller's token (the user pushing), then the payer's token (split with
    paid_share > 0), then the single stored token. Raises NoSplitwiseToken if none usable. The caller
    fallback matters when the expense's payer identifier differs from the caller's `/me` (the identifier
    the token is stored under) and duplicate tokens make the single-token fallback ambiguous."""
    if caller:
        token = await session.scalar(
            select(SplitwiseToken).where(SplitwiseToken.user_identifier == caller)
        )
        if token is not None:
            return token
    payer_ids = [s.user_identifier for s in expense.splits if s.paid_share and s.paid_share > 0]
    if payer_ids:
        token = await session.scalar(
            select(SplitwiseToken).where(SplitwiseToken.user_identifier.in_(payer_ids))
        )
        if token is not None:
            return token
    tokens = (await session.scalars(select(SplitwiseToken))).all()
    if len(tokens) == 1:
        return tokens[0]
    raise NoSplitwiseToken()


async def _category_id(client, category: str | None) -> int | None:
    """Resolve our category to a Splitwise category_id (best-effort - never block a push on it)."""
    try:
        name_to_id = await asyncio.to_thread(sw_client.category_name_to_id, client)
    except Exception:
        return None
    return mapper.resolve_category_id(category, name_to_id)


async def _payload_for(session: AsyncSession, expense, group, client) -> dict:
    id_to_swid = await _resolve_swids(session, [s.user_identifier for s in expense.splits])
    category_id = await _category_id(client, expense.category)
    return build_payload(_expense_to_dict(expense), group.splitwise_group_id, id_to_swid, category_id)


async def push_create(session: AsyncSession, expense, group, client) -> str:
    payload = await _payload_for(session, expense, group, client)
    sw_id = await asyncio.to_thread(sw_client.create_expense, client, payload)
    expense.splitwise_expense_id = sw_id
    return sw_id


async def push_update(session: AsyncSession, expense, group, client) -> str:
    payload = await _payload_for(session, expense, group, client)
    return await asyncio.to_thread(
        sw_client.update_expense, client, expense.splitwise_expense_id, payload
    )


async def push_delete(client, splitwise_expense_id: str) -> None:
    await asyncio.to_thread(sw_client.delete_expense, client, splitwise_expense_id)
