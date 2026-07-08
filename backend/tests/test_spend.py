"""Phase 4: server-side spend-by-category (solo) + the budget-nearing/over push hook. Covers the resolver/
include-flag/linked-expense-dedup paths, the status thresholds, and once-per-(goal,month,kind) firing gated by
`budget_push_enabled`. DB-backed (calls the service fns directly)."""
import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

from sqlalchemy import delete, select

from app import server_settings
from app.db import async_session
from app.models import (
    Account, AccountOverride, BackendType, Connection, Expense, ExpenseItem, ExpenseOverride, Goal,
    GoalBudgetNotification, Group, GroupMember, GroupOverride, Notification, Split, Transaction,
    TransactionItem, TransactionOverride,
)
from app.models.enums import ConnectionStatus, TransactionSource
from app.services import spend as spend_svc

OWNER = "spend-alice"
OTHER = "spend-bob"
_MONTH = date.today().replace(day=1)


def _mid_month() -> date:
    return _MONTH.replace(day=15)


async def _cleanup():
    async with async_session() as s:
        await s.execute(delete(GoalBudgetNotification).where(
            GoalBudgetNotification.owner_identifier == OWNER))
        await s.execute(delete(Notification).where(Notification.owner_identifier.in_([OWNER, OTHER])))
        await s.execute(delete(Goal).where(Goal.owner_identifier == OWNER))
        await s.execute(delete(TransactionOverride).where(TransactionOverride.owner_identifier == OWNER))
        await s.execute(delete(AccountOverride).where(AccountOverride.owner_identifier == OWNER))
        await s.execute(delete(ExpenseOverride).where(ExpenseOverride.owner_identifier == OWNER))
        await s.execute(delete(GroupOverride).where(GroupOverride.owner_identifier == OWNER))
        await s.execute(delete(Transaction).where(Transaction.owner_identifier.in_([OWNER, OTHER])))
        await s.execute(delete(Account).where(Account.owner_identifier == OWNER))
        await s.execute(delete(Connection).where(
            Connection.requester_identifier.in_([OWNER, OTHER])))
        # expenses/splits/groups cascade from the group
        gids = list(await s.scalars(select(Group.id).where(Group.name.like("spend-grp%"))))
        for gid in gids:
            await s.execute(delete(Group).where(Group.id == gid))
        await s.commit()


def test_budget_status_thresholds():
    assert spend_svc.budget_status(Decimal("90"), Decimal("100")) == "nearing"   # 90%
    assert spend_svc.budget_status(Decimal("84"), Decimal("100")) == "under"      # <85%
    assert spend_svc.budget_status(Decimal("120"), Decimal("100")) == "over"      # >100%
    assert spend_svc.budget_status(Decimal("0"), Decimal("0")) == "under"


async def test_spend_by_category_solo_and_account_default():
    await _cleanup()
    try:
        async with async_session() as s:
            acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                           owner_identifier=OWNER)
            s.add(acct)
            await s.flush()
            # FOOD_AND_DRINK → Dining (deterministic); a credit-card (liability) counts too.
            s.add(Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Dinner",
                              amount=Decimal("40.00"), currency="USD", date=_mid_month(),
                              category="FOOD_AND_DRINK", owner_identifier=OWNER))
            s.add(Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Lunch",
                              amount=Decimal("10.00"), currency="USD", date=_mid_month(),
                              category="FOOD_AND_DRINK_GROCERIES", owner_identifier=OWNER))
            # An income row (negative-ish category) is excluded from spend.
            s.add(Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Pay",
                              amount=Decimal("500.00"), currency="USD", date=_mid_month(),
                              category="INCOME", owner_identifier=OWNER))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.spend_by_category(s, OWNER, _MONTH)
        assert totals.get("Dining") == Decimal("40.00")
        assert totals.get("Groceries") == Decimal("10.00")
        assert "Income" not in totals
    finally:
        await _cleanup()


# --- Itemized attribution: same fixtures + numbers as ios ItemizedSpendTests (cross-language golden parity) ---

