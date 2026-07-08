"""Demo guest login (POST /auth/demo) + seed_identity. Drives the handler directly; toggles demo_mode in
process. Runs against the running Postgres; cleans up its own rows.
"""
from fastapi import HTTPException
from sqlalchemy import delete, func, or_, select

from app.categories import CATEGORIES
from app.config import settings
from app.db import async_session
from app.integrations.dev_seed.seeder import seed_identity
from app.models import (
    Account,
    CategoryMap,
    Connection,
    Expense,
    Goal,
    Group,
    GroupMember,
    SpendCategory,
    Transaction,
    TransactionOverride,
    User,
)
from app.models.enums import ShareLevel, UserSource
from app.routers.accounts import list_accounts
from app.routers.auth import auth_demo
from app.schemas.auth import DemoAuthRequest

FAKES = ["robin", "sam", "alex"]


async def _purge(session, identifier: str) -> None:
    partner = f"{identifier}-partner"
    idents = [identifier, partner]
    gids = list(await session.scalars(
        select(GroupMember.group_id).where(GroupMember.user_identifier == identifier)))
    if gids:
        await session.execute(delete(Group).where(Group.id.in_(gids)))  # cascades expenses/splits
    for model in (Account, Transaction, Goal, SpendCategory, CategoryMap):  # txn_overrides cascade via txns
        await session.execute(delete(model).where(model.owner_identifier.in_(idents)))
    await session.execute(delete(GroupMember).where(GroupMember.user_identifier.in_(idents)))
    await session.execute(delete(Connection).where(or_(
        Connection.requester_identifier.in_(idents), Connection.addressee_identifier.in_(idents))))
    await session.execute(delete(User).where(User.identifier.in_([*idents, *FAKES])))
    await session.commit()


async def test_seed_identity_idempotent():
    ident = "seedid-zzz"
    async with async_session() as session:
        await _purge(session, ident)
        try:
            session.add(User(identifier=ident, display_name="Z", source=UserSource.app))
            await session.flush()
            assert await seed_identity(session, ident) is True
            await session.commit()
            assert await session.scalar(
                select(func.count()).select_from(Account).where(Account.owner_identifier == ident)) == 3
            assert await session.scalar(
                select(func.count()).select_from(GroupMember)
                .where(GroupMember.user_identifier == ident)) == 2
            async with async_session() as s2:
                assert await seed_identity(s2, ident) is False  # idempotent
        finally:
            await _purge(session, ident)


async def test_seed_enrichment_links_recat_and_partner():
    ident = "seedrich-zzz"
    partner = f"{ident}-partner"
    async with async_session() as session:
        await _purge(session, ident)
        try:
            session.add(User(identifier=ident, display_name="Rich", source=UserSource.app))
            await session.flush()
            assert await seed_identity(session, ident) is True
            await session.commit()

            # Accounts render with institution branding.
            accts = (await session.scalars(
                select(Account).where(Account.owner_identifier == ident))).all()
            assert len(accts) == 3 and all(a.institution_name for a in accts)

            # At least one expense is linked to a paying transaction (drives the linked-counterpart UI).
            gids = list(await session.scalars(
                select(GroupMember.group_id).where(GroupMember.user_identifier == ident)))
            linked = await session.scalar(
                select(func.count()).select_from(Expense)
                .where(Expense.group_id.in_(gids), Expense.transaction_id.is_not(None)))
            assert linked >= 1

            # Recategorizations: an explicit override + an AI refinement.
            assert await session.scalar(select(func.count()).select_from(TransactionOverride)
                .where(TransactionOverride.owner_identifier == ident,
                       TransactionOverride.category.is_not(None))) >= 1
            assert await session.scalar(select(func.count()).select_from(TransactionOverride)
                .where(TransactionOverride.owner_identifier == ident,
                       TransactionOverride.refined_category.is_not(None))) >= 1

            # Category taxonomy seeded (so the picker + server-side spend resolve).
            assert await session.scalar(select(func.count()).select_from(SpendCategory)
                .where(SpendCategory.owner_identifier == ident)) == len(CATEGORIES)

            # Partner shares two read-only accounts (full + balances) via an accepted connection.
            shared = (await session.scalars(select(Account).where(
                Account.owner_identifier == partner, Account.share_level != ShareLevel.private))).all()
            assert {a.share_level for a in shared} == {ShareLevel.full, ShareLevel.balances}
            assert await session.scalar(select(func.count()).select_from(Connection).where(
                or_(Connection.requester_identifier == ident,
                    Connection.addressee_identifier == ident))) == 1

            # Read path: the guest sees the partner's shared accounts (tagged shared_by); an outsider doesn't.
            mine = await list_accounts(caller=ident, session=session)
            shared_in = [a for a in mine if a.owner_identifier == partner]
            assert len(shared_in) == 2 and all(a.shared_by for a in shared_in)
            outsider = await list_accounts(caller="outsider-zzz", session=session)
            assert not any(a.owner_identifier == partner for a in outsider)
        finally:
            await _purge(session, ident)


async def test_auth_demo_gated_and_seeds():
    saved = settings.demo_mode
    created: list[str] = []
    try:
        # Off everywhere but the demo backend.
        settings.demo_mode = False
        async with async_session() as session:
            try:
                await auth_demo(DemoAuthRequest(display_name="Casey"), session=session)
                assert False, "expected 404 when demo_mode off"
            except HTTPException as e:
                assert e.status_code == 404

        # On: guest gets a token + a populated isolated app.
        settings.demo_mode = True
        async with async_session() as session:
            resp = await auth_demo(DemoAuthRequest(display_name="Casey"), session=session)
            assert resp.token and resp.user.display_name == "Casey"
            assert resp.user.identifier.startswith("demo-")
            created.append(resp.user.identifier)
            assert await session.scalar(
                select(func.count()).select_from(Account)
                .where(Account.owner_identifier == resp.user.identifier)) == 3
    finally:
        settings.demo_mode = saved
        async with async_session() as session:
            for ident in created:
                await _purge(session, ident)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
