from datetime import datetime

from sqlalchemy import DateTime, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class ServerSetting(Base):
    """A server-global runtime setting, keyed by `key` with a JSON-encoded `value`. Holds the admin-editable
    policy that used to live in `.env` (invite policy, hard-delete toggles, scheduler intervals, public
    hostname). The typed registry + accessors live in `app/server_settings.py`."""

    __tablename__ = "server_settings"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(Text, nullable=False)  # JSON-encoded scalar
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
