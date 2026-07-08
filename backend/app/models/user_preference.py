from sqlalchemy import String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class UserPreference(UUIDMixin, TimestampMixin, Base):
    """A per-owner client preference blob, keyed by a string `key` and holding an opaque JSON `value`
    (a string the app encodes/versions itself). Scoped to the caller's `owner_identifier`, so users
    sharing a backend keep independent preferences. Used to back up locally-authoritative settings - 
    e.g. suggestion templates/decisions (`suggestions.v1`) or tab order - so they survive a new device. The
    backend never interprets `value`; it only stores and returns it. (Categories used to live here under
    `categories.v1`; they moved to the relational `/categories` store, blob retired in migration 0049.)"""

    __tablename__ = "user_preferences"
    __table_args__ = (UniqueConstraint("owner_identifier", "key", name="uq_user_preferences_owner_key"),)

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    key: Mapped[str] = mapped_column(String(64), nullable=False)
    value: Mapped[str] = mapped_column(Text, nullable=False)
