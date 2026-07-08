import uuid
from datetime import date as date_type

from sqlalchemy import Date, ForeignKey, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class GoalBudgetNotification(UUIDMixin, TimestampMixin, Base):
    """Marker that a budget push already fired for a (goal, month, threshold), so the post-sync hook notifies
    **once** per period instead of every sync. `kind` is "nearing" (≥85%) or "over" (>100%); crossing from
    nearing→over fires a second (distinct-kind) notification, but never repeats the same one."""

    __tablename__ = "goal_budget_notifications"
    __table_args__ = (
        UniqueConstraint("goal_id", "period_month", "kind", name="uq_goal_budget_notif"),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    goal_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("goals.id", ondelete="CASCADE"), nullable=False, index=True
    )
    period_month: Mapped[date_type] = mapped_column(Date, nullable=False)  # first-of-month
    kind: Mapped[str] = mapped_column(String(16), nullable=False)  # "nearing" | "over"
