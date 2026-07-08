"""Create-endpoint idempotency via the Idempotency-Key header (audit High #9). A retried create with the same
key returns the ORIGINAL entity - no second row, and for a Splitwise-linked expense no second push_create. A
genuinely concurrent same-key double-submit resolves to one row. Absent header = today's behavior (no dedup).
The Splitwise SDK is monkeypatched - no network."""
import asyncio
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.splitwise import client as sw_client
from app.models import (
    Account, BackendType, Expense, Group, GroupMember, SplitwiseToken, Transaction, User,
)
from app.models.enums import TransactionSource, UserSource
from app.routers.accounts import create_transaction
from app.routers.expenses import create_expense
from app.schemas.expense import ExpenseCreate
from app.schemas.transaction import TransactionCreate

CALLER = "idem-alice"
PARTNER = "idem-bob"
SWGID = "99000777"


async def _purge():
    async with async_session() as s:
        gids = list(await s.scalars(select(Group.id).where(Group.name.in_(["idem-local", "idem-sw"]))))
        if gids:
            await s.execute(delete(Group).where(Group.id.in_(gids)))  # cascades expenses/splits
        aids = list(await s.scalars(select(Account.id).where(Account.owner_identifier == CALLER)))
        if aids:
            await s.execute(delete(Transaction).where(Transaction.account_id.in_(aids)))
            await s.execute(delete(Account).where(Account.id.in_(aids)))
        await s.execute(delete(GroupMember).where(GroupMember.user_identifier.in_([CALLER, PARTNER])))
        await s.execute(delete(User).where(User.identifier.in_([CALLER, PARTNER])))
        await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == CALLER))
        await s.commit()


async def _seed_local_group() -> "UUID":
    async with async_session() as s:
        g = Group(name="idem-local", backend_type=BackendType.self_hosted)
        s.add(g); await s.flush()
        s.add(GroupMember(group_id=g.id, user_identifier=CALLER))
        await s.commit()
        return g.id


async def _seed_sw_group() -> "UUID":
    async with async_session() as s:
        s.add(User(identifier=CALLER, display_name="M", source=UserSource.app, splitwise_user_id="11"))
        g = Group(name="idem-sw", backend_type=BackendType.splitwise, splitwise_group_id=SWGID)
        s.add(g); await s.flush()
        s.add(GroupMember(group_id=g.id, user_identifier=CALLER))
        s.add(SplitwiseToken(user_identifier=CALLER, access_token="x"))
        await s.commit()
        return g.id


async def _seed_account() -> "UUID":
    async with async_session() as s:
        a = Account(name="idem-acct", owner_identifier=CALLER, currency="USD", balance=Decimal(0))
        s.add(a); await s.commit()
        return a.id


def _expense_body(gid, **kw):
    return ExpenseCreate(group_id=gid, description="Coffee", amount=Decimal("5.00"),
                         date=date(2026, 6, 1), created_by=CALLER, splits=[], **kw)


async def test_expense_same_key_returns_original_no_duplicate():
    await _purge()
    try:
        gid = await _seed_local_group()
        async with async_session() as s:
            first = await create_expense(_expense_body(gid), caller=CALLER, idempotency_key="k-exp-1", session=s)
        async with async_session() as s:
            second = await create_expense(_expense_body(gid), caller=CALLER, idempotency_key="k-exp-1", session=s)
        assert second.id == first.id                              # same entity, replayed
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(Expense).where(Expense.group_id == gid))
            assert n == 1                                          # no second row
    finally:
        await _purge()


async def test_expense_splitwise_same_key_no_second_push():
    await _purge()
    calls = {"n": 0}

    def fake_create(client, payload):
        calls["n"] += 1
        return f"sw-{calls['n']}"

    orig = (sw_client.make_client, sw_client.category_name_to_id, sw_client.create_expense)
    sw_client.make_client = lambda token: object()
    sw_client.category_name_to_id = lambda client: {}
    sw_client.create_expense = fake_create
    try:
        gid = await _seed_sw_group()
        async with async_session() as s:
            first = await create_expense(_expense_body(gid), caller=CALLER, idempotency_key="k-sw-1", session=s)
        async with async_session() as s:
            second = await create_expense(_expense_body(gid), caller=CALLER, idempotency_key="k-sw-1", session=s)
        assert second.id == first.id
        assert calls["n"] == 1                                    # short-circuited BEFORE a second push_create
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(Expense).where(Expense.group_id == gid))
            assert n == 1
    finally:
        sw_client.make_client, sw_client.category_name_to_id, sw_client.create_expense = orig
        await _purge()


async def test_expense_absent_header_still_duplicates():
    await _purge()
    try:
        gid = await _seed_local_group()
        async with async_session() as s:
            await create_expense(_expense_body(gid), caller=CALLER, idempotency_key=None, session=s)
        async with async_session() as s:
            await create_expense(_expense_body(gid), caller=CALLER, idempotency_key=None, session=s)
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(Expense).where(Expense.group_id == gid))
            assert n == 2                                          # no header -> unchanged behavior (two rows)
    finally:
        await _purge()


async def test_expense_concurrent_same_key_resolves_to_one_row():
    await _purge()
    try:
        gid = await _seed_local_group()

        async def _one():
            async with async_session() as s:
                return await create_expense(_expense_body(gid), caller=CALLER, idempotency_key="k-race",
                                            session=s)
        r1, r2 = await asyncio.gather(_one(), _one())
        assert r1.id == r2.id                                     # both resolve to the same row
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(Expense).where(Expense.group_id == gid))
            assert n == 1                                          # exactly one, no 500
    finally:
        await _purge()


async def test_transaction_same_key_returns_original_no_duplicate():
    await _purge()
    try:
        aid = await _seed_account()

        def _body():
            return TransactionCreate(account_id=aid, description="Latte", amount=Decimal("4.00"),
                                     date=date(2026, 6, 1))
        async with async_session() as s:
            first = await create_transaction(_body(), caller=CALLER, idempotency_key="k-txn-1", session=s)
        async with async_session() as s:
            second = await create_transaction(_body(), caller=CALLER, idempotency_key="k-txn-1", session=s)
        assert second.id == first.id
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(Transaction)
                               .where(Transaction.account_id == aid))
            assert n == 1
    finally:
        await _purge()


async def test_transaction_concurrent_same_key_resolves_to_one_row():
    await _purge()
    try:
        aid = await _seed_account()

        async def _one():
            async with async_session() as s:
                return await create_transaction(
                    TransactionCreate(account_id=aid, description="Latte", amount=Decimal("4.00"),
                                      date=date(2026, 6, 1)),
                    caller=CALLER, idempotency_key="k-txn-race", session=s)
        r1, r2 = await asyncio.gather(_one(), _one())
        assert r1.id == r2.id
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(Transaction)
                               .where(Transaction.account_id == aid))
            assert n == 1
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
