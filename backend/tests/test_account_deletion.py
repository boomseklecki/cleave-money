"""DELETE /users/{id} removes the user's personal data (accounts/transactions/goals/Splitwise token/
memberships) but RETAINS shared group expenses/splits. Drives the handler directly with an explicit caller.
Runs against the running Postgres; cleans up its own rows.
"""
from datetime import date
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete, func, select

from app.db import async_session
from app.models import (
    Account,
    Expense,
    Goal,
    Group,
    GroupMember,
    Split,
    SplitwiseToken,
    Transaction,
    User,
)
from app.models.enums import BackendType, TransactionSource, UserSource
from app.routers.users import delete_user

ME = "delme-zzz"


async def _cleanup(session) -> None:
    gids = list(await session.scalars(select(Group.id).where(Group.name == "DelGrp ZZZ")))
    if gids:
        await session.execute(delete(Group).where(Group.id.in_(gids)))  # cascades expenses/splits
    await session.execute(delete(Transaction).where(Transaction.owner_identifier == ME))
    await session.execute(delete(Account).where(Account.owner_identifier == ME))
    await session.execute(delete(Goal).where(Goal.owner_identifier == ME))
    await session.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == ME))
    await session.execute(delete(GroupMember).where(GroupMember.user_identifier == ME))
    await session.execute(delete(User).where(User.identifier == ME))
    await session.commit()


async def test_delete_user_purges_personal_keeps_shared():
    async with async_session() as session:
        await _cleanup(session)
        try:
            user = User(identifier=ME, display_name="Del", source=UserSource.app, email="del-zzz@x.com")
            session.add(user)
            await session.flush()
            uid = user.id
            account = Account(name="My Acct", owner_identifier=ME)
            session.add(account)
            await session.flush()
            session.add(Transaction(account_id=account.id, source=TransactionSource.manual,
                                    description="t", amount=Decimal("5"), date=date.today(),
                                    owner_identifier=ME))
            session.add(Goal(kind="spend", name="g", owner_identifier=ME, target_amount=Decimal("10")))
            session.add(SplitwiseToken(user_identifier=ME, access_token="x"))
            group = Group(name="DelGrp ZZZ", backend_type=BackendType.self_hosted)
            session.add(group)
            await session.flush()
            session.add(GroupMember(group_id=group.id, user_identifier=ME))
            session.add(Expense(group_id=group.id, description="shared", amount=Decimal("10"),
                                currency="USD", date=date.today(),
                                splits=[Split(user_identifier=ME, paid_share=Decimal("10"),
                                              owed_share=Decimal("10"))]))
            await session.commit()

            # Cross-account deletion is refused.
            try:
                await delete_user(uid, caller="someone-else", session=session)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403

            await delete_user(uid, caller=ME, session=session)

        finally:
            pass

    async with async_session() as session:
        try:
            # Personal data gone.
            assert await session.get(User, uid) is None
            for model in (Account, Transaction, Goal):
                assert await session.scalar(
                    select(func.count()).select_from(model).where(model.owner_identifier == ME)) == 0
            assert await session.scalar(
                select(func.count()).select_from(SplitwiseToken)
                .where(SplitwiseToken.user_identifier == ME)) == 0
            assert await session.scalar(
                select(func.count()).select_from(GroupMember)
                .where(GroupMember.user_identifier == ME)) == 0
            # Shared expense + split RETAINED (co-owned household history).
            assert await session.scalar(
                select(func.count()).select_from(Split).where(Split.user_identifier == ME)) == 1
        finally:
            await _cleanup(session)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
