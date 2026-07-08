"""Concurrent /plaid/sync for the same item serializes on a per-item row lock, so the two runs don't both
fetch from the same cursor (redundant Plaid calls / page reprocessing). Audit Medium #16. The Plaid client is
stubbed - no network."""
import asyncio

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.plaid import client as plaid_client
from app.models import Account, PlaidItem, Transaction
from app.routers.plaid import run_sync

OWNER = "cursor-lock-zzz"


async def _purge():
    async with async_session() as s:
        ids = list(await s.scalars(select(PlaidItem.id).where(PlaidItem.user_identifier == OWNER)))
        if ids:
            aids = list(await s.scalars(select(Account.id).where(Account.plaid_item_id.in_(ids))))
            if aids:
                await s.execute(delete(Transaction).where(Transaction.account_id.in_(aids)))
                await s.execute(delete(Account).where(Account.id.in_(aids)))
            await s.execute(delete(PlaidItem).where(PlaidItem.id.in_(ids)))
        await s.commit()


class _FakeClient:
    """Records the cursor each fetch starts from; returns a terminal page advancing to a fresh cursor."""
    def __init__(self):
        self.seen: list = []
        self.n = 0

    def get_accounts(self, access_token):
        return []

    def fetch_transactions_page(self, access_token, cursor):
        self.seen.append(cursor)
        self.n += 1
        return {"added": [], "modified": [], "removed": [], "next_cursor": f"cur-{self.n}", "has_more": False}


async def test_concurrent_sync_serializes_cursor():
    await _purge()
    fake = _FakeClient()  # one shared instance so the cursor chain + counter are observed across both requests
    orig = plaid_client.make_client
    plaid_client.make_client = lambda *a, **k: fake
    try:
        async with async_session() as s:
            s.add(PlaidItem(plaid_item_id="cursor-lock-item", access_token="x", user_identifier=OWNER,
                            institution_id="inst-1", transactions_cursor="cur-0"))  # inst set -> skip resolve
            await s.commit()

        async def _one():
            async with async_session() as s:
                return await run_sync(body=None, caller=OWNER, session=s)
        await asyncio.gather(_one(), _one())

        assert len(fake.seen) == 2                          # each request fetched exactly once
        assert fake.seen[0] == "cur-0"                      # first started from the stored cursor
        assert fake.seen[1] == "cur-1"                      # second saw the first's advance (NOT "cur-0" again)
        assert len(set(fake.seen)) == 2                     # no two fetches from the same cursor
        async with async_session() as s:
            item = await s.scalar(select(PlaidItem).where(PlaidItem.user_identifier == OWNER))
            assert item.transactions_cursor == "cur-2"      # both advances applied in order
    finally:
        plaid_client.make_client = orig
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