async def test_itemized_expense_honors_owners():
    await _cleanup()
    try:
        async with async_session() as s:
            grp = Group(name="spend-grp-item", backend_type=BackendType.self_hosted)
            s.add(grp)
            await s.flush()
            e = Expense(group_id=grp.id, description="Costco", amount=Decimal("100.00"), currency="USD",
                        date=_mid_month(), category="Groceries")
            s.add(e)
            await s.flush()
            s.add(Split(expense_id=e.id, user_identifier=OWNER, paid_share=Decimal("100.00"),
                        owed_share=Decimal("60.00")))
            s.add(ExpenseItem(expense_id=e.id, name="Food", price=Decimal("50.00"), category="Groceries",
                              owner_identifier=OWNER))
            s.add(ExpenseItem(expense_id=e.id, name="Takeout", price=Decimal("30.00"), category="Dining"))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.spend_by_category(s, OWNER, _MONTH)
        # mine Groceries 50 + remainder 10*(20/50)=4 → 54 ; Dining 10*(30/50)=6 ; sum == owed 60
        assert abs(totals.get("Groceries", Decimal(0)) - Decimal("54")) < Decimal("0.01")
        assert abs(totals.get("Dining", Decimal(0)) - Decimal("6")) < Decimal("0.01")
        assert abs(sum(totals.values(), Decimal(0)) - Decimal("60")) < Decimal("0.01")
    finally:
        await _cleanup()


async def test_itemized_splitwise_expense_ignores_owners():
    await _cleanup()
    try:
        async with async_session() as s:
            grp = Group(name="spend-grp-item", backend_type=BackendType.splitwise)
            s.add(grp)
            await s.flush()
            e = Expense(group_id=grp.id, description="Costco", amount=Decimal("100.00"), currency="USD",
                        date=_mid_month(), category="Groceries", splitwise_expense_id="sw-item-1")
            s.add(e)
            await s.flush()
            s.add(Split(expense_id=e.id, user_identifier=OWNER, paid_share=Decimal("100.00"),
                        owed_share=Decimal("60.00")))
            s.add(ExpenseItem(expense_id=e.id, name="Food", price=Decimal("50.00"), category="Groceries",
                              owner_identifier=OWNER))  # owner ignored for a Splitwise expense
            s.add(ExpenseItem(expense_id=e.id, name="Takeout", price=Decimal("30.00"), category="Dining"))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.spend_by_category(s, OWNER, _MONTH)
        # all shared: Groceries 60*(50/100)=30 + remainder 60*(20/100)=12 → 42 ; Dining 60*(30/100)=18
        assert abs(totals.get("Groceries", Decimal(0)) - Decimal("42")) < Decimal("0.01")
        assert abs(totals.get("Dining", Decimal(0)) - Decimal("18")) < Decimal("0.01")
    finally:
        await _cleanup()


async def test_itemized_transaction():
    await _cleanup()
    try:
        async with async_session() as s:
            acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                           owner_identifier=OWNER)
            s.add(acct)
            await s.flush()
            t = Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Target",
                            amount=Decimal("100.00"), currency="USD", date=_mid_month(),
                            category="FOOD_AND_DRINK", owner_identifier=OWNER)  # effective → Dining
            s.add(t)
            await s.flush()
            s.add(TransactionItem(transaction_id=t.id, name="Groceries", price=Decimal("30.00"),
                                  category="Groceries"))
            s.add(TransactionItem(transaction_id=t.id, name="Snack", price=Decimal("20.00"), category=None))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.spend_by_category(s, OWNER, _MONTH)
        # Groceries item 30 ; nil-cat item 20 + remainder (100-50=50) → effective Dining 70 ; sum == 100
        assert totals.get("Groceries") == Decimal("30.00")
        assert abs(totals.get("Dining", Decimal(0)) - Decimal("70")) < Decimal("0.01")
        assert abs(sum(totals.values(), Decimal(0)) - Decimal("100")) < Decimal("0.01")
    finally:
        await _cleanup()


async def test_itemized_excluded_item_dropped():
    await _cleanup()
    try:
        async with async_session() as s:
            acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                           owner_identifier=OWNER)
            s.add(acct)
            await s.flush()
            t = Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Mixed",
                            amount=Decimal("100.00"), currency="USD", date=_mid_month(),
                            category="FOOD_AND_DRINK", owner_identifier=OWNER)
            s.add(t)
            await s.flush()
            s.add(TransactionItem(transaction_id=t.id, name="Dinner", price=Decimal("60.00"),
                                  category="Dining"))
            s.add(TransactionItem(transaction_id=t.id, name="Cash back", price=Decimal("40.00"),
                                  category="Transfer"))  # excluded → dropped (sums to 100, no remainder)
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.spend_by_category(s, OWNER, _MONTH)
        assert totals.get("Dining") == Decimal("60.00")
        assert "Transfer" not in totals
    finally:
        await _cleanup()


