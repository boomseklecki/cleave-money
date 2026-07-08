"""App-source notification producer: shared events write `app` Notification rows for the right recipients
(group members for splits, audience for sharing), never the actor. DB-backed, calling router fns directly.
APNs is unconfigured in tests so the push is a no-op."""
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.models import (Account, BackendType, Connection, Expense, Goal, Group, GroupMember,
                        Notification, NotificationMute, User)
from app.services import notify as notify_svc
from app.models.enums import NotificationSource, ShareLevel
from app.routers.accounts import update_account
from app.routers.connections import accept_connection, create_connection
from app.routers.expenses import create_expense
from app.routers.goals import create_goal
from app.schemas.account import AccountUpdate
from app.schemas.connection import ConnectionCreate
from app.schemas.expense import ExpenseCreate, SplitInput
from app.schemas.goal import GoalCreate

ALICE, BOB = "ntp-alice", "ntp-bob"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(Notification).where(Notification.owner_identifier.in_([ALICE, BOB])))
        await s.execute(delete(NotificationMute).where(NotificationMute.owner_identifier.in_([ALICE, BOB])))
        await s.execute(delete(Connection).where(
            Connection.requester_identifier.in_([ALICE, BOB]) | Connection.addressee_identifier.in_([ALICE, BOB])))
        await s.execute(delete(Goal).where(Goal.owner_identifier == ALICE))
        await s.execute(delete(Account).where(Account.owner_identifier == ALICE))
        gids = (await s.scalars(select(GroupMember.group_id).where(
            GroupMember.user_identifier.in_([ALICE, BOB])))).all()
        if gids:
            await s.execute(delete(Expense).where(Expense.group_id.in_(gids)))
            await s.execute(delete(GroupMember).where(GroupMember.group_id.in_(gids)))
            await s.execute(delete(Group).where(Group.id.in_(gids)))
        await s.execute(delete(User).where(User.identifier.in_([ALICE, BOB])))
        await s.commit()


async def _seed_users():
    async with async_session() as s:
        s.add(User(identifier=ALICE, display_name="Alice", source="app", email="a@x.com"))
        s.add(User(identifier=BOB, display_name="Bob", source="app", email="b@x.com"))
        await s.commit()


async def _connect_and_accept():
    async with async_session() as s:
        conn = await create_connection(ConnectionCreate(identifier=BOB), caller=ALICE, session=s)
    async with async_session() as s:
        await accept_connection(conn.id, caller=BOB, session=s)


async def _types(owner: str) -> set[str]:
    async with async_session() as s:
        rows = await s.scalars(select(Notification).where(
            Notification.owner_identifier == owner, Notification.source == NotificationSource.app))
        return {n.type for n in rows}


async def test_connection_request_and_accept():
    await _purge(); await _seed_users()
    try:
        async with async_session() as s:
            conn = await create_connection(ConnectionCreate(identifier=BOB), caller=ALICE, session=s)
        assert "connection_request" in await _types(BOB)
        assert "connection_request" not in await _types(ALICE)       # actor not notified
        async with async_session() as s:
            await accept_connection(conn.id, caller=BOB, session=s)
        assert "connection_accepted" in await _types(ALICE)
    finally:
        await _purge()


async def test_shared_goal_notifies_partner():
    await _purge(); await _seed_users(); await _connect_and_accept()
    try:
        async with async_session() as s:
            await create_goal(GoalCreate(kind="spend", name="Dining", category="Dining",
                                         target_amount=Decimal("100"), shared=True), caller=ALICE, session=s)
        assert "goal_shared" in await _types(BOB)
    finally:
        await _purge()


async def test_shared_account_notifies_partner():
    await _purge(); await _seed_users(); await _connect_and_accept()
    async with async_session() as s:
        a = Account(name="Checking", balance=Decimal("0"), currency="USD",
                    owner_identifier=ALICE, share_level=ShareLevel.private)
        s.add(a); await s.commit(); aid = a.id
    try:
        async with async_session() as s:
            await update_account(aid, AccountUpdate(share_level="full"), caller=ALICE, session=s)
        assert "account_shared" in await _types(BOB)
    finally:
        await _purge()


async def test_local_expense_notifies_members_not_actor():
    await _purge(); await _seed_users()
    async with async_session() as s:
        g = Group(name="House", backend_type=BackendType.self_hosted)
        s.add(g); await s.flush()
        s.add_all([GroupMember(group_id=g.id, user_identifier=ALICE),
                   GroupMember(group_id=g.id, user_identifier=BOB)])
        await s.commit(); gid = g.id
    try:
        async with async_session() as s:
            await create_expense(ExpenseCreate(
                group_id=gid, description="Dinner", amount=Decimal("100"), date=date(2026, 6, 1),
                created_by=ALICE, splits=[
                    SplitInput(user_identifier=ALICE, paid_share=Decimal("100"), owed_share=Decimal("50")),
                    SplitInput(user_identifier=BOB, paid_share=Decimal("0"), owed_share=Decimal("50"))]),
                caller=ALICE, session=s)
        assert "expense_added" in await _types(BOB)
        assert "expense_added" not in await _types(ALICE)            # actor excluded
    finally:
        await _purge()


