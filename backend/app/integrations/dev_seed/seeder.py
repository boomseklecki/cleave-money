"""Idempotent per-identity synthetic seed - reused by the dev CLI and the demo guest login.

`seed_identity` gives one local identifier a populated, *isolated* sample app: a couple of shared-expense
groups (with synthetic co-members so names render), their expenses, and that identity's own accounts/
transactions/goals. Per-caller scoping then shows each identity only their own data.
"""
import asyncio
import json
import logging
from pathlib import Path
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.dev_seed import generator
from app.integrations.storage import minio_client
from app.models import (
    Account,
    CategoryMap,
    Connection,
    Expense,
    ExpenseItem,
    Goal,
    Group,
    GroupMember,
    SpendCategory,
    Split,
    Transaction,
    TransactionOverride,
    User,
    UserPreference,
)
from app.models.enums import BackendType, ConnectionStatus, ShareLevel, TransactionSource, UserSource

log = logging.getLogger(__name__)

_ASSETS = Path(__file__).parent / "assets"
_CONTENT_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}

# A seeded client-side merchant rule (the app restores it from this preference blob on launch): Target -> Household.
# Drives an Inbox "Your rule" categorize card in the demo (the AI-suggested variant needs on-device Apple
# Intelligence, unavailable in the Simulator). Format mirrors iOS MerchantPreferences.Snapshot.
_MERCHANT_PREFS_BLOB = json.dumps({
    "version": 1,
    "prefs": [
        {"pattern": "target", "note": "Target", "website": "target.com",
         "amountMode": "any", "category": "Household"},
    ],
})


async def _apply_avatar(entity, kind: str, asset: str) -> None:
    """Best-effort seed of a custom MinIO avatar on `entity` (a User or Group), mirroring the object-key
    scheme in `routers/avatars.py`. Sets the display + original objects to the same bundled image and stamps
    the entity's avatar columns. Swallows storage errors so a MinIO-less seed (e.g. a bare dev DB) still
    populates - the entity just keeps its default placeholder."""
    path = _ASSETS / asset
    content_type = _CONTENT_TYPES.get(path.suffix.lower(), "image/png")
    try:
        data = path.read_bytes()
        display = f"avatars/{kind}/{entity.id}/display.img"
        original = f"avatars/{kind}/{entity.id}/original.img"
        await asyncio.to_thread(minio_client.put_object, display, data, content_type)
        await asyncio.to_thread(minio_client.put_object, original, data, content_type)
    except Exception:
        log.warning("seed avatar upload skipped (kind=%s asset=%s)", kind, asset, exc_info=True)
        return
    entity.avatar_object_key = display
    entity.avatar_original_key = original
    entity.avatar_content_type = content_type


async def _ensure_user(session: AsyncSession, u: generator.SeedUser) -> None:
    if await session.scalar(select(User.id).where(User.identifier == u.identifier)) is None:
        session.add(User(identifier=u.identifier, display_name=u.display_name,
                         source=UserSource(u.source)))


