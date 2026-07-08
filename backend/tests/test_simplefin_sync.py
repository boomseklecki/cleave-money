"""SimpleFIN sync: apply_sync upsert/negation/dedup, pending reap, backfill paging, staleness gate."""
from datetime import UTC, datetime, timedelta
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.simplefin import sync as sf_sync
from app.models import Account, SimpleFinConnection, Transaction, TransactionSource

OWNER = "sf-owner-zzz"
ACC = "sf-acc-zzz"
_NOW = datetime.now(tz=UTC)
_RECENT = int(_NOW.timestamp())  # a recent posted epoch so reaped/kept rows fall inside the fetch window


def _account_set(txns, balance="100.00"):
    return {
        "accounts": [{
            "id": ACC, "name": "Checking", "currency": "USD", "balance": balance,
            "org": {"name": "TestBank", "domain": "testbank.example"},
            "transactions": txns,
        }],
        "since_date": (_NOW - timedelta(days=90)).date(),
        "warnings": [],
    }


def _txn(tid, amount, pending=False):
    return {"id": tid, "amount": amount, "description": "Coffee", "posted": _RECENT, "pending": pending}


async def _cleanup():
    async with async_session() as session:
        acc_ids = (await session.scalars(select(Account.id).where(Account.owner_identifier == OWNER))).all()
        if acc_ids:
            await session.execute(delete(Transaction).where(Transaction.account_id.in_(acc_ids)))
            await session.execute(delete(Account).where(Account.id.in_(acc_ids)))
        await session.execute(delete(SimpleFinConnection).where(SimpleFinConnection.user_identifier == OWNER))
        await session.commit()


def test_is_stale_gate():
    conn = SimpleFinConnection(access_url="x")
    conn.last_synced_at = None
    assert sf_sync.is_stale(conn, 720) is True                                   # never synced
    conn.last_synced_at = datetime.now(tz=UTC) - timedelta(minutes=30)
    assert sf_sync.is_stale(conn, 720) is False                                  # 30m < 12h
    conn.last_synced_at = datetime.now(tz=UTC) - timedelta(hours=13)
    assert sf_sync.is_stale(conn, 720) is True                                   # 13h > 12h


async def test_backfill_pages_backward_and_stops_on_empty():
    class FakeClient:
        def __init__(self):
            self.calls = []

        def fetch_account_set(self, access_url, start_date, end_date=None, pending=True):
            self.calls.append((start_date, end_date))
            has = len(self.calls) <= 2  # first two windows have data; the third is empty -> stop
            txns = [_txn(f"w{len(self.calls)}", "1.00")] if has else []
            return {"accounts": [{"id": ACC, "balance": "1", "org": {}, "transactions": txns}], "errors": []}

    client = FakeClient()
    fetched = await sf_sync._fetch_windows(client, "https://u:p@sf.example/access", None)  # None = backfill
    assert len(client.calls) == 3                              # stopped one window past the last data
    assert all(c[1] is not None for c in client.calls)         # backfill windows carry an end-date
    assert len(fetched["accounts"][0]["transactions"]) == 2    # w1 + w2 merged


async def test_incremental_single_window():
    class FakeClient:
        def __init__(self):
            self.calls = []

        def fetch_account_set(self, access_url, start_date, end_date=None, pending=True):
            self.calls.append((start_date, end_date))
            return {"accounts": [], "errors": []}

    client = FakeClient()
    fetched = await sf_sync._fetch_windows(client, "url", datetime.now(tz=UTC) - timedelta(days=1))
    assert len(client.calls) == 1 and client.calls[0][1] is None  # one window, open-ended (no end-date)
    assert fetched["warnings"] == []


