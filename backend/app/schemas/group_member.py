from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class GroupMemberCreate(BaseModel):
    # Add an existing directory person by `user_identifier`, OR (Splitwise groups only) invite someone new by
    # `email` (+ optional name). Exactly one path is used; self-hosted groups require `user_identifier`.
    user_identifier: str | None = None
    email: str | None = None
    first_name: str | None = None
    last_name: str | None = None


class GroupMemberResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    group_id: UUID
    user_identifier: str
    created_at: datetime