# --- Household (shared) budgets: same fixtures + numbers as ios HouseholdBudgetTests (golden parity) ---

async def _make_household(s) -> uuid.UUID:
    """Accepted OWNER<->OTHER connection + a self-hosted group both belong to. Returns the shared group id."""
    s.add(Connection(requester_identifier=OWNER, addressee_identifier=OTHER, status=ConnectionStatus.accepted))
    grp = Group(name="spend-grp-hh", backend_type=BackendType.self_hosted)
    s.add(grp)
    await s.flush()
    s.add(GroupMember(group_id=grp.id, user_identifier=OWNER))
    s.add(GroupMember(group_id=grp.id, user_identifier=OTHER))
    return grp.id


def _split(e_id, who, owed, paid=Decimal("0.00")) -> Split:
    return Split(expense_id=e_id, user_identifier=who, paid_share=paid, owed_share=owed)


async def test_household_split_expense_combines():
    await _cleanup()
    try:
        async with async_session() as s:
            gid = await _make_household(s)
            e = Expense(group_id=gid, description="Dinner", amount=Decimal("100.00"), currency="USD",
                        date=_mid_month(), category="Dining")
            s.add(e)
            await s.flush()
            s.add(_split(e.id, OWNER, Decimal("50.00"), Decimal("100.00")))
            s.add(_split(e.id, OTHER, Decimal("50.00")))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.household_spend_by_category(s, OWNER, {OTHER}, {gid}, _MONTH)
        assert totals.get("Dining") == Decimal("100.00")  # 50 mine + 50 partner
    finally:
        await _cleanup()


async def test_household_itemized_per_owner():
    await _cleanup()
    try:
        async with async_session() as s:
            gid = await _make_household(s)
            e = Expense(group_id=gid, description="Store", amount=Decimal("50.00"), currency="USD",
                        date=_mid_month(), category="Groceries")
            s.add(e)
            await s.flush()
            s.add(_split(e.id, OWNER, Decimal("20.00"), Decimal("50.00")))
            s.add(_split(e.id, OTHER, Decimal("30.00")))
            s.add(ExpenseItem(expense_id=e.id, name="Wine", price=Decimal("20.00"), category="Dining",
                              owner_identifier=OWNER))
            s.add(ExpenseItem(expense_id=e.id, name="Veg", price=Decimal("30.00"), category="Groceries",
                              owner_identifier=OTHER))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.household_spend_by_category(s, OWNER, {OTHER}, {gid}, _MONTH)
        assert totals.get("Dining") == Decimal("20.00")     # OWNER's wine
        assert totals.get("Groceries") == Decimal("30.00")  # OTHER's veg
    finally:
        await _cleanup()


async def test_household_splitwise_canonicalization():
    await _cleanup()
    try:
        async with async_session() as s:
            gid = await _make_household(s)
            e = Expense(group_id=gid, description="Dinner", amount=Decimal("100.00"), currency="USD",
                        date=_mid_month(), category="Dining out", splitwise_expense_id="sw-hh")
            s.add(e)
            await s.flush()
            s.add(_split(e.id, OWNER, Decimal("50.00"), Decimal("100.00")))
            s.add(_split(e.id, OTHER, Decimal("50.00")))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.household_spend_by_category(s, OWNER, {OTHER}, {gid}, _MONTH)
        assert totals.get("Dining") == Decimal("100.00")  # canonical
        assert "Dining out" not in totals                 # the raw label is never the bucket
    finally:
        await _cleanup()


async def test_household_non_shared_group_excluded():
    await _cleanup()
    try:
        async with async_session() as s:
            s.add(Connection(requester_identifier=OWNER, addressee_identifier=OTHER,
                             status=ConnectionStatus.accepted))
            grp = Group(name="spend-grp-hh", backend_type=BackendType.self_hosted)
            s.add(grp)
            await s.flush()
            s.add(GroupMember(group_id=grp.id, user_identifier=OWNER))  # OTHER is NOT a member
            e = Expense(group_id=grp.id, description="Solo", amount=Decimal("100.00"), currency="USD",
                        date=_mid_month(), category="Dining")
            s.add(e)
            await s.flush()
            s.add(_split(e.id, OWNER, Decimal("100.00"), Decimal("100.00")))
            await s.commit()
        async with async_session() as s:
            partners, shared = await spend_svc._household(s, OWNER)
            assert partners == {OTHER}
            assert shared == set()  # the group isn't shared (OTHER isn't a member)
            totals = await spend_svc.household_spend_by_category(s, OWNER, partners, shared, _MONTH)
        assert totals == {}
    finally:
        await _cleanup()


