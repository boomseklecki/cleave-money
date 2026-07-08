from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from app.schemas.group import GroupResponse


class SplitwiseStatus(BaseModel):
    connected: bool
    users: list[str]


class LocalImportRequest(BaseModel):
    name: str | None = None  # defaults to the source group's name


class LocalImportResult(BaseModel):
    group: GroupResponse
    expenses_copied: int
    receipts_downloaded: int = 0


class ReceiptDownloadResult(BaseModel):
    downloaded: int
    skipped: int
    enabled: bool


class ReceiptDownloadStarted(BaseModel):
    """The bulk download-all kickoff: the work runs in the background (the caller can leave). `pending` is how
    many receipts were queued; `enabled` is false (nothing started) when the backfill setting is off."""
    enabled: bool
    started: bool
    pending: int


class SplitwiseImportRequest(BaseModel):
    since: str | None = None  # dated_after, e.g. 2020-01-01
    until: str | None = None  # dated_before
    as_user: str | None = None
    dry_run: bool = False


class SplitwiseImportResult(BaseModel):
    groups: int
    expenses_fetched: int
    imported: int
    skipped_deleted: int
    settle_ups: int
    dry_run: bool
    users: int | None = None


class SyncRequest(BaseModel):
    as_user: str | None = None
    since: str | None = None  # override updated_after (ISO 8601); /sync/expenses only
    dry_run: bool = False


class SyncResult(BaseModel):
    groups: int | None = None
    users: int | None = None
    friends: int | None = None
    notifications: int | None = None
    expenses_fetched: int | None = None
    imported: int | None = None
    skipped_deleted: int | None = None
    deleted: int | None = None
    settle_ups: int | None = None
    cursor: datetime | None = None  # new expenses_synced_at after an /sync/expenses run
    dry_run: bool = False


class NotificationResponse(BaseModel):
    id: UUID
    source: str
    type: str | None = None
    content: str
    created_at: datetime
    read: bool
    # Deep-link target (app-native rows only): the entity this is about + its id. Null for Splitwise rows.
    entity_type: str | None = None
    entity_id: str | None = None

    model_config = {"from_attributes": True}
