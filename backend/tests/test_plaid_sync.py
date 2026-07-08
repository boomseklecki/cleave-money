"""Plaid sync: cursor pagination (fake fetcher), DB idempotency, and HTTP reads."""
import json
import urllib.request
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.plaid import sync as plaid_sync
from app.models import (
    Account, BackendType, Expense, Group, PlaidItem, Transaction, TransactionItem, TransactionOverride,
)

API = "http://localhost:8000"
ITEM = "test-item-zzz"
ACC = "test-acc-zzz"
TX = "test-tx-zzz"
PEND = "test-tx-pending-zzz"   # the pending charge
POST = "test-tx-posted-zzz"    # its posted replacement
OWNER = "carry-owner-zzz"


def _fake_fetcher(pages):
    state = {"i": 0}

    def fetch(access_token, cursor):
        page = pages[state["i"]]
        state["i"] += 1
        return page

    return fetch


def _accounts():
    return [{"plaid_account_id": ACC, "name": "Checking", "type": "checking", "balance": "100.00", "currency": "USD"}]


def _added():
    return [
        {
            "plaid_transaction_id": TX,
            "plaid_account_id": ACC,
            "description": "Coffee",
            "amount": "4.50",
            "currency": "USD",
            "date": "2023-03-01",
            "category": "Food",
            "pending": False,
        }
    ]


def _txn(plaid_id, *, pending=False, pending_of=None):
    return {
        "plaid_transaction_id": plaid_id, "plaid_account_id": ACC, "description": "Coffee",
        "amount": "4.50", "currency": "USD", "date": "2023-03-01", "category": "Food",
        "pending": pending, "pending_transaction_id": pending_of,
    }


async def _cleanup():
    async with async_session() as session:
        await session.execute(delete(Expense).where(Expense.description == "carry-zzz"))
        await session.execute(delete(Group).where(Group.name == "carry-grp-zzz"))
        await session.execute(delete(TransactionOverride).where(TransactionOverride.owner_identifier == OWNER))
        await session.execute(
            delete(Transaction).where(Transaction.plaid_transaction_id.in_([TX, PEND, POST])))
        await session.execute(delete(Account).where(Account.plaid_account_id == ACC))
        await session.execute(delete(PlaidItem).where(PlaidItem.plaid_item_id == ITEM))
        await session.commit()


def test_accumulate_sync_paginates():
    pages = [
        {"added": [{"plaid_transaction_id": "t1"}], "modified": [], "removed": [], "next_cursor": "c1", "has_more": True},
        {"added": [{"plaid_transaction_id": "t2"}], "modified": [{"plaid_transaction_id": "t3"}], "removed": ["r1"], "next_cursor": "c2", "has_more": False},
    ]
    result = plaid_sync.accumulate_sync(_fake_fetcher(pages), "token", None)
    assert [t["plaid_transaction_id"] for t in result["added"]] == ["t1", "t2"]
    assert [t["plaid_transaction_id"] for t in result["modified"]] == ["t3"]
    assert result["removed"] == ["r1"]
    assert result["cursor"] == "c2"


async def test_apply_sync_idempotent_and_removal():
    await _cleanup()
    try:
        async with async_session() as session:
            item = PlaidItem(plaid_item_id=ITEM, access_token="x")
            session.add(item)
            await session.commit()

            stats = await plaid_sync.apply_sync(
                session, item, _accounts(), {"added": _added(), "modified": [], "removed": [], "cursor": "c1"}
            )
            assert stats == {"accounts": 1, "added": 1, "modified": 0, "removed": 0}

            # re-apply same batch -> no duplicates, cursor advances
            await plaid_sync.apply_sync(
                session, item, _accounts(), {"added": _added(), "modified": [], "removed": [], "cursor": "c2"}
            )
            tx_count = await session.scalar(
                select(func.count()).select_from(Transaction).where(Transaction.plaid_transaction_id == TX)
            )
            acc_count = await session.scalar(
                select(func.count()).select_from(Account).where(Account.plaid_account_id == ACC)
            )
            assert tx_count == 1 and acc_count == 1
            assert item.transactions_cursor == "c2"
            balance = await session.scalar(select(Account.balance).where(Account.plaid_account_id == ACC))
            assert balance == Decimal("100.00")

            # removed id deletes the row
            await plaid_sync.apply_sync(
                session, item, _accounts(), {"added": [], "modified": [], "removed": [TX], "cursor": "c3"}
            )
            gone = await session.scalar(
                select(func.count()).select_from(Transaction).where(Transaction.plaid_transaction_id == TX)
            )
            assert gone == 0
    finally:
        await _cleanup()


