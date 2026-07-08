from datetime import datetime

from sqlalchemy import JSON, DateTime, Enum, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.models.enums import BackendType


class Group(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "groups"

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    backend_type: Mapped[BackendType] = mapped_column(
        Enum(BackendType, name="backend_type"), nullable=False
    )
    # Set only when backend_type == splitwise
    splitwise_group_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # Splitwise group metadata (null for self-hosted / unknown). group_type: apartment/house/trip/etc.
    group_type: Mapped[str | None] = mapped_column(String(32), nullable=True)
    avatar_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    cover_photo_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    # Custom avatar in MinIO (overrides avatar_url when set), member-only. object_key = served display
    # square, original_key = full-res original kept for re-editing, crop = pinch/pan transform {scale,dx,dy}.
    avatar_object_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    avatar_original_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    avatar_content_type: Mapped[str | None] = mapped_column(String(128), nullable=True)
    avatar_crop: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    # Internal "superseded by local import" marker (set only by import_group_local, so its expenses stop
    # counting after they've been cloned to a self-hosted group). NOT a user-facing archive; null = active.
    superseded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # "Deleted on Splitwise but restorable" marker: a Splitwise group deleted through the app keeps its shared
    # row (+ members) flagged so any member can restore it (Splitwise supports undelete). null = active.
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Note: the per-user `hidden` visibility toggle now lives in `group_overrides` (per (owner, group)).

    expenses: Mapped[list["Expense"]] = relationship(  # noqa: F821
        back_populates="group", cascade="all, delete-orphan", passive_deletes=True
    )
