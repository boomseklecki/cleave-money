import uuid

from sqlalchemy import Boolean, ForeignKey, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class ExpenseOverride(UUIDMixin, TimestampMixin, Base):
    """A user's per-expense budget overrides, keyed by `(owner_identifier, expense_id)` so they're per-user - 
    independent inclusion survives a shared expense (two members of a group). The shared expense columns stay
    on `expenses`; only these analytics toggles are per-user. The expenses router attaches the caller's
    override onto the response; nothing here touches balances. A missing row means the default (included)."""

    __tablename__ = "expense_overrides"
    __table_args__ = (
        UniqueConstraint("owner_identifier", "expense_id", name="uq_expense_override_owner_expense"),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    expense_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("expenses.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # Per-user budget inclusion; null = the default (included). Excludes this expense's owed-share from
    # spending / cash-flow analytics without changing balances.
    include_in_spending: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    include_in_cash_flow: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    # Per-user free-text note - a personal annotation, never synced to Splitwise.
    note: Mapped[str | None] = mapped_column(String(500), nullable=True)
