"""Per-caller data scoping: lists return only the caller's rows; cross-caller writes 403; create stamps
the owner; a group's creator is auto-joined so they see it. Drives the router handlers directly with an
explicit `caller` (no HTTP/auth plumbing). Runs against the running Postgres; cleans up its own rows.
"""
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete, select

from app.auth.access import is_admin
from app.config import settings
from app.db import async_session
from app.models import Account, Friend, Goal, Group, GroupMember, User
from app.models.enums import BackendType, UserSource
from app.routers import accounts as acct
from app.routers import goals as goals_router
from app.routers import groups as groups_router
from app.routers import users as users_router
from app.schemas.account import AccountCreate
from app.schemas.goal import GoalCreate, GoalUpdate
from app.schemas.group import GroupCreate

A = "scope-a-zzz"
B = "scope-b-zzz"


async def _cleanup(session) -> None:
    gids = list(await session.scalars(select(Group.id).where(Group.name == "Scope Group ZZZ")))
    if gids:
        await session.execute(delete(GroupMember).where(GroupMember.group_id.in_(gids)))
        await session.execute(delete(Group).where(Group.id.in_(gids)))
    await session.execute(delete(Goal).where(Goal.owner_identifier.in_([A, B])))
    await session.execute(delete(Account).where(Account.owner_identifier.in_([A, B])))
    await session.commit()


async def test_goal_scoping():
    async with async_session() as session:
        await _cleanup(session)
        try:
            goal = await goals_router.create_goal(
                GoalCreate(kind="spend", name="ZZZ", target_amount=Decimal("100")),
                caller=A, session=session)
            assert goal.owner_identifier == A

            mine = await goals_router.list_goals(caller=A, session=session)
            theirs = await goals_router.list_goals(caller=B, session=session)
            assert goal.id in [g.id for g in mine]
            assert goal.id not in [g.id for g in theirs]

            try:
                await goals_router.update_goal(goal.id, GoalUpdate(name="hijack"),
                                               caller=B, session=session)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403
        finally:
            await _cleanup(session)


async def test_account_scoping():
    async with async_session() as session:
        await _cleanup(session)
        try:
            account = await acct.create_account(AccountCreate(name="ZZZ Acct"), caller=A, session=session)
            assert account.owner_identifier == A
            mine = await acct.list_accounts(caller=A, session=session)
            theirs = await acct.list_accounts(caller=B, session=session)
            assert account.id in [x.id for x in mine] and account.id not in [x.id for x in theirs]
            try:
                await acct.delete_account(account.id, caller=B, session=session)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403
        finally:
            await _cleanup(session)


async def test_group_membership_scoping():
    async with async_session() as session:
        await _cleanup(session)
        try:
            group = await groups_router.create_group(GroupCreate(name="Scope Group ZZZ"),
                                                     caller=A, session=session)
            # Creator is auto-joined -> sees it; B is not a member -> doesn't, and is 403 on access.
            mine = await groups_router.list_groups(caller=A, session=session)
            theirs = await groups_router.list_groups(caller=B, session=session)
            assert group.id in [g.id for g in mine] and group.id not in [g.id for g in theirs]
            try:
                await groups_router.get_group(group.id, caller=B, session=session)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403
            # Open mode (caller=None) is unscoped - sees everything.
            assert group.id in [g.id for g in await groups_router.list_groups(caller=None, session=session)]
        finally:
            await _cleanup(session)


DIR = ["dir-a-zzz", "dir-b-zzz", "dir-c-zzz"]


async def _cleanup_dir(session) -> None:
    gids = list(await session.scalars(select(Group.id).where(Group.name == "Dir Grp ZZZ")))
    if gids:
        await session.execute(delete(GroupMember).where(GroupMember.group_id.in_(gids)))
        await session.execute(delete(Group).where(Group.id.in_(gids)))
    await session.execute(delete(User).where(User.identifier.in_(DIR)))
    await session.commit()


