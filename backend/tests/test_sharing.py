"""Zeta-style sharing: partner connections + per-account share level + shared goals (view-only). DB-backed,
calling the router functions directly."""
from datetime import date
from decimal import Decimal
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import delete, select

from app.auth.scope import audience
from app.db import async_session
from app.models import Account, Connection, Goal, Transaction, User
from app.models.enums import ShareLevel
from app.routers.accounts import list_accounts, list_transactions, update_account
from app.routers.connections import accept_connection, create_connection
from app.routers.goals import list_goals, update_goal
from app.schemas.account import AccountUpdate
from app.schemas.connection import ConnectionCreate
from app.schemas.goal import GoalUpdate

ALICE, BOB = "shr-alice", "shr-bob"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(Connection).where(
            Connection.requester_identifier.in_([ALICE, BOB])))
        aids = (await s.scalars(select(Account.id).where(Account.owner_identifier == ALICE))).all()
        if aids:
            await s.execute(delete(Transaction).where(Transaction.account_id.in_(aids)))
        await s.execute(delete(Transaction).where(Transaction.owner_identifier == ALICE))
        await s.execute(delete(Goal).where(Goal.owner_identifier == ALICE))
        await s.execute(delete(Account).where(Account.owner_identifier == ALICE))
        await s.execute(delete(User).where(User.identifier.in_([ALICE, BOB])))
        await s.commit()


async def _seed_users():
    async with async_session() as s:
        s.add(User(identifier=ALICE, display_name="Alice", source="app", email="alice@x.com"))
        s.add(User(identifier=BOB, display_name="Bob", source="app", email="bob@x.com"))
        await s.commit()


async def _seed_account(level: ShareLevel, *, with_txn=False) -> str:
    async with async_session() as s:
        a = Account(name=f"Acct {level.value}", balance=Decimal("100"), currency="USD",
                    owner_identifier=ALICE, share_level=level)
        s.add(a)
        await s.flush()
        if with_txn:
            s.add(Transaction(account_id=a.id, source="manual", description="Coffee",
                              amount=Decimal("4"), currency="USD", date=date(2026, 6, 1),
                              owner_identifier=ALICE))
        await s.commit()
        return str(a.id)


async def _connect_and_accept():
    """Alice invites Bob; Bob accepts."""
    async with async_session() as s:
        conn = await create_connection(ConnectionCreate(identifier=BOB), caller=ALICE, session=s)
    async with async_session() as s:
        await accept_connection(conn.id, caller=BOB, session=s)


async def test_audience_resolves_both_directions():
    await _purge(); await _seed_users()
    try:
        await _connect_and_accept()
        async with async_session() as s:
            assert await audience(s, ALICE) == {BOB}
            assert await audience(s, BOB) == {ALICE}
    finally:
        await _purge()


async def test_accept_only_by_addressee():
    await _purge(); await _seed_users()
    try:
        async with async_session() as s:
            conn = await create_connection(ConnectionCreate(identifier=BOB), caller=ALICE, session=s)
        async with async_session() as s:
            try:
                await accept_connection(conn.id, caller=ALICE, session=s)  # requester can't accept
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
    finally:
        await _purge()


async def test_private_account_hidden_balances_visible_full_visible():
    await _purge(); await _seed_users()
    priv = await _seed_account(ShareLevel.private)
    bal = await _seed_account(ShareLevel.balances)
    full = await _seed_account(ShareLevel.full, with_txn=True)
    try:
        await _connect_and_accept()
        async with async_session() as s:
            mine = await list_accounts(caller=BOB, session=s)  # Bob has no own accounts
        ids = {str(a.id): a for a in mine}
        assert priv not in ids                          # private hidden
        assert bal in ids and ids[bal].shared_by_identifier == ALICE
        assert full in ids and ids[full].shared_by == "Alice"
    finally:
        await _purge()


async def test_transaction_gating():
    await _purge(); await _seed_users()
    bal = await _seed_account(ShareLevel.balances, with_txn=True)
    full = await _seed_account(ShareLevel.full, with_txn=True)
    try:
        await _connect_and_accept()
        # Full-shared: Bob can read the account's transactions...
        async with async_session() as s:
            txns = await list_transactions(account_id=UUID(full), limit=500, offset=0, caller=BOB, session=s)
            assert len(txns) == 1
        # ...but balances-only is 403.
        async with async_session() as s:
            try:
                await list_transactions(account_id=UUID(bal), limit=500, offset=0, caller=BOB, session=s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
        # Bob's unscoped list never includes shared transactions.
        async with async_session() as s:
            assert await list_transactions(limit=500, offset=0, caller=BOB, session=s) == []
    finally:
        await _purge()


async def test_shared_goal_visible_unshared_hidden():
    await _purge(); await _seed_users()
    try:
        await _connect_and_accept()
        async with async_session() as s:
            shared = Goal(kind="spend", name="Dining", category="Dining",
                          target_amount=Decimal("400"), owner_identifier=ALICE, shared=True)
            private = Goal(kind="spend", name="Secret", category="Other",
                           target_amount=Decimal("50"), owner_identifier=ALICE, shared=False)
            s.add_all([shared, private]); await s.commit()
            shared_id, private_id = shared.id, private.id
        async with async_session() as s:
            goals = await list_goals(caller=BOB, session=s)
        ids = {g.id: g for g in goals}
        assert shared_id in ids and ids[shared_id].shared_by == "Alice"
        assert private_id not in ids
    finally:
        await _purge()


async def test_non_owner_cannot_edit_shared():
    await _purge(); await _seed_users()
    full = await _seed_account(ShareLevel.full)
    try:
        await _connect_and_accept()
        async with async_session() as s:
            try:
                await update_account(UUID(full),
                                     AccountUpdate(share_level="private"), caller=BOB, session=s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
        async with async_session() as s:
            g = Goal(kind="spend", name="D", category="Dining", target_amount=Decimal("1"),
                     owner_identifier=ALICE, shared=True)
            s.add(g); await s.commit(); gid = g.id
        async with async_session() as s:
            try:
                await update_goal(gid, GoalUpdate(name="hacked"), caller=BOB, session=s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
