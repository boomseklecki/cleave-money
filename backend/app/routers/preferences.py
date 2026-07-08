from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.db import get_session
from app.models.user_preference import UserPreference
from app.schemas.user_preference import PreferenceResponse, PreferenceUpsert

router = APIRouter(tags=["preferences"])


@router.get("/preferences", response_model=list[PreferenceResponse])
async def list_preferences(
    caller: str | None = Depends(require_auth), session: AsyncSession = Depends(get_session)
) -> list[UserPreference]:
    """Every preference blob belonging to the caller (empty in open mode). Each is an opaque JSON string
    the client decodes itself - e.g. the suggestion templates/decisions under key `suggestions.v1`. (The old
    `categories.v1` blob was retired in migration 0049; categories now sync via `/categories`.)"""
    if caller is None:
        return []
    rows = await session.scalars(
        select(UserPreference)
        .where(UserPreference.owner_identifier == caller)
        .order_by(UserPreference.key)
    )
    return list(rows)


@router.put("/preferences/{key}", response_model=PreferenceResponse)
async def upsert_preference(
    key: str,
    body: PreferenceUpsert,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> UserPreference:
    """Store (create or replace) the caller's preference blob under `key`. Scoped to `owner_identifier`,
    so users sharing a backend keep independent preferences."""
    if caller is None:
        raise HTTPException(status_code=401, detail="Sign in to save preferences")
    row = await session.scalar(
        select(UserPreference).where(
            UserPreference.owner_identifier == caller, UserPreference.key == key
        )
    )
    if row is None:
        row = UserPreference(owner_identifier=caller, key=key)
        session.add(row)
    row.value = body.value
    await session.commit()
    await session.refresh(row)
    return row
