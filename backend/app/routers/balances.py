import asyncio
import logging
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.auth import require_auth
from app.auth.scope import assert_group_member
from app.db import get_session
from app.integrations.splitwise import client as sw_client
from app.models import Expense, Group, GroupMember, Split, User
from app.models.splitwise_token import SplitwiseToken
from app.schemas.balance import BalanceEntry, FriendBalance, FriendGroupBalance
from app.services import friend_balances

logger = logging.getLogger(__name__)

router = APIRouter(tags=["balances"])


async def _compute(
    session: AsyncSession, group_id: UUID | None, caller: str | None = None
) -> list[BalanceEntry]:
    paid = func.coalesce(func.sum(Split.paid_share), 0).label("paid")
    owed = func.coalesce(func.sum(Split.owed_share), 0).label("owed")
    stmt = (
        select(Split.user_identifier, paid, owed)
        .join(Expense, Split.expense_id == Expense.id)
        .group_by(Split.user_identifier)
    )
    if group_id is not None:
        stmt = stmt.where(Expense.group_id == group_id)
    else:
        # Overall: exclude groups superseded by a local import, and (when scoped) only the caller's groups.
        stmt = stmt.join(Group, Expense.group_id == Group.id).where(Group.superseded_at.is_(None))
        if caller is not None:
            stmt = stmt.where(
                Expense.group_id.in_(
                    select(GroupMember.group_id).where(GroupMember.user_identifier == caller)
                )
            )

    rows = (await session.execute(stmt)).all()
    identifiers = [r.user_identifier for r in rows]
    names: dict[str, str] = {}
    if identifiers:
        users = await session.scalars(select(User).where(User.identifier.in_(identifiers)))
        names = {u.identifier: u.display_name for u in users}

    return [
        BalanceEntry(
            identifier=r.user_identifier,
            display_name=names.get(r.user_identifier),
            paid_total=r.paid,
            owed_total=r.owed,
            net=r.paid - r.owed,
        )
        for r in rows
    ]


@router.get("/balances", response_model=list[BalanceEntry])
async def overall_balances(
    caller: str | None = Depends(require_auth), session: AsyncSession = Depends(get_session)
) -> list[BalanceEntry]:
    return await _compute(session, None, caller)


async def _splitwise_token(session: AsyncSession, caller: str | None) -> SplitwiseToken | None:
    """The caller's OWN Splitwise token. A real authenticated caller only ever resolves to their own token - 
    never another user's (else a tokenless caller would see someone else's friends). The lone-token fallback
    is only safe in open mode (`caller is None`, single-user dev). None when the caller has no token."""
    if caller is not None:
        return await session.scalar(
            select(SplitwiseToken).where(SplitwiseToken.user_identifier == caller)
        )
    tokens = (await session.scalars(select(SplitwiseToken))).all()
    return tokens[0] if len(tokens) == 1 else None


async def _splitwise_friends(
    session: AsyncSession, token: SplitwiseToken, sw_map: dict[str, str]
) -> list[FriendBalance]:
    """Splitwise's authoritative current friend balances (its own ledger nets settle-ups across groups, so it's
    the source of truth - not a sum of per-expense repayments). Mapped to local identifiers so the app resolves
    names/avatars from its user directory. Positive net = that person owes the caller."""
    friends = await asyncio.to_thread(sw_client.fetch_friends, sw_client.make_client(token.access_token))
    # Local group names by Splitwise group id, so each per-group row can show the cached name + link locally.
    group_rows = await session.execute(
        select(Group.splitwise_group_id, Group.name).where(Group.splitwise_group_id.is_not(None))
    )
    group_names = {sw_gid: name for sw_gid, name in group_rows}

    def _sum(balances) -> Decimal:
        # Single-currency for now; multi-currency balances are summed (a known v1 simplification).
        return sum((Decimal(str(b["amount"])) for b in balances if b.get("amount")), Decimal(0))

    out: list[FriendBalance] = []
    for f in friends:
        identifier = sw_map.get(f["splitwise_id"]) or f"swuser_{f['splitwise_id']}"
        name = " ".join(p for p in (f.get("first_name"), f.get("last_name")) if p) or None
        groups = [
            FriendGroupBalance(
                splitwise_group_id=g["splitwise_group_id"],
                name=group_names.get(g["splitwise_group_id"]),
                net=_sum(g["balances"]),
            )
            for g in f.get("groups", [])
        ]
        out.append(FriendBalance(
            identifier=identifier, display_name=name, net=_sum(f["balances"]), groups=groups))
    return sorted(out, key=lambda fb: (fb.display_name or fb.identifier).lower())


async def resolve_friends(session: AsyncSession, caller: str | None) -> list[FriendBalance]:
    """The caller's current balance with each person, mirroring Splitwise's Friends tab. Sourced from
    Splitwise's authoritative `getFriends()` when a token is connected; otherwise computed server-side from the
    caller's group expenses (self-hosted fallback). Positive net = that person owes the caller. Shared by the
    /friends endpoint and the data export so both report the SAME authoritative balances."""
    if caller is None:
        return []  # no "me" (open mode)
    sw_rows = await session.execute(
        select(User.splitwise_user_id, User.identifier).where(User.splitwise_user_id.is_not(None))
    )
    sw_map = {sw_id: identifier for sw_id, identifier in sw_rows}

    token = await _splitwise_token(session, caller)
    if token is not None:
        try:
            return await _splitwise_friends(session, token, sw_map)
        except Exception:  # Splitwise unreachable -> fall back to the local computation below
            logger.warning("Splitwise getFriends failed; falling back to local balances", exc_info=True)

    # Fallback: derive from the caller's group expenses (correct for self-hosted; repayments path for
    # Splitwise-linked groups when the API is unavailable).
    expenses = (
        await session.scalars(
            select(Expense)
            .where(Expense.group_id.notin_(select(Group.id).where(Group.superseded_at.is_not(None))))
            .where(
                Expense.group_id.in_(
                    select(GroupMember.group_id).where(GroupMember.user_identifier == caller)
                )
            )
            .options(selectinload(Expense.splits))
        )
    ).all()
    nets = friend_balances.compute(caller, expenses, sw_map)
    if not nets:
        return []
    users = await session.scalars(select(User).where(User.identifier.in_(list(nets))))
    names = {u.identifier: u.display_name for u in users}
    return [
        FriendBalance(identifier=identifier, display_name=names.get(identifier), net=net)
        for identifier, net in sorted(nets.items(), key=lambda kv: (names.get(kv[0]) or kv[0]).lower())
    ]


@router.get("/friends", response_model=list[FriendBalance])
async def friends(
    caller: str | None = Depends(require_auth), session: AsyncSession = Depends(get_session)
) -> list[FriendBalance]:
    """The caller's current balance with each person, mirroring Splitwise's Friends tab (see
    `resolve_friends`)."""
    return await resolve_friends(session, caller)


@router.get("/groups/{group_id}/balances", response_model=list[BalanceEntry])
async def group_balances(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[BalanceEntry]:
    if await session.get(Group, group_id) is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    return await _compute(session, group_id)