async def test_apply_sync_negates_upserts_dedups():
    await _cleanup()
    try:
        async with async_session() as session:
            conn = SimpleFinConnection(access_url="https://u:p@sf/access", user_identifier=OWNER)
            session.add(conn)
            await session.commit()

            stats = await sf_sync.apply_sync(
                session, conn, _account_set([_txn("t1", "100.00"), _txn("t2", "-40.00")]))
            assert stats["accounts"] == 1 and stats["transactions"] == 2

            acc_id = await session.scalar(
                select(Account.id).where(Account.simplefin_connection_id == conn.id))
            amt1 = await session.scalar(select(Transaction.amount).where(
                Transaction.account_id == acc_id, Transaction.external_transaction_id == "t1"))
            amt2 = await session.scalar(select(Transaction.amount).where(
                Transaction.account_id == acc_id, Transaction.external_transaction_id == "t2"))
            assert amt1 == Decimal("-100.00") and amt2 == Decimal("40.00")  # negated
            src = await session.scalar(select(Transaction.source).where(
                Transaction.account_id == acc_id, Transaction.external_transaction_id == "t1"))
            assert src == TransactionSource.simplefin
            inst = await session.scalar(select(Account.institution_domain).where(Account.id == acc_id))
            assert inst == "testbank.example"  # branding from account.org

            # Re-apply the same set -> no duplicate rows, balance stable (per-account external-id dedup).
            await sf_sync.apply_sync(session, conn, _account_set([_txn("t1", "100.00"), _txn("t2", "-40.00")]))
            n = await session.scalar(
                select(func.count()).select_from(Transaction).where(Transaction.account_id == acc_id))
            assert n == 2
            assert await session.scalar(select(Account.balance).where(Account.id == acc_id)) == Decimal("100.00")
    finally:
        await _cleanup()


async def test_pending_reap_when_gone_from_window():
    await _cleanup()
    try:
        async with async_session() as session:
            conn = SimpleFinConnection(access_url="x", user_identifier=OWNER)
            session.add(conn)
            await session.commit()

            await sf_sync.apply_sync(session, conn, _account_set([_txn("p1", "10.00", pending=True)]))
            acc_id = await session.scalar(
                select(Account.id).where(Account.simplefin_connection_id == conn.id))
            assert await session.scalar(
                select(func.count()).select_from(Transaction).where(Transaction.account_id == acc_id)) == 1

            # Next window no longer lists the pending row -> reaped (SimpleFIN sends no `removed`).
            stats = await sf_sync.apply_sync(session, conn, _account_set([]))
            assert stats["reaped"] == 1
            assert await session.scalar(
                select(func.count()).select_from(Transaction).where(Transaction.account_id == acc_id)) == 0
    finally:
        await _cleanup()


async def test_match_candidates_tier_on_mask():
    from app.routers.simplefin import _match_candidates
    await _cleanup()
    try:
        async with async_session() as session:
            # An existing Plaid account (chase.com, ending 1234) is the candidate to match against.
            session.add(Account(name="Chase", owner_identifier=OWNER, plaid_account_id="p-sf-zzz",
                                institution_domain="chase.com", mask="1234", currency="USD"))
            conn = SimpleFinConnection(access_url="x", user_identifier=OWNER)
            session.add(conn)
            await session.flush()
            strong = Account(name="Chase Checking", owner_identifier=OWNER, simplefin_connection_id=conn.id,
                             simplefin_account_id="a1", institution_domain="chase.com", mask="1234",
                             currency="USD")
            soft = Account(name="Chase Savings", owner_identifier=OWNER, simplefin_connection_id=conn.id,
                           simplefin_account_id="a2", institution_domain="chase.com", mask="9999",
                           currency="USD")
            other = Account(name="Elsewhere", owner_identifier=OWNER, simplefin_connection_id=conn.id,
                            simplefin_account_id="a3", institution_domain="elsewhere.example", currency="USD")
            session.add_all([strong, soft, other])
            await session.commit()

            by_name = {m.name: m for m in await _match_candidates(session, OWNER, [strong, soft, other])}
            assert "Elsewhere" not in by_name                                   # different institution -> no match
            assert by_name["Chase Checking"].candidates[0].strong is True       # institution + mask 1234
            assert by_name["Chase Checking"].candidates[0].source == "plaid"    # candidate is the Plaid account
            assert by_name["Chase Savings"].candidates[0].strong is False       # institution only (9999 != 1234)
    finally:
        await _cleanup()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
