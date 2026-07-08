"""Per-(owner, transaction) overrides (category + budget inclusion): set/clear via PATCH, scoped to the
caller, coexisting in one row. DB-backed."""
import uuid
from datetime import date

from sqlalchemy import delete, select

from app.db import async_session
from app.models import Transaction, TransactionOverride
from app.routers.accounts import _load_transaction, update_transaction, update_transaction_override
from app.schemas.transaction import TransactionOverrideUpdate, TransactionUpdate


async def _make_txn(session, owner: str) -> uuid.UUID:
    txn = Transaction(
        source="manual", description="Coffee", amount=4, currency="USD", date=date(2026, 6, 1),
        owner_identifier=owner,
    )
    session.add(txn)
    await session.commit()
    return txn.id


async def _cleanup(session, txn_id):
    await session.execute(
        delete(TransactionOverride).where(TransactionOverride.transaction_id == txn_id)
    )
    await session.execute(delete(Transaction).where(Transaction.id == txn_id))
    await session.commit()


async def test_set_then_clear_override():
    async with async_session() as s:
        txn_id = await _make_txn(s, "alice")
        try:
            await update_transaction(txn_id, TransactionUpdate(category_override="Dining"),
                                     caller="alice", session=s)
            t = await _load_transaction(s, txn_id, "alice")
            assert t.category_override == "Dining"
            # A second update replaces it.
            await update_transaction(txn_id, TransactionUpdate(category_override="Groceries"),
                                     caller="alice", session=s)
            assert (await _load_transaction(s, txn_id, "alice")).category_override == "Groceries"
            # null clears it (row deleted).
            await update_transaction(txn_id, TransactionUpdate(category_override=None),
                                     caller="alice", session=s)
            assert (await _load_transaction(s, txn_id, "alice")).category_override is None
            assert (await s.scalar(select(TransactionOverride).where(
                TransactionOverride.transaction_id == txn_id))) is None
        finally:
            await _cleanup(s, txn_id)


async def test_include_flag_coexists_with_category():
    async with async_session() as s:
        txn_id = await _make_txn(s, "alice")
        try:
            # Exclude from spending (via the override endpoint); the row appears with the flag.
            await update_transaction_override(txn_id, TransactionOverrideUpdate(include_in_spending=False),
                                              caller="alice", session=s)
            t = await _load_transaction(s, txn_id, "alice")
            assert t.include_in_spending is False and t.category_override is None
            # Add a category override (separate endpoint) - both persist on the one row.
            await update_transaction(txn_id, TransactionUpdate(category_override="Dining"),
                                     caller="alice", session=s)
            t = await _load_transaction(s, txn_id, "alice")
            assert t.include_in_spending is False and t.category_override == "Dining"
            # Clear the category; the row stays because the flag is still set.
            await update_transaction(txn_id, TransactionUpdate(category_override=None),
                                     caller="alice", session=s)
            assert (await s.scalar(select(TransactionOverride).where(
                TransactionOverride.transaction_id == txn_id))) is not None
            # Clear the flag too → row deleted.
            await update_transaction_override(txn_id, TransactionOverrideUpdate(include_in_spending=None),
                                              caller="alice", session=s)
            assert (await s.scalar(select(TransactionOverride).where(
                TransactionOverride.transaction_id == txn_id))) is None
        finally:
            await _cleanup(s, txn_id)


async def test_override_scoped_per_owner():
    async with async_session() as s:
        txn_id = await _make_txn(s, "alice")
        try:
            await update_transaction(txn_id, TransactionUpdate(category_override="Dining"),
                                     caller="alice", session=s)
            # Bob (a different caller) sees no override on the same transaction row.
            assert (await _load_transaction(s, txn_id, "bob")).category_override is None
            assert (await _load_transaction(s, txn_id, "alice")).category_override == "Dining"
        finally:
            await _cleanup(s, txn_id)


async def test_note_set_readback_scoped_and_clear():
    async with async_session() as s:
        txn_id = await _make_txn(s, "alice")
        try:
            # A note-only override row: set + read back.
            await update_transaction_override(
                txn_id, TransactionOverrideUpdate(note="Duolingo subscription"), caller="alice", session=s)
            assert (await _load_transaction(s, txn_id, "alice")).note == "Duolingo subscription"
            # Per-user: bob doesn't see alice's note.
            assert (await _load_transaction(s, txn_id, "bob")).note is None
            # Coexists with an include flag on the one row.
            await update_transaction_override(
                txn_id, TransactionOverrideUpdate(include_in_spending=False), caller="alice", session=s)
            t = await _load_transaction(s, txn_id, "alice")
            assert t.note == "Duolingo subscription" and t.include_in_spending is False
            # Blank note clears just the note (flag keeps the row alive).
            await update_transaction_override(
                txn_id, TransactionOverrideUpdate(note="   "), caller="alice", session=s)
            t = await _load_transaction(s, txn_id, "alice")
            assert t.note is None and t.include_in_spending is False
            assert (await s.scalar(select(TransactionOverride).where(
                TransactionOverride.transaction_id == txn_id))) is not None
            # Clearing the flag too drops the row.
            await update_transaction_override(
                txn_id, TransactionOverrideUpdate(include_in_spending=None), caller="alice", session=s)
            assert (await s.scalar(select(TransactionOverride).where(
                TransactionOverride.transaction_id == txn_id))) is None
        finally:
            await _cleanup(s, txn_id)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
