from pydantic import BaseModel

from app.schemas.user import UserResponse


class AppleAuthRequest(BaseModel):
    identity_token: str
    # Apple only sends the name on first consent; the client forwards it here when present.
    full_name: str | None = None
    # Single-use enrollment invite captured from a join link; required for a NEW user on a claimed server.
    invite: str | None = None


class GoogleAuthRequest(BaseModel):
    id_token: str
    invite: str | None = None  # single-use enrollment invite (see AppleAuthRequest.invite)


class DemoAuthRequest(BaseModel):
    display_name: str | None = None  # optional; a friendly name for the guest, no email/OAuth


class AuthResponse(BaseModel):
    token: str
    user: UserResponse


class SplitwiseAuthStart(BaseModel):
    # The Splitwise authorize URL to open; the OAuth state is bound to the authenticated caller server-side.
    authorize_url: str