async def test_users_directory_scopes_contact_to_co_members_and_admin():
    saved_admin = settings.admin_users
    async with async_session() as session:
        await _cleanup_dir(session)
        try:
            for ident in DIR:
                session.add(User(identifier=ident, display_name=ident.upper(),
                                 source=UserSource.app, email=f"{ident}@x.com"))
            group = Group(name="Dir Grp ZZZ", backend_type=BackendType.self_hosted)
            session.add(group)
            await session.flush()
            session.add(GroupMember(group_id=group.id, user_identifier="dir-a-zzz"))
            session.add(GroupMember(group_id=group.id, user_identifier="dir-b-zzz"))
            await session.commit()

            # As A: own + co-member (B) keep email; the unrelated C is nulled.
            settings.admin_users = []
            rows = await users_router.list_users(caller="dir-a-zzz", session=session)
            byid = {u.identifier: u for u in rows if u.identifier in DIR}
            assert byid["dir-a-zzz"].email == "dir-a-zzz@x.com"
            assert byid["dir-b-zzz"].email == "dir-b-zzz@x.com"
            assert byid["dir-c-zzz"].email is None
            assert byid["dir-c-zzz"].splitwise_user_id is None

            # As an admin: everyone's contact details are visible.
            settings.admin_users = ["dir-a-zzz"]
            assert is_admin("dir-a-zzz") and not is_admin("dir-b-zzz")
            rows = await users_router.list_users(caller="dir-a-zzz", session=session)
            byid = {u.identifier: u for u in rows if u.identifier in DIR}
            assert byid["dir-c-zzz"].email == "dir-c-zzz@x.com"
        finally:
            settings.admin_users = saved_admin
            await _cleanup_dir(session)


USC = ["usc-a-zzz", "usc-b-zzz", "usc-afriend-zzz", "usc-bcontact-zzz"]


async def _cleanup_usc(session) -> None:
    await session.execute(delete(Friend).where(Friend.owner_identifier.in_(["usc-a-zzz", "usc-b-zzz"])))
    await session.execute(delete(User).where(User.identifier.in_(USC)))
    await session.commit()


async def test_users_directory_excludes_others_splitwise_contacts():
    """The browsable directory = local logins + your own Splitwise friends/partners/co-members. It must NOT
    leak *another* person's Splitwise-only contacts. `?source=app` is the admin local-users view."""
    async with async_session() as session:
        await _cleanup_usc(session)
        try:
            session.add_all([
                User(identifier="usc-a-zzz", display_name="A", source=UserSource.app),
                User(identifier="usc-b-zzz", display_name="B", source=UserSource.app),
                User(identifier="usc-afriend-zzz", display_name="A Friend", source=UserSource.splitwise),
                User(identifier="usc-bcontact-zzz", display_name="B Contact", source=UserSource.splitwise),
            ])
            # A's Splitwise friend resolves to usc-afriend-zzz; B's contact resolves to usc-bcontact-zzz.
            session.add(Friend(owner_identifier="usc-a-zzz", splitwise_friend_id="fa",
                               identifier="usc-afriend-zzz"))
            session.add(Friend(owner_identifier="usc-b-zzz", splitwise_friend_id="cb",
                               identifier="usc-bcontact-zzz"))
            await session.commit()

            seen = {u.identifier for u in await users_router.list_users(caller="usc-a-zzz", session=session)}
            # A sees local logins (A, B) + A's own Splitwise friend, NOT B's Splitwise-only contact.
            assert {"usc-a-zzz", "usc-b-zzz", "usc-afriend-zzz"} <= seen
            assert "usc-bcontact-zzz" not in seen

            # The admin "Local Users" view (?source=app) is only local logins.
            locals_ = {u.identifier for u in await users_router.list_users(
                source=UserSource.app, caller="usc-a-zzz", session=session)}
            assert {"usc-a-zzz", "usc-b-zzz"} <= locals_
            assert "usc-afriend-zzz" not in locals_ and "usc-bcontact-zzz" not in locals_
        finally:
            await _cleanup_usc(session)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
