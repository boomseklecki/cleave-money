"""Deleting a transaction / account / Plaid item removes its receipts' MinIO objects, not just the DB rows
(audit High #7). The receipt rows cascade via FK; the bucket objects don't, so the delete paths must gather
+ remove the object keys first - mirroring the expense/group delete paths. MinIO is stubbed (remove recorded,
no live call)."""
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.storage import minio_client
from app.models import Account, PlaidItem, Receipt, Transaction, TransactionSource
from app.routers.accounts import delete_account, delete_transaction
from app.routers.plaid import delete_item

OWNER = "receipt-cleanup-zzz"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(Account).where(Account.owner_identifier == OWNER))  # cascades txns + receipts
        await s.execute(delete(PlaidItem).where(PlaidItem.user_identifier == OWNER))
        await s.commit()


class _RemoveRecorder:
    def __init__(self):
        self.keys: list[str] = []

    def __call__(self, object_key):  # sync - invoked via asyncio.to_thread, like the real minio_client.remove
        self.keys.append(object_key)


async def _seed_txn_with_receipt(object_key: str, *, plaid: bool = False):
    """An owner's manual/bank account + one transaction carrying a receipt with the given object key."""
    async with async_session() as s:
        item = None
        if plaid:
            item = PlaidItem(plaid_item_id=f"item-{object_key}", access_token="x", user_identifier=OWNER)
            s.add(item); await s.flush()
        acct = Account(name="Acct zzz", owner_identifier=OWNER,
                       plaid_item_id=item.id if item else None,
                       plaid_account_id=f"pa-{object_key}" if plaid else None)
        s.add(acct); await s.flush()
        t = Transaction(account_id=acct.id, source=TransactionSource.manual, description="x",
                        amount=Decimal("1.00"), currency="USD", date=date(2026, 3, 1), owner_identifier=OWNER)
        s.add(t); await s.flush()
        s.add(Receipt(transaction_id=t.id, bucket="receipts", object_key=object_key))
        await s.commit()
        return (item.id if item else None), acct.id, t.id


async def test_delete_transaction_removes_receipt_object():
    await _purge()
    rec = _RemoveRecorder()
    orig = minio_client.remove
    minio_client.remove = rec
    try:
        _, _, tid = await _seed_txn_with_receipt("obj-txn-zzz")
        async with async_session() as s:
            await delete_transaction(tid, caller=OWNER, session=s)
        assert rec.keys == ["obj-txn-zzz"]                     # object removed, not just the row
        async with async_session() as s:
            assert await s.get(Transaction, tid) is None
            assert (await s.scalar(select(Receipt).where(Receipt.transaction_id == tid))) is None
    finally:
        minio_client.remove = orig
        await _purge()


async def test_delete_account_removes_its_transactions_receipt_objects():
    await _purge()
    rec = _RemoveRecorder()
    orig = minio_client.remove
    minio_client.remove = rec
    try:
        _, aid, _ = await _seed_txn_with_receipt("obj-acct-zzz")
        async with async_session() as s:
            await delete_account(aid, caller=OWNER, session=s)
        assert rec.keys == ["obj-acct-zzz"]                    # receipt via the account's transaction
        async with async_session() as s:
            assert await s.get(Account, aid) is None
    finally:
        minio_client.remove = orig
        await _purge()


async def test_delete_plaid_item_removes_its_accounts_receipt_objects():
    await _purge()
    rec = _RemoveRecorder()
    orig = minio_client.remove
    minio_client.remove = rec
    try:
        iid, _, _ = await _seed_txn_with_receipt("obj-item-zzz", plaid=True)
        async with async_session() as s:
            await delete_item(iid, caller=OWNER, session=s)
        assert rec.keys == ["obj-item-zzz"]                    # receipt via the item's account's transaction
        async with async_session() as s:
            assert await s.get(PlaidItem, iid) is None
    finally:
        minio_client.remove = orig
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
