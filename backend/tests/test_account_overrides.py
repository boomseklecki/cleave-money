"""Per-(owner, account) overrides: set/clear via PATCH, scoped to the caller. DB-backed."""
import uuid
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete, select

from app.db import async_session
from app.models import Account, AccountOverride
from app.routers.accounts import _attach_account_overrides, update_account
from app.schemas.account import AccountUpdate


async def _make_account(session, owner: str) -> uuid.UUID:
    account = Account(name="Everyday Checking", type="checking", balance=Decimal(100), currency="USD",
                      owner_identifier=owner)
    session.add(account)
    await session.commit()
    return account.id


async def _cleanup(session, account_id):
    await session.execute(delete(AccountOverride).where(AccountOverride.account_id == account_id))
    await session.execute(delete(Account).where(Account.id == account_id))
    await session.commit()


async def _loaded(session, account_id, caller):
    account = await session.get(Account, account_id)
    await _attach_account_overrides(session, caller, [account])
    return account


async def test_set_clear_and_validate():
    async with async_session() as s:
        account_id = await _make_account(s, "alice")
        try:
            await update_account(account_id, AccountUpdate(display_name="Joint Checking", kind="cash_flow",
                                                           include_in_spending=True), caller="alice", session=s)
            a = await _loaded(s, account_id, "alice")
            assert (a.display_name, a.kind, a.include_in_spending) == ("Joint Checking", "cash_flow", True)
            # exclude_unset: toggling one flag leaves the others.
            await update_account(account_id, AccountUpdate(include_in_cash_flow=False), caller="alice", session=s)
            a = await _loaded(s, account_id, "alice")
            assert a.display_name == "Joint Checking" and a.include_in_cash_flow is False
            # Empty display_name resets to null.
            await update_account(account_id, AccountUpdate(display_name=""), caller="alice", session=s)
            assert (await _loaded(s, account_id, "alice")).display_name is None
            # Unknown kind → 422.
            try:
                await update_account(account_id, AccountUpdate(kind="bogus"), caller="alice", session=s)
                assert False, "expected 422"
            except HTTPException as e:
                assert e.status_code == 422
            # Clearing every override deletes the row (display_name already null above).
            await update_account(account_id, AccountUpdate(kind=None, include_in_spending=None,
                                                           include_in_cash_flow=None), caller="alice", session=s)
            assert (await s.scalar(select(AccountOverride).where(
                AccountOverride.account_id == account_id))) is None
        finally:
            await _cleanup(s, account_id)


async def test_scoped_per_owner():
    async with async_session() as s:
        account_id = await _make_account(s, "alice")
        try:
            await update_account(account_id, AccountUpdate(display_name="Alice's"), caller="alice", session=s)
            # Bob sees no override on the same account row.
            assert (await _loaded(s, account_id, "bob")).display_name is None
            assert (await _loaded(s, account_id, "alice")).display_name == "Alice's"
        finally:
            await _cleanup(s, account_id)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
