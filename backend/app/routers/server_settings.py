"""Admin-editable, server-global runtime settings (invite policy, hard-delete toggles, scheduler intervals,
public hostname). GET is readable by any enrolled member (so the client can show the right UI); PATCH is
admin-only. Storage + the typed registry live in `app/server_settings.py`."""
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app import server_settings as store
from app.auth import require_admin, require_auth
from app.db import get_session
from app.schemas.server_settings import ServerSettingsResponse, ServerSettingsUpdate

router = APIRouter(prefix="/server-settings", tags=["server-settings"])


@router.get("", response_model=ServerSettingsResponse)
async def get_server_settings(
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> ServerSettingsResponse:
    return ServerSettingsResponse(**(await store.get_all(session)))


@router.patch("", response_model=ServerSettingsResponse)
async def update_server_settings(
    body: ServerSettingsUpdate,
    caller: str = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
) -> ServerSettingsResponse:
    for key, value in body.model_dump(exclude_unset=True).items():
        await store.set_value(session, key, value)
    await session.commit()
    return ServerSettingsResponse(**(await store.get_all(session)))
