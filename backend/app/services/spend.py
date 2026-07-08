"""Server-side spend-by-category for a single owner - the solo slice of iOS `SpendingAnalytics`/`GoalProgress`,
enough to drive the budget-nearing/over push when the app is closed (the on-device number stays authoritative
on tap). Reuses the `CategoryResolver` + `category_builtin` spend-class sets so it agrees with the app.

Faithful to the app on the dominant path: linked-expense dedup (a Plaid transaction linked to a Splitwise
expense counts as the owed share, not the gross), per-user include flags (transaction→account, expense→group),
account-classification defaults, EXCLUDED filtering, itemized attribution (line items split a row across
categories - mirrors iOS `ItemizedSpend`), and combined **household** spend over shared-group expenses (both
partners' owed shares - mirrors `HouseholdBudget`). Drives both the solo and the shared budget push.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

import logging
from datetime import date as _date

from uuid import UUID

from .. import server_settings
from ..auth.scope import audience, caller_group_ids
from ..category_builtin import EXCLUDED_FROM_SPEND
from ..models.account import Account
from ..models.account_override import AccountOverride
from ..models.enums import TransactionSource
from ..models.expense import Expense
from ..models.expense_override import ExpenseOverride
from ..models.goal import Goal
from ..models.goal_budget_notification import GoalBudgetNotification
from ..models.group import Group
from ..models.group_override import GroupOverride
from ..models.transaction import Transaction
from ..models.transaction_override import TransactionOverride
from . import notify as notify_svc
from .category_resolver import CategoryResolver

log = logging.getLogger(__name__)

# Account classification (mirrors iOS AccountClassification): which kinds count toward spend.
_LIABILITY_SUBTYPES = {
    "credit card", "credit", "loan", "auto", "business", "commercial", "construction", "consumer",
    "home equity", "line of credit", "mortgage", "overdraft", "student",
}
_HOLDINGS_SUBTYPES = {
    "investment", "brokerage", "cd", "hsa", "ira", "roth", "roth ira", "sep ira", "simple ira",
    "401k", "401a", "403b", "457b", "529", "roth 401k", "mutual fund", "stock plan", "pension",
    "retirement", "keogh", "thrift savings plan", "tfsa", "rrsp", "rrif", "lira", "resp", "trust",
}


def _classify(account_type: str | None) -> str:
    key = (account_type or "").lower()
    if key in _LIABILITY_SUBTYPES:
        return "liability"
    if key in _HOLDINGS_SUBTYPES:
        return "savings"
    return "cash_flow"


def _account_counts_in_spending(account: Account | None, override: AccountOverride | None) -> bool:
    """Mirrors `Account.countsInSpending`: the per-account override wins, else cash-flow + liability count."""
    if override is not None and override.include_in_spending is not None:
        return override.include_in_spending
    kind = (override.kind if override and override.kind else None) or _classify(
        account.type if account else None)
    return kind in ("cash_flow", "liability")


def budget_status(spent: Decimal, target: Decimal) -> str:
    """`"under"` / `"nearing"` (≥85%) / `"over"` (>100%) - mirrors `GoalProgress.budgetStatus`."""
    if target <= 0:
        return "over" if spent > 0 else "under"
    if spent > target:
        return "over"
    return "nearing" if (spent / target) >= Decimal("0.85") else "under"


def month_bounds(month: date) -> tuple[date, date]:
    """First-of-month (inclusive) → first-of-next-month (exclusive)."""
    start = month.replace(day=1)
    end = start.replace(year=start.year + 1, month=1) if start.month == 12 else start.replace(
        month=start.month + 1)
    return start, end


def _item_category(resolver: CategoryResolver, raw: str | None, fallback: str | None) -> str | None:
    """Canonical category for a line item (mirrors iOS `CategoryMapping.canonical`): its own category, else the
    row's fallback (the transaction's effective / the expense's category)."""
    return resolver.resolve_expense(raw).category if raw else fallback


