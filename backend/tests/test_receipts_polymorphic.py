"""Polymorphic receipts: a Receipt is owned by exactly one of an expense or a transaction (the xor check
constraint), and transaction receipts are owner-scoped. DB-backed - no MinIO (the byte round-trip is covered
by test_receipts_flow on the full stack)."""
import uuid
from datetime import date
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete
from sqlalchemy.exc import IntegrityError

from app.db import async_session
from app.models import Account, Connection, Receipt, Transaction
from app.models.enums import ConnectionStatus, ShareLevel, TransactionSource
from app.routers.receipts import list_transaction_receipts

OWNER = "rcpt-alice"
VIEWER = "rcpt-carol"  # connected partner, in the owner's audience


async def _make_txn(session) -> uuid.UUID:
    t = Transaction(source=TransactionSource.manual, description="Store", amount=Decimal("9.99"),
                    currency="USD", date=date(2026, 6, 1), owner_identifier=OWNER)
    session.add(t)
    await session.commit()
    return t.id


def _receipt(**kw) -> Receipt:
    return Receipt(bucket="receipts", object_key=str(uuid.uuid4()), content_type="image/png", **kw)


async def _cleanup(txn_id):
    async with async_session() as s:
        await s.execute(delete(Receipt).where(Receipt.transaction_id == txn_id))
        await s.execute(delete(Transaction).where(Transaction.id == txn_id))
        await s.commit()


async def test_transaction_receipt_allowed_and_owner_scoped():
    async with async_session() as s:
        txn_id = await _make_txn(s)
    try:
        # A transaction-owned receipt is allowed (expense_id null).
        async with async_session() as s:
            s.add(_receipt(transaction_id=txn_id))
            await s.commit()
        # The owner lists it; a different caller is rejected.
        async with async_session() as s:
            listed = await list_transaction_receipts(txn_id, caller=OWNER, session=s)
            assert len(listed) == 1 and listed[0].transaction_id == txn_id
        async with async_session() as s:
            try:
                await list_transaction_receipts(txn_id, caller="rcpt-bob", session=s)
                assert False, "expected 403 for a non-owner"
            except HTTPException as e:
                assert e.status_code == 403
    finally:
        await _cleanup(txn_id)


async def test_transaction_receipt_shared_full_readable():
    """A `full`-shared account's transaction receipts are readable by a connected partner (in the owner's
    audience), but not by an unconnected caller - mirrors the transaction-list sharing rule."""
    acct_id = uuid.uuid4()
    async with async_session() as s:
        s.add(Account(id=acct_id, name="Shared Checking", owner_identifier=OWNER,
                      share_level=ShareLevel.full))
        s.add(Connection(requester_identifier=OWNER, addressee_identifier=VIEWER,
                         status=ConnectionStatus.accepted))
        t = Transaction(source=TransactionSource.plaid, description="Store", amount=Decimal("9.99"),
                        currency="USD", date=date(2026, 6, 1), owner_identifier=OWNER, account_id=acct_id)
        s.add(t)
        await s.commit()
        txn_id = t.id
    try:
        async with async_session() as s:
            s.add(_receipt(transaction_id=txn_id))
            await s.commit()
        # The connected partner can list the shared account's transaction receipts.
        async with async_session() as s:
            listed = await list_transaction_receipts(txn_id, caller=VIEWER, session=s)
            assert len(listed) == 1 and listed[0].transaction_id == txn_id
        # An unconnected caller cannot.
        async with async_session() as s:
            try:
                await list_transaction_receipts(txn_id, caller="rcpt-bob", session=s)
                assert False, "expected 403 for an unconnected caller"
            except HTTPException as e:
                assert e.status_code == 403
    finally:
        async with async_session() as s:
            await s.execute(delete(Receipt).where(Receipt.transaction_id == txn_id))
            await s.execute(delete(Transaction).where(Transaction.id == txn_id))
            await s.execute(delete(Account).where(Account.id == acct_id))
            await s.execute(delete(Connection).where(Connection.requester_identifier == OWNER))
            await s.commit()


async def test_receipt_requires_exactly_one_owner():
    # Neither expense nor transaction set → the xor check constraint rejects the row.
    async with async_session() as s:
        s.add(_receipt())
        try:
            await s.commit()
            assert False, "expected IntegrityError (orphan receipt)"
        except IntegrityError:
            await s.rollback()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
