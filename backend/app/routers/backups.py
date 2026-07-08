"""Admin-only backup management: create / list / restore / delete full-stack backups (DB + receipts).

Every route is gated by `require_admin`. The raw artifact is never returned - only metadata and actions.
Create and restore are long-running (a pg_dump/pg_restore + receipt IO); the iOS client calls these on its
300s "slow" transport.
"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_admin
from app.db import get_session
from app.schemas.backup import (
    BackupCreate,
    BackupResponse,
    OffsiteSnapshot,
    OffsiteStatus,
    RestoreResult,
)
from app.services import backups

router = APIRouter(tags=["backups"])


def _response(info: backups.BackupInfo) -> BackupResponse:
    return BackupResponse(name=info.name, size_bytes=info.size_bytes, created_at=info.created_at,
                          label=info.label, kind=info.kind)


@router.get("/backups", response_model=list[BackupResponse])
async def list_backups(_: str = Depends(require_admin)) -> list[BackupResponse]:
    return [_response(b) for b in await backups.list_backups()]


@router.get("/backups/offsite", response_model=OffsiteStatus)
async def offsite_status(_: str = Depends(require_admin)) -> OffsiteStatus:
    return OffsiteStatus(**await backups.offsite_status())


@router.get("/backups/offsite/snapshots", response_model=list[OffsiteSnapshot])
async def offsite_snapshots(_: str = Depends(require_admin)) -> list[OffsiteSnapshot]:
    """List the restic snapshots in the off-device repo (read-only). Empty when the tier is off/unconfigured."""
    return [OffsiteSnapshot(**s) for s in await backups.offsite_snapshots()]


@router.post("/backups/offsite", response_model=OffsiteStatus)
async def offsite_backup_now(_: str = Depends(require_admin)) -> OffsiteStatus:
    """Push a fresh off-device (restic) snapshot on demand. 409 if the tier isn't enabled/configured."""
    try:
        await backups.offsite_push(label="manual")
        await backups.record_offsite_result(True, "")
    except Exception as exc:  # noqa: BLE001 - record + surface as a clean error
        await backups.record_offsite_result(False, str(exc))
        raise HTTPException(status_code=409, detail=f"Off-device backup failed: {exc}") from exc
    return OffsiteStatus(**await backups.offsite_status())


@router.post("/backups", response_model=BackupResponse, status_code=201)
async def create_backup(body: BackupCreate, _: str = Depends(require_admin)) -> BackupResponse:
    return _response(await backups.create(label=body.label, kind=backups.KIND_MANUAL))


@router.post("/backups/{name}/restore", response_model=RestoreResult)
async def restore_backup(
    name: str,
    _: str = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
) -> RestoreResult:
    # Release this request's DB connection BEFORE restoring. The auth dependency leaves this session
    # idle-in-transaction holding an AccessShare lock on `users`; pg_restore --clean needs AccessExclusive
    # on the same tables → a self-deadlock that wedges the whole DB (every login queues behind it). Closing
    # frees the lock so pg_restore can proceed.
    await session.close()
    return RestoreResult(**await backups.restore(name))


@router.delete("/backups/{name}", status_code=204)
async def delete_backup(name: str, _: str = Depends(require_admin)) -> None:
    await backups.delete(name)