def _txn_contributions(transaction, effective: str | None,
                       resolver: CategoryResolver) -> list[tuple[str | None, Decimal]]:
    """Per-category contributions for a transaction, honoring line items (mirrors
    `ItemizedSpend.transactionDetailed`): each item at full price under its own category, the leftover
    (`amount − Σ prices`) under `effective`. No items → the whole amount under `effective`."""
    items = list(transaction.items)
    if not items:
        return [(effective, transaction.amount)]
    out: list[tuple[str | None, Decimal]] = []
    items_total = Decimal(0)
    for it in items:
        items_total += it.price
        if it.price != 0:
            out.append((_item_category(resolver, it.category, effective), it.price))
    remainder = transaction.amount - items_total
    if remainder != 0:
        out.append((effective, remainder))
    return out


def _expense_contributions(expense, me: str, owed: Decimal,
                           resolver: CategoryResolver) -> list[tuple[str | None, Decimal]]:
    """The owner's per-category share of an expense, honoring item ownership + the shared pool (mirrors
    `ItemizedSpend.detailed`). No items → the whole owed share under the expense category."""
    exp_cat = resolver.resolve_expense(expense.category).category
    items = list(expense.items)
    if not items:
        return [(exp_cat, owed)] if (owed > 0 and exp_cat) else []

    out: list[tuple[str | None, Decimal]] = []

    def add(raw: str | None, amount: Decimal) -> None:
        if amount > 0:
            out.append((_item_category(resolver, raw, exp_cat), amount))

    # Item ownership is local-only; a Splitwise expense's split syncs while items don't, so treat all its items
    # as shared (fully proportional to the synced owed share).
    honor_owners = expense.splitwise_expense_id is None

    def owner(it) -> str | None:
        return it.owner_identifier if honor_owners else None

    mine = [it for it in items if owner(it) == me]
    for it in mine:
        add(it.category, it.price)                       # items assigned to me → full price
    assigned_to_me = sum((it.price for it in mine), Decimal(0))

    pool_share = max(owed - assigned_to_me, Decimal(0))  # my share of the shared pool, spread by price
    if pool_share > 0:
        shared = [it for it in items if owner(it) is None]
        items_total = sum((it.price for it in items), Decimal(0))
        non_item_remainder = max(expense.amount - items_total, Decimal(0))  # tax/tip
        pool_total = sum((it.price for it in shared), Decimal(0)) + non_item_remainder
        if pool_total > 0:
            for it in shared:
                add(it.category, pool_share * it.price / pool_total)
            add(None, pool_share * non_item_remainder / pool_total)        # remainder → expense category
        else:
            add(None, pool_share)
    return out