async def test_household_linked_transaction_counts_once():
    await _cleanup()
    try:
        async with async_session() as s:
            gid = await _make_household(s)
            acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                           owner_identifier=OWNER)
            s.add(acct)
            await s.flush()
            t = Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Grocery",
                            amount=Decimal("80.00"), currency="USD", date=_mid_month(),
                            category="FOOD_AND_DRINK_GROCERIES", owner_identifier=OWNER)
            s.add(t)
            await s.flush()
            e = Expense(group_id=gid, transaction_id=t.id, description="Grocery", amount=Decimal("80.00"),
                        currency="USD", date=_mid_month(), category="Groceries")
            s.add(e)
            await s.flush()
            s.add(_split(e.id, OWNER, Decimal("40.00"), Decimal("80.00")))
            s.add(_split(e.id, OTHER, Decimal("40.00")))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.household_spend_by_category(s, OWNER, {OTHER}, {gid}, _MONTH)
        assert totals.get("Groceries") == Decimal("80.00")  # once via the expense; the linked txn never enters
    finally:
        await _cleanup()


async def test_household_month_scoping():
    await _cleanup()
    try:
        last_month = _MONTH - timedelta(days=15)  # mid previous month
        async with async_session() as s:
            gid = await _make_household(s)
            e = Expense(group_id=gid, description="Old", amount=Decimal("100.00"), currency="USD",
                        date=last_month, category="Dining")
            s.add(e)
            await s.flush()
            s.add(_split(e.id, OWNER, Decimal("50.00"), Decimal("100.00")))
            s.add(_split(e.id, OTHER, Decimal("50.00")))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.household_spend_by_category(s, OWNER, {OTHER}, {gid}, _MONTH)
        assert "Dining" not in totals  # last month's expense isn't in this month
    finally:
        await _cleanup()


async def test_household_budget_push_notifies_both_partners():
    await _cleanup()
    async with async_session() as s:
        original = await server_settings.get(s, "budget_push_enabled")
    try:
        async with async_session() as s:
            gid = await _make_household(s)
            s.add(Goal(kind="spend", name="Groceries", owner_identifier=OWNER, category="Groceries",
                       target_amount=Decimal("100.00"), shared=True))
            e = Expense(group_id=gid, description="Costco", amount=Decimal("90.00"), currency="USD",
                        date=_mid_month(), category="Groceries")
            s.add(e)
            await s.flush()
            s.add(_split(e.id, OWNER, Decimal("45.00"), Decimal("90.00")))
            s.add(_split(e.id, OTHER, Decimal("45.00")))
            await server_settings.set_value(s, "budget_push_enabled", True)
            await s.commit()
        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})  # combined 90 ≥ 85% of 100 → nearing
        async with async_session() as s:
            notes = list(await s.scalars(select(Notification).where(
                Notification.owner_identifier.in_([OWNER, OTHER]), Notification.type == "budget_nearing")))
        assert {n.owner_identifier for n in notes} == {OWNER, OTHER}  # both partners alerted, one household budget
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "budget_push_enabled", original)
            await s.commit()
        await _cleanup()


async def test_linked_expense_dedup():
    await _cleanup()
    try:
        async with async_session() as s:
            acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                           owner_identifier=OWNER)
            s.add(acct)
            await s.flush()
            txn = Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Rent",
                              amount=Decimal("2000.00"), currency="USD", date=_mid_month(),
                              category="RENT_AND_UTILITIES_RENT", owner_identifier=OWNER)
            s.add(txn)
            grp = Group(name="spend-grp-1", backend_type=BackendType.self_hosted)
            s.add(grp)
            await s.flush()
            s.add(GroupMember(group_id=grp.id, user_identifier=OWNER))
            exp = Expense(group_id=grp.id, transaction_id=txn.id, description="Rent split",
                          amount=Decimal("2000.00"), currency="USD", date=_mid_month(), category="Rent")
            s.add(exp)
            await s.flush()
            s.add(Split(expense_id=exp.id, user_identifier=OWNER, paid_share=Decimal("2000.00"),
                        owed_share=Decimal("1000.00")))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.spend_by_category(s, OWNER, _MONTH)
        # The $2000 gross transaction is dropped in favor of the $1000 owed share - not $3000.
        assert totals.get("Rent") == Decimal("1000.00")
    finally:
        await _cleanup()


