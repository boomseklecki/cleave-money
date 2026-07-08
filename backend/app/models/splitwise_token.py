from datetime import datetime

from sqlalchemy import DateTime, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.security.crypto import EncryptedString


class SplitwiseToken(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "splitwise_tokens"

    # Local identifier the token belongs to (e.g. "alice")
    user_identifier: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    access_token: Mapped[str] = mapped_column(EncryptedString, nullable=False)  # encrypted at rest
    token_type: Mapped[str] = mapped_column(String(32), nullable=False, default="bearer")
    scope: Mapped[str | None] = mapped_column(String(256), nullable=True)
    # Incremental-sync cursor: start time of the last successful expense sync; the next sync
    # passes updated_after=this. Null until the first import/sync stamps it.
    expenses_synced_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Push watermark: the newest Splitwise notification `created_at` already accounted for. Only items
    # strictly newer push; advanced every sync. Null = first sync (no push). Decoupled from the storage prune.
    notifications_pushed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