async def spend_by_category(session: AsyncSession, owner: str | None, month: date) -> dict[str, Decimal]:
    """Outflow spend per canonical category for `owner` in `month`'s calendar month."""
    if owner is None:
        return {}
    start, end = month_bounds(month)
    resolver = await CategoryResolver.for_owner(session, owner)
    totals: dict[str, Decimal] = defaultdict(Decimal)

    accounts = {a.id: a for a in await session.scalars(
        select(Account).where(Account.owner_identifier == owner))}
    acct_ovr = {o.account_id: o for o in await session.scalars(
        select(AccountOverride).where(AccountOverride.owner_identifier == owner))}
    txn_ovr = {o.transaction_id: o for o in await session.scalars(
        select(TransactionOverride).where(TransactionOverride.owner_identifier == owner))}
    # Transactions a (any) expense links to: their gross side is dropped for the expense's owed share.
    linked = set(await session.scalars(
        select(Expense.transaction_id).where(Expense.transaction_id.is_not(None))))

    txns = await session.scalars(select(Transaction).options(selectinload(Transaction.items)).where(
        Transaction.owner_identifier == owner, Transaction.date >= start, Transaction.date < end))
    for t in txns:
        if t.id in linked:
            continue
        account = accounts.get(t.account_id) if t.account_id else None
        if t.source == TransactionSource.plaid and account is None:
            continue
        o = txn_ovr.get(t.id)
        in_spending = (o.include_in_spending if o is not None and o.include_in_spending is not None
                       else _account_counts_in_spending(account, acct_ovr.get(t.account_id)))
        if not in_spending or t.amount is None or t.amount <= 0:
            continue
        effective = resolver.resolve(t.category, override=(o.category if o else None),
                                     refined=(o.refined_category if o else None)).category
        # Itemized: split the row across item categories (the leftover falls under `effective`); the excluded
        # filter is per-contribution, so an item in an excluded category is dropped while its siblings count.
        for cat, amount in _txn_contributions(t, effective, resolver):
            if cat and cat not in EXCLUDED_FROM_SPEND:
                totals[cat] += amount

    exp_ovr = {o.expense_id: o for o in await session.scalars(
        select(ExpenseOverride).where(ExpenseOverride.owner_identifier == owner))}
    grp_ovr = {o.group_id: o for o in await session.scalars(
        select(GroupOverride).where(GroupOverride.owner_identifier == owner))}
    exps = await session.scalars(
        select(Expense).options(selectinload(Expense.splits), selectinload(Expense.items)).where(
            Expense.date >= start, Expense.date < end,
            # Exclude a Splitwise group superseded by a local import - its expenses live on the clone, so
            # counting both double-counts the spend and can fire a false budget push.
            Expense.group_id.notin_(select(Group.id).where(Group.superseded_at.is_not(None)))))
    for e in exps:
        mine = next((s for s in e.splits if s.user_identifier == owner), None)
        if mine is None:
            continue
        eo = exp_ovr.get(e.id)
        go = grp_ovr.get(e.group_id)
        inc = (eo.include_in_spending if eo is not None and eo.include_in_spending is not None
               else (go.include_in_spending if go is not None and go.include_in_spending is not None
                     else True))
        if not inc:
            continue
        share = mine.owed_share or Decimal(0)
        if share <= 0:
            continue
        # Itemized: split my owed share across item categories (excluded filtered per-contribution; NEUTRAL ⊂
        # EXCLUDED, so one check). Non-itemized falls back to the whole owed share under the expense category.
        for cat, amount in _expense_contributions(e, owner, share, resolver):
            if cat and cat not in EXCLUDED_FROM_SPEND:
                totals[cat] += amount

    return dict(totals)


async def _household(session: AsyncSession, owner: str) -> tuple[set[str], set[UUID]]:
    """The owner's accepted-connection partners + the groups both the owner and a partner belong to (the
    'shared' groups whose expenses count toward a household budget)."""
    partners = await audience(session, owner)
    if not partners:
        return set(), set()
    owner_groups = set(await caller_group_ids(session, owner))
    shared_group_ids: set[UUID] = set()
    for p in partners:
        shared_group_ids |= owner_groups & set(await caller_group_ids(session, p))
    return partners, shared_group_ids


async def household_spend_by_category(session: AsyncSession, owner: str, partners: set[str],
                                      shared_group_ids: set[UUID], month: date) -> dict[str, Decimal]:
    """Combined per-category spend for a household (`owner` + `partners`) over shared-group expenses in `month`
 - each member's item-aware owed share, summed (mirrors iOS `HouseholdBudget.combinedByCategory`).

    Categorized deterministically (empty resolver - no per-user overrides - so both partners agree); solo
    transactions never enter (shared-group *expenses* only); no include-flag or EXCLUDED filtering, matching
    `HouseholdBudget` (excluded contributions land under keys no budget targets)."""
    if not partners or not shared_group_ids:
        return {}
    start, end = month_bounds(month)
    resolver = CategoryResolver(lookup={})
    members = {owner} | partners
    totals: dict[str, Decimal] = defaultdict(Decimal)
    exps = await session.scalars(
        select(Expense).options(selectinload(Expense.splits), selectinload(Expense.items)).where(
            Expense.group_id.in_(shared_group_ids), Expense.date >= start, Expense.date < end,
            # Exclude a superseded (locally-imported) source group so its expenses aren't counted alongside
            # the clone's - same double-count guard as the solo path.
            Expense.group_id.notin_(select(Group.id).where(Group.superseded_at.is_not(None)))))
    for e in exps:
        for member in members:
            mine = next((s for s in e.splits if s.user_identifier == member), None)
            if mine is None:
                continue
            share = mine.owed_share or Decimal(0)
            if share <= 0:
                continue
            for cat, amount in _expense_contributions(e, member, share, resolver):
                if cat:
                    totals[cat] += amount
    return dict(totals)


