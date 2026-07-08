"""Scoped read paths for the export feature.

Each fetcher applies the same per-user scoping the live list endpoints use, but
without their `limit`/`offset` pagination (an export takes everything the caller
can see). Expenses/groups scope by group membership; transactions/accounts scope
by `owner_identifier`. In open mode (`caller is None`) scoping is bypassed, matching
the list endpoints. The per-user override attachers are reused from the routers so
exports carry the caller's notes/flags just like the API responses do.
"""
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models import Account, Expense, Group, GroupMember, Transaction
from app.routers.accounts import (
    _attach_account_overrides,
    _attach_overrides as _attach_transaction_overrides,
    _shared_in_accounts,
)
from app.routers.balances import resolve_friends
from app.routers.expenses import _attach_expense_overrides


def _member_group_ids(caller: str):
    return select(GroupMember.group_id).where(GroupMember.user_identifier == caller)


async def fetch_expenses(session: AsyncSession, caller: str | None) -> list[Expense]:
    stmt = (
        select(Expense)
        .options(
            selectinload(Expense.splits),
            selectinload(Expense.items),
            selectinload(Expense.receipts),
        )
        .join(Group, Expense.group_id == Group.id)
        .where(Group.superseded_at.is_(None))
    )
    if caller is not None:
        stmt = stmt.where(Expense.group_id.in_(_member_group_ids(caller)))
    stmt = stmt.order_by(Expense.date.desc(), Expense.created_at.desc())
    expenses = list(await session.scalars(stmt))
    await _attach_expense_overrides(session, caller, expenses)
    return expenses


async def fetch_transactions(session: AsyncSession, caller: str | None) -> list[Transaction]:
    stmt = select(Transaction).options(
        selectinload(Transaction.items), selectinload(Transaction.receipts)
    )
    if caller is not None:
        stmt = stmt.where(Transaction.owner_identifier == caller)
    stmt = stmt.order_by(Transaction.date.desc(), Transaction.created_at.desc())
    transactions = list(await session.scalars(stmt))
    await _attach_transaction_overrides(session, caller, transactions)
    return transactions


async def fetch_accounts(session: AsyncSession, caller: str | None) -> list[Account]:
    stmt = select(Account).order_by(Account.name)
    if caller is not None:
        stmt = stmt.where(Account.owner_identifier == caller)
    accounts = list(await session.scalars(stmt))
    await _attach_account_overrides(session, caller, accounts)
    if caller is not None:
        accounts += await _shared_in_accounts(session, caller)
    return accounts


async def fetch_balances(session: AsyncSession, caller: str | None) -> list[dict]:
    """The caller's net balance with each person (positive = they owe the caller). Uses the SAME authoritative
    resolver as the /friends tab: Splitwise's `getFriends()` ledger when a token is connected, falling back to
    the local group-expense computation only when it isn't (so the export matches what the app shows, not the
    stale sum-of-splits). Empty in open mode (no "me")."""
    friends = await resolve_friends(session, caller)
    return [
        {"identifier": f.identifier, "display_name": f.display_name, "net": f.net}
        for f in friends
    ]


async def fetch_groups(
    session: AsyncSession, caller: str | None
) -> tuple[list[Group], list[GroupMember]]:
    stmt = select(Group).where(Group.superseded_at.is_(None), Group.deleted_at.is_(None))
    if caller is not None:
        stmt = stmt.where(Group.id.in_(_member_group_ids(caller)))
    stmt = stmt.order_by(Group.name)
    groups = list(await session.scalars(stmt))
    members: list[GroupMember] = []
    if groups:
        members = list(
            await session.scalars(
                select(GroupMember)
                .where(GroupMember.group_id.in_([g.id for g in groups]))
                .order_by(GroupMember.group_id, GroupMember.user_identifier)
            )
        )
    return groups, members
