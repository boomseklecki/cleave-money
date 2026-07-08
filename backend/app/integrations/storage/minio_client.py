"""MinIO storage helpers.

A single internal client (in-cluster `minio:9000`) handles all object IO. Receipt bytes
flow through the API - the iOS client never reaches MinIO directly, so there is no public
client and no presigning. All calls here are blocking - wrap in asyncio.to_thread.
"""
from datetime import datetime, timezone
from functools import lru_cache
from io import BytesIO
from uuid import UUID, uuid4

from minio import Minio
from minio.error import S3Error

from app.config import settings

# Extension by content type so stored keys keep a recognizable suffix.
_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/heic": ".heic",
    "image/webp": ".webp",
    "application/pdf": ".pdf",
}


@lru_cache
def _internal_client() -> Minio:
    return Minio(
        settings.minio_endpoint,
        access_key=settings.minio_access_key,
        secret_key=settings.minio_secret_key,
        secure=settings.minio_secure,
    )


def build_object_key(owner_id: UUID, content_type: str | None) -> str:
    """Object key prefixed by the owning entity's id (an expense or a transaction)."""
    return f"{owner_id}/{uuid4()}{_EXTENSIONS.get(content_type or '', '')}"


def ensure_bucket() -> None:
    client = _internal_client()
    if not client.bucket_exists(settings.minio_bucket):
        client.make_bucket(settings.minio_bucket)


def put_object(object_key: str, data: bytes, content_type: str | None) -> None:
    _internal_client().put_object(
        settings.minio_bucket,
        object_key,
        BytesIO(data),
        length=len(data),
        content_type=content_type or "application/octet-stream",
    )


def get_bytes(object_key: str) -> bytes:
    response = _internal_client().get_object(settings.minio_bucket, object_key)
    try:
        return response.read()
    finally:
        response.close()
        response.release_conn()


def get_object_and_type(object_key: str) -> tuple[bytes, str | None]:
    """Object bytes plus the content-type stored with it at upload (or None if absent), so a caller can
    serve each object with its own type rather than a separately-tracked one."""
    response = _internal_client().get_object(settings.minio_bucket, object_key)
    try:
        return response.read(), response.headers.get("Content-Type")
    finally:
        response.close()
        response.release_conn()


def object_exists(object_key: str) -> bool:
    try:
        _internal_client().stat_object(settings.minio_bucket, object_key)
        return True
    except S3Error:
        return False


def remove(object_key: str) -> None:
    _internal_client().remove_object(settings.minio_bucket, object_key)


def age_seconds(object_key: str) -> float | None:
    """Seconds since a default-bucket object was last modified, or None if it doesn't exist.
    (minio returns a tz-aware UTC last_modified.)"""
    try:
        st = _internal_client().stat_object(settings.minio_bucket, object_key)
    except S3Error:
        return None
    return (datetime.now(timezone.utc) - st.last_modified).total_seconds()


# --- Generic, bucket-parameterized helpers (used by the backups service) -----------------------------
# These take an explicit bucket so they can operate on the backups bucket as well as receipts. All are
# blocking (minio SDK) - call from asyncio.to_thread.

def ensure_bucket_named(bucket: str) -> None:
    client = _internal_client()
    if not client.bucket_exists(bucket):
        client.make_bucket(bucket)


def list_object_names(bucket: str) -> list[str]:
    """Recursive object keys in a bucket (empty if the bucket doesn't exist yet)."""
    client = _internal_client()
    if not client.bucket_exists(bucket):
        return []
    return [obj.object_name for obj in client.list_objects(bucket, recursive=True)]


def stat(bucket: str, object_key: str) -> tuple[int, datetime, dict[str, str]]:
    """(size_bytes, last_modified, user_metadata) for one object."""
    st = _internal_client().stat_object(bucket, object_key)
    return st.size, st.last_modified, dict(st.metadata or {})


def download_to_file(bucket: str, object_key: str, dest_path: str) -> None:
    _internal_client().fget_object(bucket, object_key, dest_path)


def upload_file(bucket: str, object_key: str, src_path: str,
                content_type: str = "application/octet-stream",
                metadata: dict[str, str] | None = None) -> None:
    _internal_client().fput_object(bucket, object_key, src_path, content_type=content_type, metadata=metadata)


def remove_named(bucket: str, object_key: str) -> None:
    _internal_client().remove_object(bucket, object_key)
