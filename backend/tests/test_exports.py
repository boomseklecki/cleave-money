"""Tests for the user-facing data export (CSV / JSON / OFX / ZIP).

Pure-format tests build lightweight stand-ins (no DB); the integration test seeds a
group, expense, splits, account and transactions, then exercises the scoped
fetchers, JSON serialization, the OFX round-trip, and the ZIP archive.
"""
import io
import json
import zipfile
from datetime import UTC, date, datetime
from decimal import Decimal
from types import SimpleNamespace
from uuid import uuid4

from app.db import async_session
from app.integrations.export import archive, csv_writer, json_writer, ofx_writer, queries
from app.integrations.statements import ofx as ofx_reader
from app.models import Account, Expense, Group, GroupMember, Split, Transaction
from app.models.enums import BackendType, ShareLevel, TransactionSource

CALLER = "export-alice"
OTHER = "export-bob"


# --- pure format tests (no DB) -------------------------------------------------

def _fake_expense():
    return SimpleNamespace(
        id=uuid4(), group_id=uuid4(), date=date(2026, 7, 1), description="Dinner, drinks & more",
        amount=Decimal("60.00"), currency="USD", category="Food", notes=None, note="mine",
        created_by=CALLER, updated_by=None, splitwise_expense_id=None, transaction_id=None,
        created_at=datetime(2026, 7, 1, 12, 0, tzinfo=UTC), updated_at=datetime(2026, 7, 1, 12, 0, tzinfo=UTC),
        splits=[
            SimpleNamespace(user_identifier=CALLER, paid_share=Decimal("60.00"), owed_share=Decimal("30.00")),
            SimpleNamespace(user_identifier=OTHER, paid_share=Decimal("0.00"), owed_share=Decimal("30.00")),
        ],
    )


def test_expenses_csv_is_locale_safe():
    text = csv_writer.expenses_csv([_fake_expense()])
    assert text.startswith("﻿")  # UTF-8 BOM for Excel
    lines = text.splitlines()
    assert lines[0].lstrip("﻿").startswith("id,group_id,date,description,amount")
    # Decimal preserved with 2dp (not float), '.' separator; the comma-bearing description is quoted.
    assert "60.00" in text
    assert '"Dinner, drinks & more"' in text


def test_splits_csv_one_row_per_person():
    text = csv_writer.splits_csv([_fake_expense()])
    body = text.lstrip("﻿").splitlines()
    assert body[0] == "expense_id,date,description,user_identifier,paid_share,owed_share,currency"
    assert len(body) == 3  # header + 2 splits
    assert any(",export-alice," in r and ",60.00," in r for r in body[1:])
    assert any(",export-bob," in r and ",0.00,30.00," in r for r in body[1:])


def _fake_txn(amount, fitid, desc="Coffee & Bar <Test>"):
    return SimpleNamespace(
        id=uuid4(), account_id=uuid4(), date=date(2026, 6, 15), description=desc,
        amount=amount, currency="USD", external_transaction_id=fitid,
    )


def test_ofx_roundtrips_through_the_reader():
    debit = _fake_txn(Decimal("12.34"), "FIT-DEBIT")     # outflow (positive internally)
    credit = _fake_txn(Decimal("-50.00"), "FIT-CREDIT")  # inflow (negative internally)
    text = ofx_writer.transactions_ofx([debit, credit], generated_at=datetime(2026, 7, 8, tzinfo=UTC))

    parsed = ofx_reader.parse(text)
    by_fitid = {t.fitid: t for stmt in parsed for t in stmt.transactions}
    assert by_fitid["FIT-DEBIT"].amount == Decimal("12.34")   # sign preserved (outflow)
    assert by_fitid["FIT-DEBIT"].date == date(2026, 6, 15)
    assert by_fitid["FIT-CREDIT"].amount == Decimal("-50.00")  # sign preserved (inflow)
    assert by_fitid["FIT-DEBIT"].description == "Coffee & Bar <Test>"  # escaping round-trips


# --- DB integration ------------------------------------------------------------

async def _seed(session):
    group = Group(name="Export Trip", backend_type=BackendType.self_hosted)
    other_group = Group(name="Bob-only", backend_type=BackendType.self_hosted)
    session.add_all([group, other_group])
    await session.flush()
    session.add_all([
        GroupMember(group_id=group.id, user_identifier=CALLER),
        GroupMember(group_id=group.id, user_identifier=OTHER),
        GroupMember(group_id=other_group.id, user_identifier=OTHER),
    ])
    exp = Expense(group_id=group.id, description="Dinner", amount=Decimal("60.00"),
                  currency="USD", date=date(2026, 7, 1), created_by=CALLER)
    exp_other = Expense(group_id=other_group.id, description="Not mine", amount=Decimal("10.00"),
                        currency="USD", date=date(2026, 7, 2), created_by=OTHER)
    session.add_all([exp, exp_other])
    await session.flush()
    session.add_all([
        Split(expense_id=exp.id, user_identifier=CALLER, paid_share=Decimal("60.00"), owed_share=Decimal("30.00")),
        Split(expense_id=exp.id, user_identifier=OTHER, paid_share=Decimal("0.00"), owed_share=Decimal("30.00")),
    ])
    acct = Account(name="Checking", owner_identifier=CALLER, balance=Decimal("100.00"),
                   currency="USD", share_level=ShareLevel.private)
    session.add(acct)
    await session.flush()
    session.add(Transaction(account_id=acct.id, source=TransactionSource.manual, description="Coffee",
                            amount=Decimal("4.50"), currency="USD", date=date(2026, 6, 20),
                            owner_identifier=CALLER, external_transaction_id="FIT-1"))
    await session.commit()
    return group.id, other_group.id, acct.id


