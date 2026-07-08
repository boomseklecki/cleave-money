from datetime import datetime

from sqlalchemy import DateTime, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.security.crypto import EncryptedString


class SimpleFinConnection(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "simplefin_connections"

    # One claimed SimpleFIN Access URL = one credential that can span several institutions; it owns the
    # accounts it returns. The Access URL embeds HTTP Basic-Auth creds, so it's encrypted at rest (like
    # PlaidItem.access_token). Institution branding is per-account (from each account's `org`), not here.
    access_url: Mapped[str] = mapped_column(EncryptedString, nullable=False)
    # HEALTHY / NEEDS_REAUTH (403) / PAYMENT_REQUIRED (402); null until first sync. `error` holds the detail.
    status: Mapped[str | None] = mapped_column(String(32), nullable=True)
    error: Mapped[str | None] = mapped_column(String(512), nullable=True)
    # SimpleFIN has no cursor - we poll a date window. Null = never synced -> initial backfill.
    last_synced_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    user_identifier: Mapped[str | None] = mapped_column(String(128), nullable=True)

    accounts: Mapped[list["Account"]] = relationship(  # noqa: F821
        back_populates="simplefin_connection", cascade="all, delete-orphan", passive_deletes=True
    )
