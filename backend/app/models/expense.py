import uuid
from datetime import date as date_type
from datetime import datetime
from decimal import Decimal

from sqlalchemy import Boolean, Date, DateTime, ForeignKey, Integer, Numeric, String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Expense(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "expenses"

    group_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("groups.id", ondelete="CASCADE"), nullable=False
    )
    # Optional link to the originating Plaid/manual transaction
    transaction_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("transactions.id", ondelete="SET NULL"), nullable=True
    )
    # Dedup key for Splitwise-synced rows; null for self-hosted-only expenses
    splitwise_expense_id: Mapped[str | None] = mapped_column(
        String(64), unique=True, nullable=True
    )
    # Client-supplied Idempotency-Key: dedups a retried create (partial unique index on (created_by,
    # client_key) via migration 0053, DB-only). Null when the caller omits the header.
    client_key: Mapped[str | None] = mapped_column(String(64), nullable=True)
    description: Mapped[str] = mapped_column(String(512), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    date: Mapped[date_type] = mapped_column(Date, nullable=False)
    category: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # Provenance from Splitwise (user_identifiers + the real added/edited timestamps, distinct from our
    # row's created_at/updated_at which track import time); null for self-hosted.
    created_by: Mapped[str | None] = mapped_column(String(128), nullable=True)
    updated_by: Mapped[str | None] = mapped_column(String(128), nullable=True)
    splitwise_created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    splitwise_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    comments_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Recurrence/bundle (display labels only - each occurrence still arrives as its own expense).
    repeats: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    repeat_interval: Mapped[str | None] = mapped_column(String(32), nullable=True)
    expense_bundle_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # Splitwise receipt image URL (remote, not our proxied bytes) + simplified repayments, both from import.
    splitwise_receipt_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    repayments: Mapped[list | None] = mapped_column(JSONB, nullable=True)

    group: Mapped["Group"] = relationship(back_populates="expenses")  # noqa: F821
    items: Mapped[list["ExpenseItem"]] = relationship(  # noqa: F821
        back_populates="expense", cascade="all, delete-orphan"
    )
    splits: Mapped[list["Split"]] = relationship(  # noqa: F821
        back_populates="expense", cascade="all, delete-orphan"
    )
    receipts: Mapped[list["Receipt"]] = relationship(  # noqa: F821
        back_populates="expense", cascade="all, delete-orphan"
    )
