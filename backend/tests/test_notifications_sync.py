"""Splitwise notification sync: HTML cleanup + the delta push (new, non-self activity pushes; backfill and
own actions don't). DB-backed; fakes the Splitwise fetch + captures push.enqueue."""
from datetime import date, datetime, timezone
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.splitwise import importer
from app.integrations.splitwise.client import _clean_content
from app.models import BackendType, Expense, Group, Notification, NotificationMute, SplitwiseToken
from app.models.enums import NotificationSource
from app.services import sync

OWNER = "nsync-owner"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(Notification).where(Notification.owner_identifier == OWNER))
        await s.execute(delete(NotificationMute).where(NotificationMute.owner_identifier == OWNER))
        await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == OWNER))
        await s.commit()


async def _seed_token(watermark: datetime | None = None):
    """The owner's Splitwise token holds the push watermark; sync_notifications reads + advances it."""
    async with async_session() as s:
        await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == OWNER))
        s.add(SplitwiseToken(user_identifier=OWNER, access_token="x", notifications_pushed_at=watermark))
        await s.commit()


async def _watermark() -> datetime | None:
    async with async_session() as s:
        return await s.scalar(select(SplitwiseToken.notifications_pushed_at).where(
            SplitwiseToken.user_identifier == OWNER))


def _dt(day: int) -> datetime:
    return datetime(2026, 6, day, 12, 0, tzinfo=timezone.utc)


def _fake_fetch(notes, limit_holder=None):
    """A stand-in for sw_client.fetch_notifications returning canned, already-normalized notes."""
    def fetch(client, access_token=None, limit=None):
        if limit_holder is not None:
            limit_holder.append(limit)
        return notes
    return fetch


async def _sync(notes, *, push, retention=100, capture=None, limit_holder=None):
    orig_fetch, orig_push = importer.sw_client.fetch_notifications, importer.push_enqueue
    importer.sw_client.fetch_notifications = _fake_fetch(notes, limit_holder)
    importer.push_enqueue = (lambda owners, title, body, target=None: capture.append((owners, body, target))) \
        if capture is not None else (lambda *a, **k: None)
    try:
        async with async_session() as s:
            return await importer.sync_notifications(
                s, client=None, owner_identifier=OWNER, retention=retention, access_token="t", push=push)
    finally:
        importer.sw_client.fetch_notifications, importer.push_enqueue = orig_fetch, orig_push


def _note(swid, content, created="2026-06-20T12:00:00Z", source_type=None, source_id=None):
    return {"splitwise_id": swid, "type": "expense_added", "content": content, "created_at": created,
            "source_type": source_type, "source_id": source_id}


def test_clean_content_strips_html_and_entities():
    assert _clean_content('<strong>Alex</strong> added &quot;Dinner&quot;') == 'Alex added "Dinner"'
    assert _clean_content(None) == ""


async def test_push_only_after_watermark_non_self():
    await _purge()
    try:
        await _seed_token(watermark=_dt(19))   # already accounted for everything up to the 19th
        captured: list = []
        holder: list = []
        await _sync([_note("sw-new", "Alex added Dinner", _dt(20).isoformat()),   # after watermark → alert
                     _note("sw-self", "You added Lunch", _dt(20).isoformat()),    # self → no
                     _note("sw-old", "Sam added Coffee", _dt(18).isoformat())],   # before watermark → no
                    push=True, capture=captured, limit_holder=holder)
        assert holder == [100]                                  # fetch count tracks retention (min(100,100))
        assert len(captured) == 1 and captured[0][1] == "Alex added Dinner"   # only the new, non-self note
        async with async_session() as s:
            ids = set(await s.scalars(select(Notification.splitwise_id).where(
                Notification.owner_identifier == OWNER)))
        assert ids == {"sw-old", "sw-new", "sw-self"}           # all in the feed (full log incl. self)
        assert await _watermark() == _dt(20)                    # advanced to the newest seen
    finally:
        await _purge()


