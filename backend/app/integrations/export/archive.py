"""Assembles the whole-account ZIP: every dataset as CSV + JSON, transactions also
as OFX, a README describing the files, and (by default) the receipt image files
pulled from MinIO.

`write_archive` streams the ZIP into a caller-supplied file object (the router hands it a spooled temp file it
then streams to the client), so the whole archive never sits in memory at once - only one receipt's bytes are
held at a time while it's copied in. `build_archive` is a thin in-memory wrapper for callers/tests that want the
bytes directly.
"""
import asyncio
import io
import zipfile
from datetime import datetime
from typing import IO

from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.export import csv_writer, json_writer, ofx_writer, queries
from app.integrations.storage import minio_client

_EXT_BY_TYPE = {
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/png": ".png",
    "image/heic": ".heic",
    "image/webp": ".webp",
    "application/pdf": ".pdf",
}

_README = """\
Cleave data export
==================

You own your money data. This archive is everything Cleave holds for your account.

Files
-----
expenses.csv       One row per shared expense.
splits.csv         One row per (expense, person) with each person's paid/owed share.
expenses.json      The same expenses with nested splits, items, and receipts.
transactions.csv   One row per bank/manual transaction.
transactions.json  The same transactions with nested items and receipts.
transactions.ofx   Transactions in OFX format (re-importable into Cleave or other
                   finance tools). Amounts follow OFX convention (negative = debit).
accounts.csv/.json Your accounts and their balances.
balances.csv/.json Your net balance with each person (positive = they owe you).
groups.csv/.json   Your groups and their members.
receipts/          Receipt image/PDF files, named by their record id (if included).

Notes
-----
- CSV files are UTF-8 with a BOM and use '.' as the decimal separator.
- Money preserves 2-decimal precision exactly (no floating point).
"""


def _ext(content_type: str | None) -> str:
    return _EXT_BY_TYPE.get((content_type or "").lower(), "")


async def _add_receipts(zf: zipfile.ZipFile, *record_sets) -> None:
    seen: set[str] = set()
    for records in record_sets:
        for record in records:
            for receipt in record.receipts:
                if receipt.object_key in seen:
                    continue
                seen.add(receipt.object_key)
                try:
                    data, content_type = await asyncio.to_thread(
                        minio_client.get_object_and_type, receipt.object_key
                    )
                except Exception:
                    continue  # a missing object shouldn't abort the whole export
                zf.writestr(f"receipts/{receipt.id}{_ext(content_type or receipt.content_type)}", data)


async def write_archive(
    session: AsyncSession,
    caller: str | None,
    out: IO[bytes],
    *,
    include_receipts: bool = True,
    generated_at: datetime | None = None,
) -> None:
    """Stream the whole-account ZIP into `out` (any writable binary file object). The datasets are small and
    built in memory; receipts are copied in one at a time so the archive is bounded to a single object's bytes
    plus whatever the ZIP has already spooled to `out`."""
    expenses = await queries.fetch_expenses(session, caller)
    transactions = await queries.fetch_transactions(session, caller)
    accounts = await queries.fetch_accounts(session, caller)
    balances = await queries.fetch_balances(session, caller)
    groups, members = await queries.fetch_groups(session, caller)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("README.txt", _README)
        zf.writestr("expenses.csv", csv_writer.expenses_csv(expenses))
        zf.writestr("splits.csv", csv_writer.splits_csv(expenses))
        zf.writestr("expenses.json", json_writer.expenses_json(expenses))
        zf.writestr("transactions.csv", csv_writer.transactions_csv(transactions))
        zf.writestr("transactions.json", json_writer.transactions_json(transactions))
        zf.writestr("transactions.ofx",
                    ofx_writer.transactions_ofx(transactions, accounts=accounts, generated_at=generated_at))
        zf.writestr("accounts.csv", csv_writer.accounts_csv(accounts))
        zf.writestr("accounts.json", json_writer.accounts_json(accounts))
        zf.writestr("balances.csv", csv_writer.balances_csv(balances))
        zf.writestr("balances.json", json_writer.balances_json(balances))
        zf.writestr("groups.csv", csv_writer.groups_csv(groups, members))
        zf.writestr("groups.json", json_writer.groups_json(groups, members))
        if include_receipts:
            await _add_receipts(zf, expenses, transactions)


async def build_archive(
    session: AsyncSession,
    caller: str | None,
    *,
    include_receipts: bool = True,
    generated_at: datetime | None = None,
) -> bytes:
    """In-memory convenience wrapper around `write_archive` for callers/tests that want the bytes directly.
    The router uses the streaming `write_archive` path instead so large archives never fully materialize."""
    buf = io.BytesIO()
    await write_archive(session, caller, buf, include_receipts=include_receipts, generated_at=generated_at)
    return buf.getvalue()
