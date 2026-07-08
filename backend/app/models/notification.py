from datetime import datetime

from sqlalchemy import Boolean, DateTime, Enum, Index, String, Text, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import UUIDMixin
from app.models.enums import NotificationSource


class Notification(UUIDMixin, Base):
    """A per-owner notification, generic over its origin. `source=splitwise` rows are pulled from
    Splitwise's getNotifications and deduped by `splitwise_id`; `source=app` is reserved for a future
    in-app notification feature. Capped per owner to `notifications_retention_count` (server setting)."""

    __tablename__ = "notifications"
    __table_args__ = (
        # Dedup Splitwise notifications per owner; `app` rows (no splitwise_id) are exempt.
        Index(
            "uq_notifications_owner_source_swid",
            "owner_identifier",
            "source",
            "splitwise_id",
            unique=True,
            postgresql_where=text("splitwise_id IS NOT NULL"),
        ),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False)
    source: Mapped[NotificationSource] = mapped_column(
        Enum(NotificationSource, name="notification_source"), nullable=False
    )
    # Splitwise notification id (null for app-generated rows).
    splitwise_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # Splitwise notification type code / app event type.
    type: Mapped[str | None] = mapped_column(String(32), nullable=True)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    # Deep-link target for app-native rows: what entity this is about + its id (a UUID string for
    # expense/account/goal/group, or a friend identifier for connections). Null for Splitwise-synced rows.
    entity_type: Mapped[str | None] = mapped_column(String(32), nullable=True)
    entity_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    read: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # Per-owner hide: the owner swiped this row away. Filtered from their feed; preserved across re-sync
    # (the Splitwise upsert never touches it). Each row is per-owner, so this affects only their feed.
    hidden: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default=text("false"), default=False)