_KIND_LABEL = {"nearing": "approaching", "over": "over"}


async def _fire_budget_push(session: AsyncSession, goal, spent: dict[str, Decimal],
                            recipients: set[str], month: date) -> None:
    """Fire the once-per-(goal, month, kind) budget push if `spent[goal.category]` crosses a threshold."""
    status = budget_status(spent.get(goal.category, Decimal(0)), goal.target_amount)
    if status not in ("nearing", "over"):
        return
    # One marker per (goal, month, kind) - under the goal owner; recipients fan out separately. Insert with
    # on_conflict_do_nothing + RETURNING so a concurrent run can't raise an IntegrityError here (which the
    # broad except in evaluate_budget_push would swallow *and* roll a real notify back with): if RETURNING is
    # empty another run already fired this marker, so skip the notify.
    inserted = await session.scalar(
        pg_insert(GoalBudgetNotification)
        .values(owner_identifier=goal.owner_identifier, goal_id=goal.id, period_month=month, kind=status)
        .on_conflict_do_nothing(constraint="uq_goal_budget_notif")
        .returning(GoalBudgetNotification.id))
    if inserted is None:
        return
    verb = _KIND_LABEL[status]
    content = (f"You're {verb} your {goal.category} budget this month."
               if status == "over"
               else f"You're {verb} your {goal.category} budget ({goal.name}) this month.")
    # notify() commits - flushing the marker added above in the same transaction.
    await notify_svc.notify(session, recipients, type=f"budget_{status}", content=content,
                            entity_type="goal", entity_id=str(goal.id))


async def evaluate_budget_push(session: AsyncSession, owners: set[str]) -> None:
    """Fire a budget push once per (goal, month, threshold) when the current month's spend crosses 85%
    (nearing) / 100% (over), for both **solo** goals and **shared/household** goals (combined partner spend over
    shared-group expenses). Gated by `budget_push_enabled`. Isolated + best-effort: never raises (so it can't
    break the sync that called it)."""
    if not owners:
        return
    try:
        if not bool(await server_settings.get(session, "budget_push_enabled")):
            return
        today = _date.today()
        month = today.replace(day=1)

        # Solo goals - each owner's own spend.
        for owner in owners:
            goals = list(await session.scalars(select(Goal).where(
                Goal.owner_identifier == owner, Goal.kind == "spend", Goal.archived_at.is_(None),
                Goal.shared.is_(False), Goal.category.is_not(None))))
            if not goals:
                continue
            spent = await spend_by_category(session, owner, month)
            for goal in goals:
                await _fire_budget_push(session, goal, spent, {owner}, month)

        # Shared/household goals - a spend by EITHER partner re-checks the goal, so expand each changed owner to
        # their household and evaluate every shared goal owned in it (deduped by goal). Each goal's household +
        # combined spend is derived from its own owner; both partners are notified.
        evaluated: set = set()
        for owner in owners:
            household_owners = {owner} | await audience(session, owner)
            shared_goals = list(await session.scalars(select(Goal).where(
                Goal.owner_identifier.in_(household_owners), Goal.kind == "spend",
                Goal.archived_at.is_(None), Goal.shared.is_(True), Goal.category.is_not(None))))
            for goal in shared_goals:
                if goal.id in evaluated:
                    continue
                evaluated.add(goal.id)
                partners, shared_group_ids = await _household(session, goal.owner_identifier)
                hspent = await household_spend_by_category(
                    session, goal.owner_identifier, partners, shared_group_ids, month)
                await _fire_budget_push(session, goal, hspent, {goal.owner_identifier} | partners, month)
    except Exception:
        log.exception("evaluate_budget_push failed")
        await session.rollback()
