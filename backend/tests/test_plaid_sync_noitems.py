"""POST /plaid/sync with no linked banks: "sync all" is a graceful no-op (0 synced), while requesting a
specific missing item still 404s.

Regression: manual/OFX-import-only users (and demo guests) have no Plaid items. The iOS bank-refresh path
runs this sync BEFORE reloading accounts; a 404 here aborted the whole refresh, so their own (manual)
accounts never loaded - only partner-shared accounts showed.
"""
import uuid

from fastapi import HTTPException

from app.db import async_session
from app.routers.plaid import run_sync
from app.schemas.plaid import SyncRequest


async def test_sync_all_no_items_is_noop():
    async with async_session() as session:
        resp = await run_sync(body=None, caller="noplaid-zzz", session=session)
    assert resp.items_synced == 0 and resp.accounts == 0 and resp.added == 0


async def test_sync_specific_missing_item_still_404s():
    async with async_session() as session:
        try:
            await run_sync(body=SyncRequest(item_id=uuid.uuid4()), caller="noplaid-zzz", session=session)
            assert False, "expected 404 for a requested item that does not exist"
        except HTTPException as e:
            assert e.status_code == 404


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