async def _row(owner: str, type: str) -> Notification | None:
    async with async_session() as s:
        return await s.scalar(select(Notification).where(
            Notification.owner_identifier == owner, Notification.type == type))


async def test_notifications_carry_deeplink_entity_ref():
    await _purge(); await _seed_users()
    async with async_session() as s:
        g = Group(name="House", backend_type=BackendType.self_hosted)
        s.add(g); await s.flush()
        s.add_all([GroupMember(group_id=g.id, user_identifier=ALICE),
                   GroupMember(group_id=g.id, user_identifier=BOB)])
        await s.commit(); gid = g.id
    try:
        async with async_session() as s:
            exp = await create_expense(ExpenseCreate(
                group_id=gid, description="Dinner", amount=Decimal("100"), date=date(2026, 6, 1),
                created_by=ALICE, splits=[
                    SplitInput(user_identifier=ALICE, paid_share=Decimal("100"), owed_share=Decimal("50")),
                    SplitInput(user_identifier=BOB, paid_share=Decimal("0"), owed_share=Decimal("50"))]),
                caller=ALICE, session=s)
        row = await _row(BOB, "expense_added")
        assert row is not None and row.entity_type == "expense" and row.entity_id == str(exp.id)
    finally:
        await _purge()


async def test_connection_accept_links_to_friend_and_request_has_none():
    await _purge(); await _seed_users()
    try:
        async with async_session() as s:
            conn = await create_connection(ConnectionCreate(identifier=BOB), caller=ALICE, session=s)
        req = await _row(BOB, "connection_request")
        assert req is not None and req.entity_type is None and req.entity_id is None   # pending → no link
        async with async_session() as s:
            await accept_connection(conn.id, caller=BOB, session=s)
        acc = await _row(ALICE, "connection_accepted")
        assert acc is not None and acc.entity_type == "friend" and acc.entity_id == BOB  # now friends → link
    finally:
        await _purge()


async def test_push_mute_suppresses_push_keeps_feed_row():
    await _purge(); await _seed_users()
    async with async_session() as s:
        g = Group(name="House", backend_type=BackendType.self_hosted)
        s.add(g); await s.flush()
        s.add_all([GroupMember(group_id=g.id, user_identifier=ALICE),
                   GroupMember(group_id=g.id, user_identifier=BOB)])
        s.add(NotificationMute(owner_identifier=BOB, token="push:expense_added"))  # Bob mutes push
        await s.commit(); gid = g.id
    pushed: list = []
    orig = notify_svc.push.enqueue
    notify_svc.push.enqueue = lambda owners, title, body, target=None: pushed.append(set(owners))
    try:
        async with async_session() as s:
            await create_expense(ExpenseCreate(
                group_id=gid, description="Dinner", amount=Decimal("100"), date=date(2026, 6, 1),
                created_by=ALICE, splits=[
                    SplitInput(user_identifier=ALICE, paid_share=Decimal("100"), owed_share=Decimal("50")),
                    SplitInput(user_identifier=BOB, paid_share=Decimal("0"), owed_share=Decimal("50"))]),
                caller=ALICE, session=s)
        assert "expense_added" in await _types(BOB)                  # feed row still written (audit intact)
        assert all(BOB not in owners for owners in pushed)           # but Bob is NOT pushed
    finally:
        notify_svc.push.enqueue = orig
        await _purge()


async def test_notify_rolls_back_on_failure():
    """notify() is best-effort: a DB failure during its inserts must be swallowed + rolled back, never raised,
    so the caller's session stays usable (its own mutation already committed). Force a real failure with a
    `type` longer than the VARCHAR(32) column so the flush errors mid-notify."""
    try:
        async with async_session() as s:
            await notify_svc.notify(s, {ALICE}, type="x" * 64, content="hello",
                                    entity_type="goal", entity_id="g1")   # must NOT raise
            # Session recovered (rollback cleared the failed tx): a fresh write commits fine.
            s.add(Account(name="probe", type="checking", balance=Decimal(0), currency="USD",
                          owner_identifier=ALICE))
            await s.commit()
        async with async_session() as s:
            persisted = len(list(await s.scalars(
                select(Notification).where(Notification.owner_identifier == ALICE))))
        assert persisted == 0   # the failed notify wrote nothing
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
