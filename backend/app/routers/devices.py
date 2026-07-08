from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.db import get_session
from app.models import DeviceToken
from app.schemas.device import DeviceRegister

router = APIRouter(tags=["devices"])


@router.post("/devices", status_code=204)
async def register_device(
    body: DeviceRegister,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Registers (idempotently) the caller's APNs device token for push."""
    if caller is None:
        raise HTTPException(status_code=401, detail="Sign in to register for push")
    existing = await session.scalar(select(DeviceToken).where(
        DeviceToken.user_identifier == caller, DeviceToken.token == body.token))
    if existing is None:
        session.add(DeviceToken(user_identifier=caller, token=body.token, platform=body.platform,
                                public_key=body.public_key))
        await session.commit()
    elif body.public_key is not None and existing.public_key != body.public_key:
        existing.public_key = body.public_key  # device rotated / first published its key
        await session.commit()


@router.delete("/devices", status_code=204)
async def unregister_device(
    body: DeviceRegister,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Removes the caller's device token (sign-out / push disabled)."""
    if caller is None:
        return
    await session.execute(delete(DeviceToken).where(
        DeviceToken.user_identifier == caller, DeviceToken.token == body.token))
    await session.commit()
