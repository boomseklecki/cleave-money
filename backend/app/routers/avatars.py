"""Custom avatars for users and groups.

Mirrors the receipts pipeline (per-entity full image, raw-body upload, proxied + auth-gated
serving), NOT the favicon/logos one (shared, cached, public). A custom avatar overrides the
external Splitwise/Google `avatar_url` via the resolver in `app.logic.avatars`.

Two images per entity, at stable keys (re-save overwrites, delete removes both):
  - display  → `avatars/{kind}/{id}/display.img`  - the small square served everywhere
  - original → `avatars/{kind}/{id}/original.img` - full-res, kept so the crop editor can un-zoom

Access:
  - user avatars: any authenticated caller may read the display (visible to all server users);
    only the owner reads their original / uploads / deletes (via the `/me/...` routes).
  - group avatars: members only (read, write, delete) - `assert_group_member`, so a group photo
    never leaks to a non-member.
"""
import asyncio
import logging
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from minio.error import S3Error
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.auth.scope import assert_group_member
from app.db import get_session
from app.integrations.storage import minio_client
from app.logic.avatars import resolved_avatar_url
from app.models import Group, User
from app.schemas.avatar import AvatarResponse

log = logging.getLogger(__name__)

router = APIRouter(tags=["avatars"])

_ALLOWED_AVATAR_TYPES = {"image/jpeg", "image/jpg", "image/png", "image/heic", "image/heif", "image/webp"}
_MAX_AVATAR_BYTES = 10 * 1024 * 1024  # 10 MiB

_BINARY_BODY = {
    "content": {"application/octet-stream": {"schema": {"type": "string", "format": "binary"}}},
    "required": True,
}
_BINARY_RESPONSE = {200: {"content": {"application/octet-stream": {"schema": {"type": "string", "format": "binary"}}}}}


def _display_key(kind: str, entity_id) -> str:
    return f"avatars/{kind}/{entity_id}/display.img"


def _original_key(kind: str, entity_id) -> str:
    return f"avatars/{kind}/{entity_id}/original.img"


def _validated_content_type(request: Request) -> str:
    content_type = (request.headers.get("content-type") or "").split(";")[0].strip().lower()
    if content_type not in _ALLOWED_AVATAR_TYPES:
        raise HTTPException(status_code=422, detail=f"Unsupported avatar content-type: {content_type or 'none'}")
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > _MAX_AVATAR_BYTES:
        raise HTTPException(status_code=413, detail="Avatar too large")
    return content_type


async def _validated_body(request: Request) -> bytes:
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="Empty request body")
    if len(data) > _MAX_AVATAR_BYTES:
        raise HTTPException(status_code=413, detail="Avatar too large")
    return data


def _parse_crop(request: Request) -> dict | None:
    """The pinch/pan transform sent alongside the display image as `X-Avatar-Crop: scale,dx,dy`."""
    raw = request.headers.get("x-avatar-crop")
    if not raw:
        return None
    try:
        scale, dx, dy = (float(part) for part in raw.split(","))
    except ValueError:
        raise HTTPException(status_code=422, detail="Invalid X-Avatar-Crop header; expected 'scale,dx,dy'")
    return {"scale": scale, "dx": dx, "dy": dy}


def _avatar_response(entity, kind: str) -> AvatarResponse:
    return AvatarResponse(
        avatar_url=resolved_avatar_url(entity, kind),
        has_custom_avatar=bool(entity.avatar_object_key),
        avatar_crop=entity.avatar_crop,
    )


async def _store_image(session: AsyncSession, request: Request, entity, kind: str, *, original: bool) -> None:
    """Put one image (display or original) in MinIO and persist its key on the entity, with the
    receipts-style compensating cleanup so a failed commit doesn't orphan bytes."""
    content_type = _validated_content_type(request)
    data = await _validated_body(request)
    key = (_original_key if original else _display_key)(kind, entity.id)
    await asyncio.to_thread(minio_client.put_object, key, data, content_type)
    if original:
        entity.avatar_original_key = key
    else:
        entity.avatar_object_key = key
        entity.avatar_content_type = content_type
        crop = _parse_crop(request)
        if crop is not None:
            entity.avatar_crop = crop
    try:
        await session.commit()
    except Exception:
        try:
            await asyncio.to_thread(minio_client.remove, key)
        except Exception:
            log.warning("avatar compensating cleanup failed (key=%s)", key, exc_info=True)
        raise
    await session.refresh(entity)


