import asyncio
import logging
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from minio.error import S3Error
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.auth.scope import assert_group_member, assert_owner, assert_transaction_readable
from app.config import settings
from app.db import get_session
from app.integrations.storage import minio_client
from app.models import Expense, Receipt, Transaction
from app.schemas.receipt import ReceiptResponse

log = logging.getLogger(__name__)

router = APIRouter(tags=["receipts"])

# Receipts are images (native camera/library) or the occasional PDF. Reject anything else + cap the size - 
# defense-in-depth (not exploitable with the native-app-only consumer today, but the stored content_type is
# echoed verbatim on download, so don't accept arbitrary types).
_ALLOWED_RECEIPT_TYPES = {"image/jpeg", "image/jpg", "image/png", "image/heic", "image/heif", "image/webp",
                          "image/gif", "application/pdf"}
_MAX_RECEIPT_BYTES = 15 * 1024 * 1024  # 15 MiB

_BINARY_BODY = {
    "content": {"application/octet-stream": {"schema": {"type": "string", "format": "binary"}}},
    "required": True,
}
_BINARY_RESPONSE = {
    200: {
        "content": {
            "application/octet-stream": {"schema": {"type": "string", "format": "binary"}}
        }
    }
}


async def _get_expense_or_404(session: AsyncSession, expense_id: UUID) -> Expense:
    expense = await session.get(Expense, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    return expense


async def _get_transaction_or_404(session: AsyncSession, transaction_id: UUID) -> Transaction:
    transaction = await session.get(Transaction, transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    return transaction


async def _assert_receipt_access(
    session: AsyncSession, receipt: Receipt, caller: str | None, *, write: bool = False
) -> None:
    """A receipt is visible to members of its expense's group, or - for a transaction receipt - its owner or a
    caller the account is `full`-shared with. `write=True` (delete) keeps transaction receipts owner-only."""
    if receipt.expense_id is not None:
        expense = await session.get(Expense, receipt.expense_id)
        if expense is not None:
            await assert_group_member(session, expense.group_id, caller)
    elif receipt.transaction_id is not None:
        transaction = await session.get(Transaction, receipt.transaction_id)
        if transaction is not None:
            if write:
                assert_owner(transaction.owner_identifier, caller)
            else:
                await assert_transaction_readable(session, transaction, caller)


async def _store_and_create(session: AsyncSession, request: Request, owner_id: UUID, **owner_fk) -> Receipt:
    """Put the request body in MinIO and create the Receipt row keyed by exactly one of expense_id/transaction_id."""
    content_type = (request.headers.get("content-type") or "").split(";")[0].strip().lower()
    if content_type not in _ALLOWED_RECEIPT_TYPES:
        raise HTTPException(status_code=422, detail=f"Unsupported receipt content-type: {content_type or 'none'}")
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > _MAX_RECEIPT_BYTES:
        raise HTTPException(status_code=413, detail="Receipt too large")
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="Empty request body")
    if len(data) > _MAX_RECEIPT_BYTES:
        raise HTTPException(status_code=413, detail="Receipt too large")
    object_key = minio_client.build_object_key(owner_id, content_type)
    await asyncio.to_thread(minio_client.put_object, object_key, data, content_type)
    receipt = Receipt(
        bucket=settings.minio_bucket, object_key=object_key, content_type=content_type, **owner_fk
    )
    session.add(receipt)
    try:
        await session.commit()
    except Exception:
        # The object is already in MinIO but the row didn't commit - remove it so we don't orphan bytes.
        try:
            await asyncio.to_thread(minio_client.remove, object_key)
        except Exception:
            log.warning("receipt compensating cleanup failed (key=%s)", object_key, exc_info=True)
        raise
    await session.refresh(receipt)
    return receipt


@router.post(
    "/expenses/{expense_id}/receipts",
    response_model=ReceiptResponse,
    status_code=201,
    openapi_extra={"requestBody": _BINARY_BODY},
)
async def upload_receipt(
    expense_id: UUID,
    request: Request,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Receipt:
    expense = await _get_expense_or_404(session, expense_id)
    await assert_group_member(session, expense.group_id, caller)
    return await _store_and_create(session, request, expense_id, expense_id=expense_id)


@router.get("/expenses/{expense_id}/receipts", response_model=list[ReceiptResponse])
async def list_receipts(
    expense_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Receipt]:
    expense = await _get_expense_or_404(session, expense_id)
    await assert_group_member(session, expense.group_id, caller)
    rows = await session.scalars(
        select(Receipt).where(Receipt.expense_id == expense_id).order_by(Receipt.created_at)
    )
    return list(rows)


@router.post(
    "/transactions/{transaction_id}/receipts",
    response_model=ReceiptResponse,
    status_code=201,
    openapi_extra={"requestBody": _BINARY_BODY},
)
async def upload_transaction_receipt(
    transaction_id: UUID,
    request: Request,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Receipt:
    transaction = await _get_transaction_or_404(session, transaction_id)
    assert_owner(transaction.owner_identifier, caller)
    return await _store_and_create(session, request, transaction_id, transaction_id=transaction_id)


@router.get("/transactions/{transaction_id}/receipts", response_model=list[ReceiptResponse])
async def list_transaction_receipts(
    transaction_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Receipt]:
    transaction = await _get_transaction_or_404(session, transaction_id)
    await assert_transaction_readable(session, transaction, caller)
    rows = await session.scalars(
        select(Receipt).where(Receipt.transaction_id == transaction_id).order_by(Receipt.created_at)
    )
    return list(rows)


@router.get(
    "/receipts/{receipt_id}/content",
    response_class=Response,
    responses=_BINARY_RESPONSE,
)
async def download_receipt(
    receipt_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Response:
    receipt = await session.get(Receipt, receipt_id)
    if receipt is None:
        raise HTTPException(status_code=404, detail="Receipt not found")
    await _assert_receipt_access(session, receipt, caller)
    try:
        data = await asyncio.to_thread(minio_client.get_bytes, receipt.object_key)
    except S3Error:  # the DB row exists but the object is gone (e.g. a prior partial cleanup) → 404, not 500
        raise HTTPException(status_code=404, detail="Receipt object not found")
    return Response(content=data, media_type=receipt.content_type or "application/octet-stream")


@router.delete("/receipts/{receipt_id}", status_code=204)
async def delete_receipt(
    receipt_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    receipt = await session.get(Receipt, receipt_id)
    if receipt is None:
        raise HTTPException(status_code=404, detail="Receipt not found")
    await _assert_receipt_access(session, receipt, caller, write=True)
    object_key = receipt.object_key
    # Delete the row + commit FIRST, then best-effort remove the object - so a commit failure leaves both
    # intact (vs. object-gone + dangling row), matching the expense/group delete ordering.
    await session.delete(receipt)
    await session.commit()
    try:
        await asyncio.to_thread(minio_client.remove, object_key)
    except Exception:
        log.warning("receipt object cleanup failed (key=%s)", object_key, exc_info=True)