async def test_cold_start_lands_rows_without_pushing():
    await _purge()
    try:
        # Null watermark = first sync → no push even with push=True; rows still land + the watermark advances.
        await _seed_token(watermark=None)
        captured: list = []
        await _sync([_note("c-1", "Alex added Dinner", _dt(18).isoformat()),
                     _note("c-2", "Sam added Coffee", _dt(19).isoformat())],
                    push=True, capture=captured)
        assert captured == []                                   # cold start: no flood
        assert await _watermark() == _dt(19)
        # A later sync pushes only what's genuinely newer than the (now-advanced) watermark.
        await _sync([_note("c-1", "Alex added Dinner", _dt(18).isoformat()),
                     _note("c-3", "Pat added Tea", _dt(20).isoformat())],
                    push=True, capture=captured)
        assert len(captured) == 1 and captured[0][1] == "Pat added Tea"
    finally:
        await _purge()


async def test_no_repush_of_pruned_then_refetched():
    # The original bug: an old notification pruned from storage, re-fetched, re-counted as "new" → re-pushed.
    # With the watermark it must NOT re-push once seen.
    await _purge()
    try:
        await _seed_token(watermark=None)
        batch = [_note("r-1", "Alex added Dinner", _dt(18).isoformat()),
                 _note("r-2", "Sam added Coffee", _dt(19).isoformat())]
        captured: list = []
        await _sync(batch, push=True, capture=captured)         # cold start → no push, watermark → 19th
        await _sync(batch, push=True, capture=captured)         # exact same batch, all ≤ watermark
        assert captured == []                                   # never re-pushed
    finally:
        await _purge()


async def test_splitwise_expense_source_deep_links_to_local_expense():
    await _purge()
    async with async_session() as s:
        g = Group(name="SW-grp", backend_type=BackendType.splitwise)
        s.add(g); await s.flush()
        e = Expense(group_id=g.id, splitwise_expense_id="SW123", description="Dinner",
                    amount=Decimal("10.00"), date=date(2026, 6, 20))
        s.add(e); await s.commit()
        eid, gid = str(e.id), g.id
    try:
        await _seed_token(watermark=_dt(19))
        captured: list = []
        # A Splitwise notification whose source is the expense SW123 → resolves to the local expense.
        await _sync([_note("n-1", "Alex added Dinner", _dt(20).isoformat(),
                           source_type="Expense", source_id="SW123"),
                     # ...and one referencing an expense we don't have locally → stays unlinked.
                     _note("n-2", "Sam added Lunch", _dt(20).isoformat(),
                           source_type="Expense", source_id="SW-UNKNOWN")],
                    push=True, capture=captured)
        async with async_session() as s:
            rows = {n.splitwise_id: n for n in await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER))}
        assert rows["n-1"].entity_type == "expense" and rows["n-1"].entity_id == eid   # deep-linked
        assert rows["n-2"].entity_type is None and rows["n-2"].entity_id is None       # not local → null
        # The individual push for n-1 carries the matching deep-link target.
        n1 = next(c for c in captured if c[1] == "Alex added Dinner")
        assert n1[2] == {"type": "expense", "id": eid}
    finally:
        async with async_session() as s:
            await s.execute(delete(Group).where(Group.id == gid))   # cascades the expense
            await s.commit()
        await _purge()


async def test_splitwise_group_source_deep_links_to_local_group():
    await _purge()
    async with async_session() as s:
        g = Group(name="SW-grp", backend_type=BackendType.splitwise, splitwise_group_id="SWG1")
        s.add(g); await s.commit()
        gid = str(g.id)
    try:
        await _seed_token(watermark=_dt(19))
        captured: list = []
        await _sync([_note("g-1", "Alex created the group", _dt(20).isoformat(),
                           source_type="Group", source_id="SWG1"),
                     _note("g-2", "Sam joined an unknown group", _dt(20).isoformat(),
                           source_type="Group", source_id="SWG-UNKNOWN")],
                    push=True, capture=captured)
        async with async_session() as s:
            rows = {n.splitwise_id: n for n in await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER))}
        assert rows["g-1"].entity_type == "group" and rows["g-1"].entity_id == gid   # deep-linked
        assert rows["g-2"].entity_type is None and rows["g-2"].entity_id is None     # not local → null
        n1 = next(c for c in captured if c[1] == "Alex created the group")
        assert n1[2] == {"type": "group", "id": gid}
    finally:
        async with async_session() as s:
            await s.execute(delete(Group).where(Group.splitwise_group_id == "SWG1"))
            await s.commit()
        await _purge()


