"""The transaction response exposes `linked_expense_id` (reverse of expense.transaction_id) so the client can
resolve the linked expense without scanning its local cache; and linking an expense to a transaction requires
the caller to be able to READ that transaction (not just that it exists). DB-backed."""
from datetime import date
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete

from app.db import async_session
from app.models import Account, BackendType, Expense, Group, GroupMember, Split, Transaction
from app.models.enums import TransactionSource
from app.routers.accounts import get_transaction
from app.routers.expenses import link_expense_transaction
from app.schemas.expense import ExpenseTransactionLink

OWNER = "linkexp-alice"
BOB = "linkexp-bob"


async def test_transaction_exposes_linked_expense_id():
    async with async_session() as s:
        acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                       owner_identifier=OWNER)
        s.add(acct)
        await s.flush()
        linked = Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Rent",
                             amount=Decimal("2000.00"), currency="USD", date=date(2026, 6, 1),
                             owner_identifier=OWNER)
        unlinked = Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Coffee",
                               amount=Decimal("5.00"), currency="USD", date=date(2026, 6, 2),
                               owner_identifier=OWNER)
        s.add_all([linked, unlinked])
        grp = Group(name="linkexp-grp", backend_type=BackendType.self_hosted)
        s.add(grp)
        await s.flush()
        s.add(GroupMember(group_id=grp.id, user_identifier=OWNER))
        exp = Expense(group_id=grp.id, transaction_id=linked.id, description="Rent split",
                      amount=Decimal("2000.00"), currency="USD", date=date(2026, 6, 1), category="Rent")
        s.add(exp)
        await s.flush()
        s.add(Split(expense_id=exp.id, user_identifier=OWNER, paid_share=Decimal("2000.00"),
                    owed_share=Decimal("1000.00")))
        await s.commit()
        linked_id, unlinked_id, exp_id, acct_id, grp_id = linked.id, unlinked.id, exp.id, acct.id, grp.id
    try:
        async with async_session() as s:
            t = await get_transaction(linked_id, caller=OWNER, session=s)
            assert t.linked_expense_id == exp_id
        async with async_session() as s:
            t = await get_transaction(unlinked_id, caller=OWNER, session=s)
            assert t.linked_expense_id is None
    finally:
        async with async_session() as s:
            await s.execute(delete(Split).where(Split.expense_id == exp_id))
            await s.execute(delete(Expense).where(Expense.id == exp_id))
            await s.execute(delete(Transaction).where(Transaction.account_id == acct_id))
            await s.execute(delete(GroupMember).where(GroupMember.group_id == grp_id))
            await s.execute(delete(Group).where(Group.id == grp_id))
            await s.execute(delete(Account).where(Account.id == acct_id))
            await s.commit()


async def test_link_requires_readable_transaction():
    """Linking an expense to a transaction requires the caller to be able to read it - a group member can't
    point their expense's FK at another user's private transaction (only 404-on-missing, else 403-on-unreadable;
    a transaction the caller owns links fine)."""
    async with async_session() as s:
        grp = Group(name="linkexp-grp2", backend_type=BackendType.self_hosted)
        s.add(grp)
        await s.flush()
        s.add(GroupMember(group_id=grp.id, user_identifier=OWNER))
        exp = Expense(group_id=grp.id, description="Dinner", amount=Decimal("50.00"), currency="USD",
                      date=date(2026, 6, 1), category="Dining")
        s.add(exp)
        # Alice's own manual transaction (readable) + Bob's private manual transaction (not readable to Alice).
        mine = Transaction(source=TransactionSource.manual, description="Mine", amount=Decimal("50.00"),
                           currency="USD", date=date(2026, 6, 1), owner_identifier=OWNER)
        bobs = Transaction(source=TransactionSource.manual, description="Bob's", amount=Decimal("50.00"),
                           currency="USD", date=date(2026, 6, 1), owner_identifier=BOB)
        s.add_all([exp, mine, bobs])
        await s.commit()
        exp_id, mine_id, bobs_id, grp_id = exp.id, mine.id, bobs.id, grp.id
    try:
        # Linking Bob's unreadable transaction → 403 (exists, but not the caller's to see).
        async with async_session() as s:
            try:
                await link_expense_transaction(exp_id, ExpenseTransactionLink(transaction_id=bobs_id),
                                                caller=OWNER, session=s)
                assert False, "expected 403 linking an unreadable transaction"
            except HTTPException as e:
                assert e.status_code == 403
        # Linking the caller's own transaction → allowed.
        async with async_session() as s:
            result = await link_expense_transaction(exp_id, ExpenseTransactionLink(transaction_id=mine_id),
                                                    caller=OWNER, session=s)
            assert result.transaction_id == mine_id
    finally:
        async with async_session() as s:
            await s.execute(delete(Expense).where(Expense.id == exp_id))
            await s.execute(delete(Transaction).where(Transaction.id.in_([mine_id, bobs_id])))
            await s.execute(delete(GroupMember).where(GroupMember.group_id == grp_id))
            await s.execute(delete(Group).where(Group.id == grp_id))
            await s.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
