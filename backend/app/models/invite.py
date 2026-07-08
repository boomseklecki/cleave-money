from datetime import datetime

from sqlalchemy import DateTime, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Invite(UUIDMixin, TimestampMixin, Base):
    """A single-use enrollment invite. An enrolled member (admin, or any member when
    `invites_open_to_members` is on) mints one; a new person redeems it at sign-in to become enrolled.
    Valid iff `redeemed_at IS NULL AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())`."""

    __tablename__ = "invites"

    code: Mapped[str] = mapped_column(String(64), unique=True, nullable=False, index=True)
    created_by: Mapped[str] = mapped_column(String(128), nullable=False)  # issuer's identifier
    label: Mapped[str | None] = mapped_column(String(255), nullable=True)  # free note, e.g. "for Bob"
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    redeemed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    redeemed_by: Mapped[str | None] = mapped_column(String(128), nullable=True)  # enrolled user's identifier
