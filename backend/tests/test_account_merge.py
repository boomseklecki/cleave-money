"""Cross-source merge: primary-source sync suppression (Plaid must not feed a merged account it isn't primary
for) + the /simplefin/merge feed-forward behavior (preserve history, primary feeds past the boundary)."""
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.plaid import sync as plaid_sync
from app.models import Account, PlaidItem, SimpleFinConnection, Transaction, TransactionSource

OWNER = "merge-owner-zzz"
PACC = "merge-plaid-acc-zzz"
PITEM = "merge-plaid-item-zzz"


async def _cleanup():
    async with async_session() as s:
        acc_ids = (await s.scalars(select(Account.id).where(Account.owner_identifier == OWNER))).all()
        if acc_ids:
            await s.execute(delete(Transaction).where(Transaction.account_id.in_(acc_ids)))
            await s.execute(delete(Account).where(Account.id.in_(acc_ids)))
        await s.execute(delete(SimpleFinConnection).where(SimpleFinConnection.user_identifier == OWNER))
        await s.execute(delete(PlaidItem).where(PlaidItem.plaid_item_id == PITEM))
        await s.commit()


def _paccounts(balance):
    return [{"plaid_account_id": PACC, "name": "Chase", "type": "checking", "balance": balance,
             "currency": "USD"}]


def _ptxn(pid, d):
    return {"plaid_transaction_id": pid, "plaid_account_id": PACC, "description": "X", "amount": "5.00",
            "currency": "USD", "date": d, "category": None, "pending": False}


async def test_plaid_suppressed_when_primary_is_simplefin():
    await _cleanup()
    try:
        async with async_session() as s:
            item = PlaidItem(plaid_item_id=PITEM, access_token="x", user_identifier=OWNER)
            s.add(item)
            await s.flush()
            # A merged account linked to Plaid but with SimpleFIN as primary -> Plaid must not touch it.
            s.add(Account(name="Chase", owner_identifier=OWNER, plaid_account_id=PACC, plaid_item_id=item.id,
                          balance=Decimal("50.00"), currency="USD",
                          primary_source=TransactionSource.simplefin))
            await s.commit()

            await plaid_sync.apply_sync(s, item, _paccounts("999.00"),
                {"added": [_ptxn("pt-zzz", "2026-06-10")], "modified": [], "removed": [], "cursor": "c1"})

            bal = await s.scalar(select(Account.balance).where(Account.plaid_account_id == PACC))
            assert bal == Decimal("50.00")  # NOT overwritten to 999 (balance left to the primary source)
            added = await s.scalar(select(func.count()).select_from(Transaction).where(
                Transaction.plaid_transaction_id == "pt-zzz"))
            assert added == 0               # Plaid transaction NOT inserted (suppressed)
    finally:
        await _cleanup()


async def _seed_merge_pair(s):
    conn = SimpleFinConnection(access_url="x", user_identifier=OWNER)
    s.add(conn)
    target = Account(name="Chase", owner_identifier=OWNER, plaid_account_id=PACC,
                     balance=Decimal("100"), currency="USD", institution_domain="chase.com")
    incoming = Account(name="Chase Checking", owner_identifier=OWNER,
                       balance=Decimal("110"), currency="USD", institution_domain="chase.com")
    s.add_all([target, incoming])
    await s.flush()
    incoming.simplefin_connection_id = conn.id
    incoming.simplefin_account_id = "sf-acc"
    s.add_all([
        Transaction(account_id=target.id, plaid_transaction_id="p1", source=TransactionSource.plaid,
                    description="old", amount=Decimal("5"), date=date(2026, 6, 1), currency="USD",
                    owner_identifier=OWNER),  # target history -> boundary = 2026-06-01
        Transaction(account_id=incoming.id, external_transaction_id="s-pre", source=TransactionSource.simplefin,
                    description="pre", amount=Decimal("6"), date=date(2026, 5, 15), currency="USD",
                    owner_identifier=OWNER),
        Transaction(account_id=incoming.id, external_transaction_id="s-post", source=TransactionSource.simplefin,
                    description="post", amount=Decimal("7"), date=date(2026, 6, 10), currency="USD",
                    owner_identifier=OWNER),
    ])
    await s.commit()
    return target.id, incoming.id


async def test_merge_simplefin_primary_feeds_forward():
    from app.routers.simplefin import merge
    from app.schemas.simplefin import SimpleFinMergeRequest
    await _cleanup()
    try:
        async with async_session() as s:
            target_id, incoming_id = await _seed_merge_pair(s)
        async with async_session() as s:
            await merge(SimpleFinMergeRequest(incoming_account_id=incoming_id, target_account_id=target_id,
                                              primary_source=TransactionSource.simplefin),
                        caller=OWNER, session=s)
        async with async_session() as s:
            assert await s.get(Account, incoming_id) is None          # duplicate row removed
            t = await s.get(Account, target_id)
            assert t.primary_source == TransactionSource.simplefin    # adopted the chosen feed
            assert t.simplefin_account_id == "sf-acc"                 # + the SimpleFIN linkage
            assert t.merged_from_date == date(2026, 6, 1)             # boundary = target's last existing date
            exts = set(await s.scalars(select(Transaction.external_transaction_id).where(
                Transaction.account_id == target_id)))
            assert "s-post" in exts and "s-pre" not in exts          # forward moved, pre-boundary dropped
            assert await s.scalar(select(func.count()).select_from(Transaction).where(
                Transaction.account_id == target_id, Transaction.plaid_transaction_id == "p1")) == 1  # history kept
    finally:
        await _cleanup()


async def test_merge_plaid_primary_discards_incoming():
    from app.routers.simplefin import merge
    from app.schemas.simplefin import SimpleFinMergeRequest
    await _cleanup()
    try:
        async with async_session() as s:
            target_id, incoming_id = await _seed_merge_pair(s)
        async with async_session() as s:
            await merge(SimpleFinMergeRequest(incoming_account_id=incoming_id, target_account_id=target_id,
                                              primary_source=TransactionSource.plaid),
                        caller=OWNER, session=s)
        async with async_session() as s:
            assert await s.get(Account, incoming_id) is None
            t = await s.get(Account, target_id)
            assert t.primary_source == TransactionSource.plaid       # Plaid stays authoritative
            assert t.simplefin_account_id == "sf-acc"                # SimpleFIN linked but suppressed
            exts = set(await s.scalars(select(Transaction.external_transaction_id).where(
                Transaction.account_id == target_id)))
            assert "s-post" not in exts and "s-pre" not in exts      # SimpleFIN copies discarded
            assert await s.scalar(select(func.count()).select_from(Transaction).where(
                Transaction.account_id == target_id, Transaction.plaid_transaction_id == "p1")) == 1
    finally:
        await _cleanup()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