async def test_apply_sync_carries_pending_data():
    """When a pending charge posts, its user data (per-user override, receipt item, expense link) follows the
    new posted row instead of being lost to the pending row's deletion."""
    await _cleanup()
    try:
        async with async_session() as session:
            item = PlaidItem(plaid_item_id=ITEM, access_token="x", user_identifier=OWNER)
            session.add(item)
            await session.commit()

            # 1) Pending charge arrives; user categorizes it, itemizes it, and links it to an expense.
            await plaid_sync.apply_sync(
                session, item, _accounts(),
                {"added": [_txn(PEND, pending=True)], "modified": [], "removed": [], "cursor": "c1"})
            pend_id = await session.scalar(select(Transaction.id).where(Transaction.plaid_transaction_id == PEND))
            group = Group(name="carry-grp-zzz", backend_type=BackendType.self_hosted)
            session.add(group)
            await session.flush()
            session.add_all([
                TransactionOverride(owner_identifier=OWNER, transaction_id=pend_id, category="Dining"),
                TransactionItem(transaction_id=pend_id, name="Latte", price=Decimal("4.50")),
                Expense(group_id=group.id, transaction_id=pend_id, description="carry-zzz",
                        amount=Decimal("4.50"), date=date(2023, 3, 1)),
            ])
            await session.commit()

            # 2) It posts as a new row (new plaid id) and the pending id is removed in the same sync.
            await plaid_sync.apply_sync(
                session, item, _accounts(),
                {"added": [_txn(POST, pending_of=PEND)], "modified": [], "removed": [PEND], "cursor": "c2"})

            post_id = await session.scalar(select(Transaction.id).where(Transaction.plaid_transaction_id == POST))
            assert post_id is not None
            assert await session.scalar(
                select(func.count()).select_from(Transaction).where(Transaction.plaid_transaction_id == PEND)) == 0
            # The pending charge's plaid id is persisted on the posted row (powers the "view posted twin" lookup)
            # and survives a re-sync of the same posted row.
            assert await session.scalar(
                select(Transaction.pending_transaction_id).where(Transaction.id == post_id)) == PEND
            await plaid_sync.apply_sync(
                session, item, _accounts(),
                {"added": [_txn(POST, pending_of=PEND)], "modified": [], "removed": [], "cursor": "c3"})
            assert await session.scalar(
                select(Transaction.pending_transaction_id).where(Transaction.id == post_id)) == PEND
            # Override carried forward onto the posted row.
            ov = (await session.scalars(
                select(TransactionOverride).where(TransactionOverride.owner_identifier == OWNER))).all()
            assert len(ov) == 1 and ov[0].transaction_id == post_id and ov[0].category == "Dining"
            # Item + expense link carried forward too.
            assert await session.scalar(
                select(TransactionItem.transaction_id).where(TransactionItem.name == "Latte")) == post_id
            assert await session.scalar(
                select(Expense.transaction_id).where(Expense.description == "carry-zzz")) == post_id
    finally:
        await _cleanup()


async def test_apply_sync_keeps_existing_posted_override():
    """If the user already overrode the posted row, the pending row's override must NOT clobber it."""
    await _cleanup()
    try:
        async with async_session() as session:
            item = PlaidItem(plaid_item_id=ITEM, access_token="x", user_identifier=OWNER)
            session.add(item)
            await session.commit()

            # Both rows already exist; the pending one says "Dining", the posted one already says "Travel".
            await plaid_sync.apply_sync(
                session, item, _accounts(),
                {"added": [_txn(PEND, pending=True), _txn(POST)], "modified": [], "removed": [], "cursor": "c1"})
            pend_id = await session.scalar(select(Transaction.id).where(Transaction.plaid_transaction_id == PEND))
            post_id = await session.scalar(select(Transaction.id).where(Transaction.plaid_transaction_id == POST))
            session.add_all([
                TransactionOverride(owner_identifier=OWNER, transaction_id=pend_id, category="Dining"),
                TransactionOverride(owner_identifier=OWNER, transaction_id=post_id, category="Travel"),
            ])
            await session.commit()

            await plaid_sync.apply_sync(
                session, item, _accounts(),
                {"added": [_txn(POST, pending_of=PEND)], "modified": [], "removed": [PEND], "cursor": "c2"})

            ov = (await session.scalars(
                select(TransactionOverride).where(TransactionOverride.owner_identifier == OWNER))).all()
            assert len(ov) == 1  # the pending one's override cascaded away, not migrated
            assert ov[0].transaction_id == post_id and ov[0].category == "Travel"  # posted override preserved
    finally:
        await _cleanup()


async def test_accounts_and_transactions_http():
    await _cleanup()
    try:
        async with async_session() as session:
            item = PlaidItem(plaid_item_id=ITEM, access_token="x")
            session.add(item)
            await session.commit()
            await plaid_sync.apply_sync(
                session, item, _accounts(), {"added": _added(), "modified": [], "removed": [], "cursor": "c1"}
            )
            account_id = str(await session.scalar(select(Account.id).where(Account.plaid_account_id == ACC)))
            tx_id = str(await session.scalar(select(Transaction.id).where(Transaction.plaid_transaction_id == TX)))

        accounts = json.loads(urllib.request.urlopen(f"{API}/accounts").read())
        assert any(a["plaid_account_id"] == ACC for a in accounts)

        txs = json.loads(urllib.request.urlopen(f"{API}/transactions?account_id={account_id}").read())
        assert any(t["id"] == tx_id for t in txs)

        one = json.loads(urllib.request.urlopen(f"{API}/transactions/{tx_id}").read())
        assert one["plaid_transaction_id"] == TX and one["source"] == "plaid"
    finally:
        await _cleanup()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
