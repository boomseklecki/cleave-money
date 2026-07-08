from datetime import datetime

from pydantic import BaseModel


class BackupResponse(BaseModel):
    name: str
    size_bytes: int
    created_at: datetime
    label: str | None
    kind: str  # "manual" | "scheduled"


class BackupCreate(BaseModel):
    label: str | None = None


class RestoreResult(BaseModel):
    restored: str       # the backup that was restored
    safety_backup: str  # the pre-restore safety backup taken first


class OffsiteStatus(BaseModel):
    """Off-device (restic) backup tier status - no secrets; the repo password + remote creds stay in .env."""
    enabled: bool
    target: str                       # the restic repository string (non-secret)
    last_run_at: datetime | None      # last successful/attempted off-device push
    last_status: str | None           # "ok" or "error: ..."


class OffsiteSnapshot(BaseModel):
    """One restic snapshot in the off-device repo (read-only). Fields non-nullable for the iOS generator."""
    id: str                 # restic short_id (8 hex)
    time: datetime          # snapshot time
    hostname: str
    tags: list[str] = []    # "manual" / "scheduled"
    paths: list[str] = []