async def _seed_goal_and_spend(target: Decimal, txn_amount: Decimal):
    async with async_session() as s:
        acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                       owner_identifier=OWNER)
        s.add(acct)
        await s.flush()
        s.add(Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Dinner",
                          amount=txn_amount, currency="USD", date=_mid_month(),
                          category="FOOD_AND_DRINK", owner_identifier=OWNER))
        s.add(Goal(kind="spend", name="Dining budget", owner_identifier=OWNER, category="Dining",
                   target_amount=target))
        await s.commit()


async def test_budget_push_once_per_month_and_escalates():
    await _cleanup()
    try:
        async with async_session() as s:
            await server_settings.set_value(s, "budget_push_enabled", True)
            await s.commit()
        await _seed_goal_and_spend(target=Decimal("100"), txn_amount=Decimal("90"))  # 90% → nearing

        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})
        async with async_session() as s:
            notifs = list(await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER)))
            markers = list(await s.scalars(select(GoalBudgetNotification).where(
                GoalBudgetNotification.owner_identifier == OWNER)))
        assert [n.type for n in notifs] == ["budget_nearing"]
        assert notifs[0].entity_type == "goal"
        assert {m.kind for m in markers} == {"nearing"}

        # Re-running the same month does not duplicate (marker present).
        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})
        async with async_session() as s:
            n = len(list(await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER))))
        assert n == 1  # still just the one nearing push

        # Crossing 100% fires a distinct "over" push (new kind), still once.
        async with async_session() as s:
            acct_id = await s.scalar(select(Account.id).where(Account.owner_identifier == OWNER))
            s.add(Transaction(account_id=acct_id, source=TransactionSource.plaid, description="More",
                              amount=Decimal("30.00"), currency="USD", date=_mid_month(),
                              category="FOOD_AND_DRINK", owner_identifier=OWNER))  # 120 > 100
            await s.commit()
        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})
        async with async_session() as s:
            kinds = sorted(m.kind for m in await s.scalars(select(GoalBudgetNotification).where(
                GoalBudgetNotification.owner_identifier == OWNER)))
            types = sorted(n.type for n in await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER)))
        assert kinds == ["nearing", "over"]
        assert types == ["budget_nearing", "budget_over"]
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "budget_push_enabled", False)
            await s.commit()
        await _cleanup()


async def test_budget_push_gated_off_by_default():
    await _cleanup()
    try:
        await _seed_goal_and_spend(target=Decimal("100"), txn_amount=Decimal("95"))
        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})  # flag default off
        async with async_session() as s:
            n = len(list(await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER))))
        assert n == 0
    finally:
        await _cleanup()


async def test_evaluate_budget_push_isolated_from_errors():
    """The post-sync budget hook must never break the sync: if spend computation blows up, evaluate_budget_push
    swallows it (rolls back, returns) and writes nothing."""
    await _cleanup()
    original = spend_svc.spend_by_category
    try:
        async with async_session() as s:
            await server_settings.set_value(s, "budget_push_enabled", True)
            await s.commit()
        await _seed_goal_and_spend(target=Decimal("100"), txn_amount=Decimal("90"))  # would be "nearing"

        async def boom(*args, **kwargs):
            raise RuntimeError("spend blew up")
        spend_svc.spend_by_category = boom

        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})   # must NOT raise

        async with async_session() as s:
            notifs = len(list(await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER))))
            markers = len(list(await s.scalars(select(GoalBudgetNotification).where(
                GoalBudgetNotification.owner_identifier == OWNER))))
        assert notifs == 0 and markers == 0   # error isolated, nothing written
    finally:
        spend_svc.spend_by_category = original
        async with async_session() as s:
            await server_settings.set_value(s, "budget_push_enabled", False)
            await s.commit()
        await _cleanup()


async def test_transaction_include_precedence():
    """Transaction include: per-transaction override > account override > account-kind default."""
    await _cleanup()
    try:
        async with async_session() as s:
            acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                           owner_identifier=OWNER)
            s.add(acct)
            await s.flush()
            s.add(Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Dinner",
                              amount=Decimal("50.00"), currency="USD", date=_mid_month(),
                              category="FOOD_AND_DRINK", owner_identifier=OWNER))
            await s.commit()
            acct_id = acct.id
            txn_id = (await s.scalars(select(Transaction.id).where(
                Transaction.owner_identifier == OWNER))).first()

        async def dining():
            async with async_session() as s:
                return (await spend_svc.spend_by_category(s, OWNER, _MONTH)).get("Dining")

        assert await dining() == Decimal("50.00")                       # cash-flow account → included
        async with async_session() as s:
            s.add(AccountOverride(owner_identifier=OWNER, account_id=acct_id, include_in_spending=False))
            await s.commit()
        assert await dining() is None                                    # account override excludes
        async with async_session() as s:
            s.add(TransactionOverride(owner_identifier=OWNER, transaction_id=txn_id, include_in_spending=True))
            await s.commit()
        assert await dining() == Decimal("50.00")                        # per-txn override wins
    finally:
        await _cleanup()


