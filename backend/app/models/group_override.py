import uuid

from sqlalchemy import Boolean, ForeignKey, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class GroupOverride(UUIDMixin, TimestampMixin, Base):
    """A user's per-group overrides, keyed by `(owner_identifier, group_id)` so they're per-user - two members
    of a shared group can hide it independently. The shared/sourced group columns (name, backend_type,
    splitwise_*, superseded_at, ...) stay on `groups`; only these per-user toggles live here. The
    groups router attaches the caller's override onto the response and filters the list by it. A missing row
    means the default (`hidden = False`)."""

    __tablename__ = "group_overrides"
    __table_args__ = (
        UniqueConstraint("owner_identifier", "group_id", name="uq_group_override_owner_group"),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    group_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("groups.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # Cosmetic per-user visibility toggle; null/absent row = the default False (shown). Reserved for a future
    # "declutter my view" feature - not yet surfaced in the UI.
    hidden: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    # Per-user budget inclusion: drop this group's owed-shares from spending / cash-flow analytics without
    # touching balances (e.g. money set aside for a Trip). null = the default (included).
    include_in_spending: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    include_in_cash_flow: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
