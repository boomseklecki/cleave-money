"""Generic notifications feed: owner-scoped list (all sources) + mark-read. DB-backed, calling the router
functions directly."""
from uuid import uuid4

from fastapi import HTTPException
from sqlalchemy import delete

from app.db import async_session
from app.models import Notification
from app.models.enums import NotificationSource
from app.routers.notifications import hide_notification, list_notifications, mark_all_read, mark_read

ALICE, BOB = "ntf-alice", "ntf-bob"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(Notification).where(Notification.owner_identifier.in_([ALICE, BOB])))
        await s.commit()


async def _seed() -> None:
    async with async_session() as s:
        s.add(Notification(owner_identifier=ALICE, source=NotificationSource.splitwise,
                           splitwise_id="sw-1", type="expense_added", content="Alex added Dinner", read=False))
        s.add(Notification(owner_identifier=ALICE, source=NotificationSource.app,
                           type="shared_budget", content="Alex created a Dining budget", read=False))
        s.add(Notification(owner_identifier=BOB, source=NotificationSource.app,
                           type="connection", content="Sam wants to connect", read=False))
        await s.commit()


async def test_list_scoped_to_owner_all_sources():
    await _purge(); await _seed()
    try:
        async with async_session() as s:
            mine = await list_notifications(caller=ALICE, session=s)
            assert len(mine) == 2                                   # both Alice's, both sources
            assert {n.source for n in mine} == {NotificationSource.splitwise, NotificationSource.app}
        async with async_session() as s:
            theirs = await list_notifications(caller=BOB, session=s)
            assert len(theirs) == 1
    finally:
        await _purge()


async def test_mark_read_by_owner():
    await _purge(); await _seed()
    try:
        async with async_session() as s:
            target = (await list_notifications(caller=ALICE, session=s))[0]
        async with async_session() as s:
            updated = await mark_read(target.id, caller=ALICE, session=s)
            assert updated.read is True
    finally:
        await _purge()


async def test_mark_read_other_owner_forbidden():
    await _purge(); await _seed()
    try:
        async with async_session() as s:
            target = (await list_notifications(caller=ALICE, session=s))[0]
        async with async_session() as s:
            try:
                await mark_read(target.id, caller=BOB, session=s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
    finally:
        await _purge()


async def test_mark_read_missing_404():
    async with async_session() as s:
        try:
            await mark_read(uuid4(), caller=ALICE, session=s)
            raise AssertionError("expected 404")
        except HTTPException as e:
            assert e.status_code == 404


async def test_hide_excludes_from_list_owner_only():
    await _purge(); await _seed()
    try:
        async with async_session() as s:
            target = (await list_notifications(caller=ALICE, session=s))[0]
        async with async_session() as s:
            await hide_notification(target.id, caller=ALICE, session=s)
        async with async_session() as s:
            remaining = await list_notifications(caller=ALICE, session=s)
            assert target.id not in {n.id for n in remaining}      # hidden row gone from the feed
            assert len(remaining) == 1
        # Cross-owner hide is forbidden.
        async with async_session() as s:
            other = (await list_notifications(caller=ALICE, session=s))[0]
        async with async_session() as s:
            try:
                await hide_notification(other.id, caller=BOB, session=s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
    finally:
        await _purge()


async def test_mark_all_read():
    await _purge(); await _seed()
    try:
        async with async_session() as s:
            result = await mark_all_read(caller=ALICE, session=s)
            assert result["updated"] == 2                          # both Alice's, none of Bob's
        async with async_session() as s:
            assert all(n.read for n in await list_notifications(caller=ALICE, session=s))
        async with async_session() as s:
            assert not any(n.read for n in await list_notifications(caller=BOB, session=s))   # Bob untouched
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