async def test_push_mute_splitwise_source_keeps_feed_drops_push():
    await _purge()
    try:
        await _seed_token(watermark=_dt(19))
        async with async_session() as s:
            s.add(NotificationMute(owner_identifier=OWNER, token="push:source:splitwise"))
            await s.commit()
        captured: list = []
        await _sync([_note("m-new", "Alex added Dinner", _dt(20).isoformat()),
                     _note("m-old", "Sam added Coffee", _dt(18).isoformat())],
                    push=True, capture=captured)
        assert captured == []                                   # push muted for splitwise → no alert
        async with async_session() as s:
            ids = set(await s.scalars(select(Notification.splitwise_id).where(
                Notification.owner_identifier == OWNER)))
        assert ids == {"m-old", "m-new"}                        # but the row still lands (feed intact)
    finally:
        await _purge()


async def test_resync_preserves_user_hide():
    await _purge()
    try:
        # The owner hid a Splitwise row; re-fetching it must NOT unhide it (the upsert never sets hidden).
        async with async_session() as s:
            s.add(Notification(owner_identifier=OWNER, source=NotificationSource.splitwise,
                               splitwise_id="h-1", content="Old content", hidden=True))
            await s.commit()
        await _sync([_note("h-1", "Updated content")], push=False)   # same id re-synced (content changes)
        async with async_session() as s:
            row = await s.scalar(select(Notification).where(
                Notification.owner_identifier == OWNER, Notification.splitwise_id == "h-1"))
        assert row.hidden is True and row.content == "Updated content"   # stays hidden, content refreshed
    finally:
        await _purge()


async def test_fetch_count_capped_at_max_fetch():
    await _purge()
    try:
        holder: list = []
        await _sync([], push=False, retention=1000, limit_holder=holder)   # retention above the cap
        assert holder == [importer._MAX_FETCH]                  # bounded fetch (min(1000, 100))
    finally:
        await _purge()


async def test_backfill_does_not_push():
    await _purge()
    try:
        captured: list = []
        await _sync([_note("b-1", "Alex added Dinner"), _note("b-2", "Sam settled up")],
                    push=False, capture=captured)
        assert captured == []                                   # connect/backfill never pushes, even all-new
        async with async_session() as s:
            ids = set(await s.scalars(select(Notification.splitwise_id).where(
                Notification.owner_identifier == OWNER)))
        assert ids == {"b-1", "b-2"}                            # but rows still landed
    finally:
        await _purge()


async def test_resync_updates_content_without_repush():
    await _purge()
    try:
        await _sync([_note("r-1", "Alex added Dinner")], push=True)            # first time → new
        captured: list = []
        await _sync([_note("r-1", "Alex updated Dinner")], push=True, capture=captured)  # seen id → no push
        assert captured == []
        async with async_session() as s:
            row = await s.scalar(select(Notification).where(
                Notification.owner_identifier == OWNER, Notification.splitwise_id == "r-1"))
            assert row.content == "Alex updated Dinner"          # content refreshed
    finally:
        await _purge()


_TOK_A, _TOK_B = "nsync-tok-a", "nsync-tok-b"


async def test_sync_notifications_all_per_token_isolation():
    async with async_session() as s:
        await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier.in_([_TOK_A, _TOK_B])))
        s.add(SplitwiseToken(user_identifier=_TOK_A, access_token="x"))
        s.add(SplitwiseToken(user_identifier=_TOK_B, access_token="x"))
        await s.commit()
    calls: list = []

    async def fake_sync(session, client, owner, *, retention, access_token=None, push=False):
        calls.append((owner, push))
        if owner == _TOK_A:
            raise RuntimeError("boom")   # one token fails → must not abort the other

    orig_mk, orig_sync = sync.sw_client.make_client, sync.importer.sync_notifications
    sync.sw_client.make_client = lambda token: object()
    sync.importer.sync_notifications = fake_sync
    try:
        async with async_session() as s:
            count = await sync.sync_notifications_all(s)
        assert {o for o, _ in calls} == {_TOK_A, _TOK_B}        # every token attempted
        assert all(p is True for _, p in calls)                 # poll always pushes
        assert count == 1                                       # B succeeded, A raised (isolated)
    finally:
        sync.sw_client.make_client, sync.importer.sync_notifications = orig_mk, orig_sync
        async with async_session() as s:
            await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier.in_([_TOK_A, _TOK_B])))
            await s.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
