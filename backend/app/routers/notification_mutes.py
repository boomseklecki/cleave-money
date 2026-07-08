from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.db import get_session
from app.models import NotificationMute
from app.schemas.notification_mute import NotificationPrefs

router = APIRouter(tags=["notification-prefs"])


@router.get("/notification-prefs", response_model=NotificationPrefs)
async def get_notification_prefs(
    caller: str | None = Depends(require_auth), session: AsyncSession = Depends(get_session)
) -> NotificationPrefs:
    """The caller's notification preference tokens (push/feed mutes). Empty = everything pushed + shown."""
    if caller is None:
        return NotificationPrefs(tokens=[])
    tokens = await session.scalars(
        select(NotificationMute.token).where(NotificationMute.owner_identifier == caller))
    return NotificationPrefs(tokens=sorted(tokens))


@router.put("/notification-prefs", response_model=NotificationPrefs)
async def put_notification_prefs(
    body: NotificationPrefs,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> NotificationPrefs:
    """Replace the caller's full set of preference tokens (delete-all + insert)."""
    if caller is None:
        raise HTTPException(status_code=401, detail="Sign in to save notification preferences")
    await session.execute(delete(NotificationMute).where(NotificationMute.owner_identifier == caller))
    wanted = {t.strip() for t in body.tokens if t.strip()}
    for token in wanted:
        session.add(NotificationMute(owner_identifier=caller, token=token))
    await session.commit()
    return NotificationPrefs(tokens=sorted(wanted))
