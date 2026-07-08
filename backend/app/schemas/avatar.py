from pydantic import BaseModel

from app.schemas.user import AvatarCrop


class AvatarResponse(BaseModel):
    """Returned after an avatar upload/delete so the client gets the resolved URL without a re-fetch."""
    avatar_url: str | None
    has_custom_avatar: bool
    avatar_crop: AvatarCrop | None = None
