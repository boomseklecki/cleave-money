import uuid
from datetime import date as date_type
from datetime import datetime
from decimal import Decimal

from sqlalchemy import Boolean, Date, DateTime, ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Goal(UUIDMixin, TimestampMixin, Base):
    """A budgeting goal derived from Plaid data. Two kinds:
    - "spend": cap monthly spend in a canonical `category` at `target_amount` (Mint-style budget).
    - "save": grow a Plaid `account`'s balance. `save_target_type` is "balance" (reach an absolute
      balance) or "amount" (add this much); progress is measured from the `starting_balance` snapshot
      taken at creation (there is no historical balance series to look back on).
    Progress is computed client-side from cached transactions/accounts - not stored here."""

    __tablename__ = "goals"

    kind: Mapped[str] = mapped_column(String(16), nullable=False)  # "spend" | "save"
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    # The local identifier this goal belongs to (per-caller scoping); the creator. Null = legacy/unowned.
    owner_identifier: Mapped[str | None] = mapped_column(String(128), nullable=True)
    category: Mapped[str | None] = mapped_column(String(64), nullable=True)  # spend goals
    account_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="CASCADE"), nullable=True
    )  # save goals
    target_amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    save_target_type: Mapped[str | None] = mapped_column(String(16), nullable=True)  # "balance" | "amount"
    starting_balance: Mapped[Decimal | None] = mapped_column(Numeric(12, 2), nullable=True)
    starting_date: Mapped[date_type | None] = mapped_column(Date, nullable=True)
    period: Mapped[str] = mapped_column(String(16), nullable=False, default="monthly")
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Owner-set: when true, the goal is visible (read-only) to the owner's accepted connections.
    shared: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