async def seed_identity(session: AsyncSession, identifier: str, *, seed_value: int = 1234) -> bool:
    """Seed a populated isolated sample app for `identifier`. Idempotent: returns False (no-op) if the
    identity already has synthetic accounts. Flushes but does NOT commit - the caller commits.
    Only synthetic (non-Plaid) accounts gate the seed, mirroring `seed_dev._wipe` which leaves
    Plaid-linked accounts in place - so a re-seed after `--wipe` still populates."""
    if await session.scalar(
        select(func.count()).select_from(Account)
        .where(Account.owner_identifier == identifier, Account.plaid_item_id.is_(None))
    ):
        return False

    data = generator.generate(identifier, seed=seed_value)

    for u in data.users:  # the identity (already exists) + shared synthetic co-members (idempotent)
        await _ensure_user(session, u)
    if data.partner is not None:  # the guest's connected partner (owns the shared read-only accounts)
        await _ensure_user(session, data.partner)
    await session.flush()

    # Seed custom photos on any user the generator marked (e.g. the connected partner "Jamie"), so avatars
    # render for real instead of monogram placeholders.
    for su in [*data.users, *( [data.partner] if data.partner else [] )]:
        if su.avatar:
            user = await session.scalar(select(User).where(User.identifier == su.identifier))
            if user is not None:
                await _apply_avatar(user, "users", su.avatar)

    # Personal finances belong to the guest AND the guest's partner (co-members stay directory-only).
    owned = {identifier} | ({data.partner.identifier} if data.partner else set())
    account_ids: dict[str, UUID] = {}
    for a in (x for x in data.accounts if x.owner in owned):
        account = Account(
            name=a.name, type=a.type, balance=a.balance, currency="USD", owner_identifier=a.owner,
            mask=a.mask, available_balance=a.available_balance, institution_name=a.institution_name,
            institution_domain=a.institution_domain, institution_color=a.institution_color,
            share_level=ShareLevel(a.share_level))
        session.add(account)
        await session.flush()
        account_ids[a.key] = account.id

    expense_by_key: dict[str, Expense] = {}
    for g in data.groups:  # groups are built around `identifier` as a member
        group = Group(name=g.name, backend_type=BackendType.self_hosted, group_type=g.group_type)
        session.add(group)
        await session.flush()
        if g.avatar:
            await _apply_avatar(group, "groups", g.avatar)
        for ident in g.members:
            session.add(GroupMember(group_id=group.id, user_identifier=ident))
        for e in g.expenses:
            expense = Expense(
                group_id=group.id, description=e.description, amount=e.amount, currency=e.currency,
                date=e.date, category=e.category, created_by=e.created_by,
                splits=[Split(user_identifier=s.user_identifier, paid_share=s.paid_share,
                              owed_share=s.owed_share) for s in e.splits],
                items=[ExpenseItem(name=i.name, quantity=i.quantity, price=i.price, category=i.category)
                       for i in e.items],
            )
            session.add(expense)
            if e.key:
                expense_by_key[e.key] = expense

    txn_by_key: dict[str, Transaction] = {}
    for t in (x for x in data.transactions if x.owner in owned):
        txn = Transaction(
            account_id=account_ids.get(t.account_key) if t.account_key else None,
            source=TransactionSource.manual, description=t.description, amount=t.amount,
            currency=t.currency, date=t.date, category=t.category, pending=t.pending,
            owner_identifier=t.owner)
        session.add(txn)
        if t.key:
            txn_by_key[t.key] = txn
    for go in (x for x in data.goals if x.owner == identifier):
        session.add(Goal(
            kind=go.kind, name=go.name, category=go.category,
            account_id=account_ids.get(go.account_key) if go.account_key else None,
            target_amount=go.target_amount, save_target_type=go.save_target_type,
            starting_balance=go.starting_balance, owner_identifier=identifier))
    await session.flush()  # expenses + transactions now have ids for the link/override wiring below

    # Link expenses to their paying transaction (drives the linked-counterpart UI + spend dedup).
    for expense_key, txn_key in data.links:
        expense, txn = expense_by_key.get(expense_key), txn_by_key.get(txn_key)
        if expense is not None and txn is not None:
            expense.transaction_id = txn.id

    # Seed the guest's merchant rule (Target -> Household) as a preference blob the app restores on launch,
    # so a "Your rule" categorize card shows in the Inbox demo.
    session.add(UserPreference(owner_identifier=identifier, key="merchantPrefs.v1", value=_MERCHANT_PREFS_BLOB))

    # The guest's category taxonomy + a couple raw→canonical maps (so categories/spend render).
    for pos, name in enumerate(data.category_names):
        session.add(SpendCategory(owner_identifier=identifier, name=name, builtin=True, position=pos))
    for m in data.category_maps:
        session.add(CategoryMap(owner_identifier=identifier, raw_category=m.raw_category,
                                canonical_category=m.canonical_category, source=m.source))
    # Per-transaction recategorizations (explicit override + AI refinement).
    for o in data.overrides:
        txn = txn_by_key.get(o.transaction_key)
        if txn is not None:
            session.add(TransactionOverride(
                owner_identifier=identifier, transaction_id=txn.id,
                category=o.category, refined_category=o.refined_category, note=o.note))
    # Accepted partner connection (unlocks the shared read-only accounts via scope.audience()).
    for requester, addressee in data.connections:
        session.add(Connection(requester_identifier=requester, addressee_identifier=addressee,
                               status=ConnectionStatus.accepted))

    await session.flush()
    return True
