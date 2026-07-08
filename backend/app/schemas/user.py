from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.logic.avatars import avatar_endpoint
from app.models.enums import UserSource


class AvatarCrop(BaseModel):
    """Pinch/pan transform baked into the custom avatar, so the crop editor can reload it."""
    scale: float
    dx: float
    dy: float


class UserCreate(BaseModel):
    display_name: str
    identifier: str | None = None  # derived from display_name when omitted
    source: UserSource = UserSource.manual
    splitwise_user_id: str | None = None
    email: str | None = None


class UserUpdate(BaseModel):
    display_name: str | None = None
    email: str | None = None


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    identifier: str
    display_name: str
    source: UserSource
    splitwise_user_id: str | None
    email: str | None
    avatar_url: str | None
    # A custom MinIO avatar overrides avatar_url: object key drives resolution (excluded from output),
    # has_custom_avatar tells the client a delete/edit target exists, avatar_crop preloads the editor.
    avatar_object_key: str | None = Field(default=None, exclude=True)
    has_custom_avatar: bool = False
    avatar_crop: AvatarCrop | None = None
    registration_status: str | None
    # Enrollment/admin status - surfaced in the admin-only Local Users view (revoked = not enrolled).
    enrolled: bool
    is_admin: bool
    created_at: datetime
    updated_at: datetime

    @model_validator(mode="after")
    def _resolve_avatar(self) -> "UserResponse":
        if self.avatar_object_key:
            self.avatar_url = avatar_endpoint("users", self.id)
            self.has_custom_avatar = True
        return self


class MeResponse(BaseModel):
    identifier: str | None
    authenticated: bool
    is_admin: bool = False
    user: UserResponse | None
