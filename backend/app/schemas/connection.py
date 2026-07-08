from uuid import UUID

from pydantic import BaseModel


class ConnectionCreate(BaseModel):
    # Invite a partner by their email or local identifier (exactly one). They must already be an enrolled user.
    identifier: str | None = None
    email: str | None = None


class ConnectionResponse(BaseModel):
    id: UUID
    other_identifier: str
    other_display_name: str
    other_avatar_url: str | None = None
    direction: str  # "incoming" (they invited you) | "outgoing" (you invited them)
    status: str     # "pending" | "accepted"
