from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class InviteCreate(BaseModel):
    label: str | None = None  # free note, e.g. who it's for
    ttl_days: int | None = 14  # expiry window; null/<=0 = no expiry


class InviteResponse(BaseModel):
    id: UUID
    code: str
    label: str | None
    status: str  # active | redeemed | revoked | expired
    expires_at: datetime | None
    redeemed_at: datetime | None
    redeemed_by: str | None
    revoked_at: datetime | None
    created_at: datetime
