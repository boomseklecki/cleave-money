"""Avatar URL resolution + object cleanup.

A user/group with a MinIO-backed custom avatar (`avatar_object_key` set) is served from our own
auth-gated endpoint; otherwise the stored external Splitwise/Google `avatar_url` is used. This is
the single source of truth for that precedence - the response schemas resolve it inline, and the
hand-built connection response uses `resolved_avatar_url`. Deleting a user/group purges its avatar
objects here (best-effort), so a delete doesn't orphan images in MinIO.
"""
import asyncio
import logging

from app.integrations.storage import minio_client

log = logging.getLogger(__name__)


def avatar_object_keys(entity) -> list[str]:
    """The MinIO keys backing an entity's custom avatar (display + original), for cleanup on delete."""
    return [
        k for k in (getattr(entity, "avatar_object_key", None),
                    getattr(entity, "avatar_original_key", None)) if k
    ]


async def remove_avatar_objects(keys: list[str]) -> None:
    """Best-effort removal of avatar objects so deleting a user/group doesn't orphan its images in MinIO
    (mirrors the receipt-object cleanup). Call after the row is committed away."""
    for key in keys:
        try:
            await asyncio.to_thread(minio_client.remove, key)
        except Exception:
            log.warning("avatar object cleanup failed (key=%s)", key, exc_info=True)


def avatar_endpoint(kind: str, entity_id) -> str:
    """The proxied serving path for a custom avatar. `kind` is "users" or "groups"."""
    return f"/{kind}/{entity_id}/avatar"


def resolved_avatar_url(entity, kind: str) -> str | None:
    """Our endpoint when the entity has a custom avatar, else its external avatar_url."""
    if getattr(entity, "avatar_object_key", None):
        return avatar_endpoint(kind, entity.id)
    return entity.avatar_url
