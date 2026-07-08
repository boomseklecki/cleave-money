"""User-facing data export. Per-format download endpoints plus a single
`/export/archive.zip` that bundles everything. Every response is an attachment.

Reads are scoped to the caller by `app/integrations/export/queries.py` (bypassed in
open mode, like the list endpoints). The router only wires format → serializer;
the serializers live in `app/integrations/export/`.
"""
import tempfile
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, Query, Response
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.db import get_session
from app.integrations.export import archive, csv_writer, json_writer, ofx_writer, queries

# Spool the ZIP to memory up to this size, then transparently to a temp file on disk, so a large export
# (many receipts) never has to fit in RAM.
_ARCHIVE_SPOOL_MAX = 16 * 1024 * 1024

router = APIRouter(prefix="/export", tags=["export"])


def _attachment(filename: str, data: bytes | str, media_type: str) -> Response:
    body = data.encode("utf-8") if isinstance(data, str) else data
    return Response(
        content=body,
        media_type=media_type,
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


_CSV = "text/csv; charset=utf-8"
_JSON = "application/json"


@router.get("/expenses.csv")
async def expenses_csv(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    return _attachment("expenses.csv", csv_writer.expenses_csv(await queries.fetch_expenses(session, caller)), _CSV)


@router.get("/splits.csv")
async def splits_csv(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    return _attachment("splits.csv", csv_writer.splits_csv(await queries.fetch_expenses(session, caller)), _CSV)


@router.get("/expenses.json")
async def expenses_json(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    return _attachment("expenses.json", json_writer.expenses_json(await queries.fetch_expenses(session, caller)), _JSON)


@router.get("/transactions.csv")
async def transactions_csv(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    return _attachment("transactions.csv", csv_writer.transactions_csv(await queries.fetch_transactions(session, caller)), _CSV)


@router.get("/transactions.json")
async def transactions_json(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    return _attachment("transactions.json", json_writer.transactions_json(await queries.fetch_transactions(session, caller)), _JSON)


@router.get("/transactions.ofx")
async def transactions_ofx(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    txns = await queries.fetch_transactions(session, caller)
    accounts = await queries.fetch_accounts(session, caller)  # supplies the stable ACCTID/ORG for re-import
    body = ofx_writer.transactions_ofx(txns, accounts=accounts, generated_at=datetime.now(UTC))
    return _attachment("transactions.ofx", body, "application/x-ofx")


@router.get("/accounts.csv")
async def accounts_csv(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    return _attachment("accounts.csv", csv_writer.accounts_csv(await queries.fetch_accounts(session, caller)), _CSV)


@router.get("/accounts.json")
async def accounts_json(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    return _attachment("accounts.json", json_writer.accounts_json(await queries.fetch_accounts(session, caller)), _JSON)


@router.get("/balances.csv")
async def balances_csv(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    return _attachment("balances.csv", csv_writer.balances_csv(await queries.fetch_balances(session, caller)), _CSV)


@router.get("/balances.json")
async def balances_json(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    return _attachment("balances.json", json_writer.balances_json(await queries.fetch_balances(session, caller)), _JSON)


@router.get("/groups.csv")
async def groups_csv(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    groups, members = await queries.fetch_groups(session, caller)
    return _attachment("groups.csv", csv_writer.groups_csv(groups, members), _CSV)


@router.get("/groups.json")
async def groups_json(caller=Depends(require_auth), session: AsyncSession = Depends(get_session)):
    groups, members = await queries.fetch_groups(session, caller)
    return _attachment("groups.json", json_writer.groups_json(groups, members), _JSON)


@router.get("/archive.zip")
async def archive_zip(
    receipts: bool = Query(True, description="Include receipt image/PDF files in the archive."),
    caller=Depends(require_auth),
    session: AsyncSession = Depends(get_session),
):
    # Build into a spooled temp file (RAM up to the threshold, then disk) and stream it back, so the whole
    # archive - receipts and all - never has to be held in memory at once.
    spool = tempfile.SpooledTemporaryFile(max_size=_ARCHIVE_SPOOL_MAX)
    await archive.write_archive(
        session, caller, spool, include_receipts=receipts, generated_at=datetime.now(UTC)
    )
    spool.seek(0)

    def _chunks():
        try:
            while chunk := spool.read(64 * 1024):
                yield chunk
        finally:
            spool.close()

    return StreamingResponse(
        _chunks(),
        media_type="application/zip",
        headers={"Content-Disposition": 'attachment; filename="cleave-export.zip"'},
    )