async def _serve(object_key: str | None, content_type: str | None) -> Response:
    if not object_key:
        raise HTTPException(status_code=404, detail="No custom avatar set")
    try:
        data, stored_type = await asyncio.to_thread(minio_client.get_object_and_type, object_key)
    except S3Error:  # the column points at an object that's gone → 404, not 500
        raise HTTPException(status_code=404, detail="Avatar object not found")
    # Prefer the object's own stored type so the original serves as its own format, not the display's
    # (`avatar_content_type` tracks only the display); fall back to it, then to a generic binary type.
    return Response(content=data, media_type=stored_type or content_type or "application/octet-stream")


async def _clear_avatar(session: AsyncSession, entity) -> None:
    """Clear the columns + commit first, then best-effort remove both objects (matches receipt delete
    ordering: a commit failure leaves both intact rather than object-gone + dangling reference)."""
    keys = [k for k in (entity.avatar_object_key, entity.avatar_original_key) if k]
    entity.avatar_object_key = None
    entity.avatar_original_key = None
    entity.avatar_content_type = None
    entity.avatar_crop = None
    await session.commit()
    for key in keys:
        try:
            await asyncio.to_thread(minio_client.remove, key)
        except Exception:
            log.warning("avatar object cleanup failed (key=%s)", key, exc_info=True)


# --- Current user ("me") -----------------------------------------------------------------------------

async def _require_me(session: AsyncSession, caller: str | None) -> User:
    if caller is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    user = await session.scalar(select(User).where(User.identifier == caller))
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@router.put("/me/avatar", response_model=AvatarResponse, openapi_extra={"requestBody": _BINARY_BODY})
async def upload_my_avatar(
    request: Request,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> AvatarResponse:
    """Upload the display square (the served avatar) + optional `X-Avatar-Crop`. Overrides Splitwise/Google."""
    user = await _require_me(session, caller)
    await _store_image(session, request, user, "users", original=False)
    return _avatar_response(user, "users")


@router.put("/me/avatar/original", response_model=AvatarResponse, openapi_extra={"requestBody": _BINARY_BODY})
async def upload_my_avatar_original(
    request: Request,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> AvatarResponse:
    """Upload the full-res original, kept only so the crop editor can reload and un-zoom/un-crop."""
    user = await _require_me(session, caller)
    await _store_image(session, request, user, "users", original=True)
    return _avatar_response(user, "users")


@router.get("/me/avatar/original", response_class=Response, responses=_BINARY_RESPONSE)
async def download_my_avatar_original(
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Response:
    """The owner fetches their own original to re-edit. Originals are never exposed to other users."""
    user = await _require_me(session, caller)
    return await _serve(user.avatar_original_key, user.avatar_content_type)


@router.delete("/me/avatar", status_code=204)
async def delete_my_avatar(
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Remove the custom avatar; the resolver falls back to the external Splitwise/Google avatar."""
    user = await _require_me(session, caller)
    await _clear_avatar(session, user)


@router.get("/users/{user_id}/avatar", response_class=Response, responses=_BINARY_RESPONSE)
async def download_user_avatar(
    user_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Response:
    """The display square, readable by any authenticated caller (a user's avatar is visible to all
    server users). This is the URL the resolver hands out in `avatar_url`."""
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return await _serve(user.avatar_object_key, user.avatar_content_type)


# --- Groups (members only) ---------------------------------------------------------------------------

async def _member_group(session: AsyncSession, group_id: UUID, caller: str | None) -> Group:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    return group


@router.put("/groups/{group_id}/avatar", response_model=AvatarResponse, openapi_extra={"requestBody": _BINARY_BODY})
async def upload_group_avatar(
    group_id: UUID,
    request: Request,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> AvatarResponse:
    group = await _member_group(session, group_id, caller)
    await _store_image(session, request, group, "groups", original=False)
    return _avatar_response(group, "groups")


@router.put(
    "/groups/{group_id}/avatar/original",
    response_model=AvatarResponse,
    openapi_extra={"requestBody": _BINARY_BODY},
)
async def upload_group_avatar_original(
    group_id: UUID,
    request: Request,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> AvatarResponse:
    group = await _member_group(session, group_id, caller)
    await _store_image(session, request, group, "groups", original=True)
    return _avatar_response(group, "groups")


@router.get("/groups/{group_id}/avatar", response_class=Response, responses=_BINARY_RESPONSE)
async def download_group_avatar(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Response:
    """The group's display square - members only, so it never leaks to non-members."""
    group = await _member_group(session, group_id, caller)
    return await _serve(group.avatar_object_key, group.avatar_content_type)


@router.get("/groups/{group_id}/avatar/original", response_class=Response, responses=_BINARY_RESPONSE)
async def download_group_avatar_original(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Response:
    group = await _member_group(session, group_id, caller)
    return await _serve(group.avatar_original_key, group.avatar_content_type)


@router.delete("/groups/{group_id}/avatar", status_code=204)
async def delete_group_avatar(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    group = await _member_group(session, group_id, caller)
    await _clear_avatar(session, group)
