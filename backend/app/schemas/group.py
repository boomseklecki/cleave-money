from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.logic.avatars import avatar_endpoint
from app.models.enums import BackendType
from app.schemas.user import AvatarCrop


class GroupCreate(BaseModel):
    name: str
    # `splitwise` creates the group on Splitwise (the caller must have a token); default keeps it local.
    backend_type: BackendType = BackendType.self_hosted
    group_type: str | None = None  # Splitwise group type (apartment/trip/...), optional


class GroupUpdate(BaseModel):
    name: str | None = None
    # Per-user overrides (in `group_overrides`): `hidden` (reserved/future), plus budget inclusion. Only
    # provided fields change; null clears that field.
    hidden: bool | None = None
    include_in_spending: bool | None = None
    include_in_cash_flow: bool | None = None


class GroupResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    backend_type: BackendType
    splitwise_group_id: str | None
    group_type: str | None
    avatar_url: str | None
    cover_photo_url: str | None
    # A custom MinIO avatar overrides avatar_url (member-only serving); see UserResponse for the fields.
    avatar_object_key: str | None = Field(default=None, exclude=True)
    has_custom_avatar: bool = False
    avatar_crop: AvatarCrop | None = None
    hidden: bool
    # The caller's per-user budget overrides (from `group_overrides`); the router attaches them. null = default.
    include_in_spending: bool | None = None
    include_in_cash_flow: bool | None = None
    superseded_at: datetime | None
    deleted_at: datetime | None
    created_at: datetime
    updated_at: datetime

    @model_validator(mode="after")
    def _resolve_avatar(self) -> "GroupResponse":
        if self.avatar_object_key:
            self.avatar_url = avatar_endpoint("groups", self.id)
            self.has_custom_avatar = True
        return self
