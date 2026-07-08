from sqlalchemy import String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class NotificationMute(UUIDMixin, TimestampMixin, Base):
    """A per-owner notification preference, stored as a `"<channel>:<selector>"` token. `channel` is
    `push` (suppress device push) or `feed` (hide from the owner's Inbox view); `selector` is a
    notification `type` code (e.g. `expense_added`) or `source:<src>` (e.g. `source:splitwise`). The
    backend enforces only `push:` tokens; `feed:` tokens are persisted but interpreted by the client.
    Empty set = everything pushed + shown (opt-out model)."""

    __tablename__ = "notification_mutes"
    __table_args__ = (
        UniqueConstraint("owner_identifier", "token", name="uq_notification_mutes_owner_token"),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    token: Mapped[str] = mapped_column(String(80), nullable=False)