async def _purge(session):
    from sqlalchemy import delete, select
    gids = (await session.scalars(select(Group.id).where(Group.name.in_(["Export Trip", "Bob-only"])))).all()
    if gids:
        eids = (await session.scalars(select(Expense.id).where(Expense.group_id.in_(gids)))).all()
        if eids:
            await session.execute(delete(Split).where(Split.expense_id.in_(eids)))
            await session.execute(delete(Expense).where(Expense.id.in_(eids)))
        await session.execute(delete(GroupMember).where(GroupMember.group_id.in_(gids)))
        await session.execute(delete(Group).where(Group.id.in_(gids)))
    await session.execute(delete(Transaction).where(Transaction.owner_identifier == CALLER))
    await session.execute(delete(Account).where(Account.owner_identifier == CALLER))
    await session.commit()


async def test_export_scoping_and_serialization():
    async with async_session() as session:
        await _purge(session)
        await _seed(session)
        try:
            # Scoping: the caller sees only their group's expense; open mode sees both.
            mine = await queries.fetch_expenses(session, CALLER)
            assert {e.description for e in mine} == {"Dinner"}
            everyone = await queries.fetch_expenses(session, None)
            assert {"Dinner", "Not mine"} <= {e.description for e in everyone}

            # JSON preserves Decimal precision losslessly.
            payload = json.loads(json_writer.expenses_json(mine))
            assert Decimal(str(payload[0]["amount"])) == Decimal("60.00")
            assert len(payload[0]["splits"]) == 2

            # OFX export of the caller's transactions re-parses to the same values.
            txns = await queries.fetch_transactions(session, CALLER)
            parsed = ofx_reader.parse(ofx_writer.transactions_ofx(txns, generated_at=datetime(2026, 7, 8, tzinfo=UTC)))
            got = {t.fitid: t for s in parsed for t in s.transactions}
            assert got["FIT-1"].amount == Decimal("4.50")

            # Archive bundles every dataset (skip receipts - none, and avoids MinIO).
            data = await archive.build_archive(session, CALLER, include_receipts=False)
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                names = set(zf.namelist())
            assert {"README.txt", "expenses.csv", "splits.csv", "expenses.json",
                    "transactions.ofx", "accounts.csv", "balances.json", "groups.csv"} <= names
        finally:
            await _purge(session)


async def test_ofx_export_reimports_into_same_account_and_dedups():
    """The strong-round-trip guarantee: exporting an account's transactions to OFX and re-importing them
    matches the SAME account (via the stable external id in <ACCTID>), dedups by FITID (imports nothing new),
    and never zeroes the balance (no <LEDGERBAL> is emitted)."""
    from sqlalchemy import delete, select

    from app.routers import statements

    owner = "export-ofx-rt"

    async def _clean(session):
        aids = (await session.scalars(select(Account.id).where(Account.owner_identifier == owner))).all()
        if aids:
            await session.execute(delete(Transaction).where(Transaction.account_id.in_(aids)))
            await session.execute(delete(Account).where(Account.id.in_(aids)))
        await session.commit()

    async with async_session() as session:
        await _clean(session)
        acct = Account(name="Apple Card", type="credit", owner_identifier=owner, currency="USD",
                       balance=Decimal("250.00"), external_account_id="APPLE-XYZ", institution_name="Apple Card")
        session.add(acct)
        await session.flush()
        session.add(Transaction(account_id=acct.id, source=TransactionSource.manual, description="Coffee & Cake",
                                amount=Decimal("4.50"), currency="USD", date=date(2026, 6, 20),
                                owner_identifier=owner, external_transaction_id="FIT-RT-1"))
        await session.commit()
        try:
            txns = await queries.fetch_transactions(session, owner)
            accounts = await queries.fetch_accounts(session, owner)
            ofx_text = ofx_writer.transactions_ofx(txns, accounts=accounts,
                                                   generated_at=datetime(2026, 7, 8, tzinfo=UTC))
            # Stable external id (not the internal UUID), credit-card aggregate, institution ORG, no balance.
            assert "<ACCTID>APPLE-XYZ" in ofx_text
            assert "<CCSTMTRS>" in ofx_text
            assert "<ORG>Apple Card" in ofx_text
            assert "<LEDGERBAL>" not in ofx_text

            before = acct.balance
            result = await statements.import_ofx(session, owner, ofx_text.encode("utf-8"))
            assert result.imported == 0             # deduped by FITID - re-import adds nothing
            assert result.account_id == acct.id     # matched the SAME account, no duplicate created
            n_accounts = len(
                (await session.scalars(select(Account.id).where(Account.owner_identifier == owner))).all())
            assert n_accounts == 1
            await session.refresh(acct)
            assert acct.balance == before           # balance untouched (was zeroed by the old writer)
        finally:
            await _clean(session)


if __name__ == "__main__":
    from tests._runner import run
    run(dict(globals()))