async def test_account_kind_default_inclusion():
    """With no overrides, holdings/savings accounts are excluded by default; liability (credit) is included."""
    await _cleanup()
    try:
        async with async_session() as s:
            savings = Account(name="Brokerage", type="investment", balance=Decimal(0), currency="USD",
                              owner_identifier=OWNER)
            credit = Account(name="Card", type="credit card", balance=Decimal(0), currency="USD",
                             owner_identifier=OWNER)
            s.add_all([savings, credit])
            await s.flush()
            s.add(Transaction(account_id=savings.id, source=TransactionSource.plaid, description="a",
                              amount=Decimal("30.00"), currency="USD", date=_mid_month(),
                              category="FOOD_AND_DRINK", owner_identifier=OWNER))
            s.add(Transaction(account_id=credit.id, source=TransactionSource.plaid, description="b",
                              amount=Decimal("20.00"), currency="USD", date=_mid_month(),
                              category="FOOD_AND_DRINK", owner_identifier=OWNER))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.spend_by_category(s, OWNER, _MONTH)
        assert totals.get("Dining") == Decimal("20.00")   # only the credit-card outflow; holdings excluded
    finally:
        await _cleanup()


async def test_expense_include_precedence():
    """Expense include: expense override > group override > default(True)."""
    await _cleanup()
    try:
        async with async_session() as s:
            grp = Group(name="spend-grp-inc", backend_type=BackendType.self_hosted)
            s.add(grp)
            await s.flush()
            s.add(GroupMember(group_id=grp.id, user_identifier=OWNER))
            exp = Expense(group_id=grp.id, description="Rent", amount=Decimal("100.00"), currency="USD",
                          date=_mid_month(), category="Rent")
            s.add(exp)
            await s.flush()
            s.add(Split(expense_id=exp.id, user_identifier=OWNER, paid_share=Decimal("100.00"),
                        owed_share=Decimal("60.00")))
            await s.commit()
            grp_id, exp_id = grp.id, exp.id

        async def rent():
            async with async_session() as s:
                return (await spend_svc.spend_by_category(s, OWNER, _MONTH)).get("Rent")

        assert await rent() == Decimal("60.00")                          # default included at owed share
        async with async_session() as s:
            s.add(GroupOverride(owner_identifier=OWNER, group_id=grp_id, include_in_spending=False))
            await s.commit()
        assert await rent() is None                                      # group override excludes
        async with async_session() as s:
            s.add(ExpenseOverride(owner_identifier=OWNER, expense_id=exp_id, include_in_spending=True))
            await s.commit()
        assert await rent() == Decimal("60.00")                          # expense override beats group
    finally:
        await _cleanup()


async def test_superseded_group_excluded_from_spend():
    """A Splitwise group cloned to self-hosted via import-local is marked superseded but keeps its expenses;
    they must NOT count toward spend (else the budget push double-counts source + clone). Audit Medium #11."""
    await _cleanup()
    try:
        async with async_session() as s:
            grp = Group(name="spend-grp-superseded", backend_type=BackendType.self_hosted)
            s.add(grp)
            await s.flush()
            e = Expense(group_id=grp.id, description="Rent", amount=Decimal("100.00"), currency="USD",
                        date=_mid_month(), category="Rent")
            s.add(e)
            await s.flush()
            s.add(Split(expense_id=e.id, user_identifier=OWNER, paid_share=Decimal("100.00"),
                        owed_share=Decimal("60.00")))
            await s.commit()
            gid = grp.id
        async with async_session() as s:  # counts while the group is live
            assert (await spend_svc.spend_by_category(s, OWNER, _MONTH)).get("Rent") == Decimal("60.00")
        async with async_session() as s:
            g = await s.get(Group, gid)
            g.superseded_at = datetime.now(timezone.utc)
            await s.commit()
        async with async_session() as s:  # excluded once superseded
            assert "Rent" not in await spend_svc.spend_by_category(s, OWNER, _MONTH)
    finally:
        await _cleanup()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
