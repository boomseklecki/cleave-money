"""Scoped (drill-in) Splitwise syncs + the new friends/notifications sources.

`sw_client` fetchers are monkeypatched (no live Splitwise); everything else hits the real DB. Covers:
  - scoped group / single-expense syncs do NOT advance the shared token cursor (`expenses_synced_at`),
  - `sync_friends` caches identity into the friends table (+ users directory),
  - `sync_notifications` upserts and prunes to the retention count.
"""
from datetime import datetime, timezone

from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.splitwise import client as c
from app.integrations.splitwise import importer
from app.models import Expense, Friend, Group, Notification, Split, SplitwiseToken, User
from app.routers.splitwise import sync_expense as sync_expense_endpoint
from app.routers.splitwise import sync_group as sync_group_endpoint
from app.schemas.splitwise import SyncRequest

GROUP_KEY = "scoped-grp-zzz"
EXP_KEY = "scoped-exp-zzz"
TOKEN_USER = "scopedtok"
FRIEND_SWID = "scoped-friend-99"
CURSOR = datetime(2024, 1, 1, 12, 0, 0, tzinfo=timezone.utc)


def _expense(splitwise_id, *, deleted=False):
    return {
        "splitwise_id": splitwise_id,
        "group_id": GROUP_KEY,
        "description": "scoped expense",
        "cost": "10.00",
        "currency_code": "USD",
        "date": "2023-01-15T00:00:00Z",
        "category": "Groceries",
        "payment": False,
        "deleted_at": "2023-02-01T00:00:00Z" if deleted else None,
        "receipt_url": None,
        "repayments": None,
        "users": [
            {"user_id": "9101", "first_name": "ScopedA", "paid_share": "10.00", "owed_share": "5.00"},
            {"user_id": "9102", "first_name": "ScopedB", "paid_share": "0.00", "owed_share": "5.00"},
        ],
    }


async def _purge():
    async with async_session() as s:
        exp_ids = (
            await s.scalars(select(Expense.id).where(Expense.splitwise_expense_id == EXP_KEY))
        ).all()
        if exp_ids:
            await s.execute(delete(Split).where(Split.expense_id.in_(exp_ids)))
        await s.execute(delete(Expense).where(Expense.splitwise_expense_id == EXP_KEY))
        await s.execute(delete(Group).where(Group.splitwise_group_id == GROUP_KEY))
        await s.execute(delete(User).where(User.splitwise_user_id.in_(["9101", "9102", FRIEND_SWID])))
        await s.execute(delete(Friend).where(Friend.owner_identifier == TOKEN_USER))
        await s.execute(delete(Notification).where(Notification.owner_identifier == TOKEN_USER))
        await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == TOKEN_USER))
        await s.commit()


async def _seed_token():
    async with async_session() as s:
        s.add(SplitwiseToken(user_identifier=TOKEN_USER, access_token="x", expenses_synced_at=CURSOR))
        await s.commit()


async def test_scoped_group_sync_leaves_cursor_untouched():
    await _purge()
    await _seed_token()
    orig_make, orig_groups, orig_exp = c.make_client, c.fetch_groups, c.fetch_expenses
    c.make_client = lambda token: object()
    c.fetch_groups = lambda client: [{"splitwise_id": GROUP_KEY, "name": "Trip", "members": []}]
    c.fetch_expenses = lambda client, **kw: [_expense(EXP_KEY)]
    try:
        async with async_session() as s:
            result = await sync_group_endpoint(
                GROUP_KEY, SyncRequest(as_user=TOKEN_USER), caller=None, session=s
            )
            assert result.imported == 1
        async with async_session() as s:
            stamped = await s.scalar(
                select(SplitwiseToken.expenses_synced_at).where(
                    SplitwiseToken.user_identifier == TOKEN_USER
                )
            )
            assert stamped == CURSOR  # scoped sync must NOT advance the shared cursor
    finally:
        c.make_client, c.fetch_groups, c.fetch_expenses = orig_make, orig_groups, orig_exp
        await _purge()


async def test_scoped_single_expense_sync_leaves_cursor_untouched():
    await _purge()
    await _seed_token()
    orig_make, orig_one = c.make_client, c.fetch_expense
    c.make_client = lambda token: object()
    c.fetch_expense = lambda client, expense_id: _expense(EXP_KEY)
    try:
        async with async_session() as s:
            result = await sync_expense_endpoint(
                EXP_KEY, SyncRequest(as_user=TOKEN_USER), caller=None, session=s
            )
            assert result.imported == 1
        async with async_session() as s:
            stamped = await s.scalar(
                select(SplitwiseToken.expenses_synced_at).where(
                    SplitwiseToken.user_identifier == TOKEN_USER
                )
            )
            assert stamped == CURSOR
    finally:
        c.make_client, c.fetch_expense = orig_make, orig_one
        await _purge()


async def test_sync_friends_caches_identity():
    await _purge()
    friend = {
        "splitwise_id": FRIEND_SWID,
        "first_name": "Solo",
        "last_name": "Friend",
        "email": "solo@example.com",
        "picture": "https://example.com/a.png",
        "balances": [],
        "groups": [],
    }
    orig = c.fetch_friends
    c.fetch_friends = lambda client: [friend]
    try:
        async with async_session() as s:
            stats = await importer.sync_friends(s, object(), {}, TOKEN_USER)
            assert stats["friends"] == 1
        async with async_session() as s:
            row = await s.scalar(
                select(Friend).where(
                    Friend.owner_identifier == TOKEN_USER, Friend.splitwise_friend_id == FRIEND_SWID
                )
            )
            assert row is not None and row.email == "solo@example.com"
            # the directory is also filled so the friend resolves to a name even with no shared group
            user = await s.scalar(select(User).where(User.splitwise_user_id == FRIEND_SWID))
            assert user is not None
    finally:
        c.fetch_friends = orig
        await _purge()


async def test_sync_notifications_upserts_and_prunes():
    await _purge()

    def _note(i):
        return {
            "splitwise_id": f"scoped-note-{i}",
            "type": "expense_added",
            "content": f"notification {i}",
            "created_at": f"2024-0{i}-01T00:00:00Z",
        }

    notes = [_note(i) for i in range(1, 6)]  # 5 notifications, ascending dates
    orig = c.fetch_notifications
    c.fetch_notifications = lambda client, access_token=None, limit=None: notes
    try:
        async with async_session() as s:
            await importer.sync_notifications(s, object(), TOKEN_USER, retention=3)
        async with async_session() as s:
            count = await s.scalar(
                select(func.count()).select_from(Notification).where(
                    Notification.owner_identifier == TOKEN_USER
                )
            )
            assert count == 3  # pruned to the newest 3
            kept = (
                await s.scalars(
                    select(Notification.splitwise_id)
                    .where(Notification.owner_identifier == TOKEN_USER)
                    .order_by(Notification.created_at.desc())
                )
            ).all()
            assert kept == ["scoped-note-5", "scoped-note-4", "scoped-note-3"]
        # Re-running is idempotent (dedup by splitwise_id) and stays pruned.
        async with async_session() as s:
            await importer.sync_notifications(s, object(), TOKEN_USER, retention=3)
        async with async_session() as s:
            count = await s.scalar(
                select(func.count()).select_from(Notification).where(
                    Notification.owner_identifier == TOKEN_USER
                )
            )
            assert count == 3
    finally:
        c.fetch_notifications = orig
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
