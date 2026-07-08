import uuid
from datetime import date as date_type
from decimal import Decimal

from sqlalchemy import Boolean, Date, Enum, ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.models.enums import TransactionSource


class Transaction(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "transactions"

    account_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="SET NULL"), nullable=True
    )
    # Dedup key for Plaid-sourced rows; null for manual entries
    plaid_transaction_id: Mapped[str | None] = mapped_column(
        String(128), unique=True, nullable=True
    )
    # Dedup key for imported-statement rows (e.g. an OFX FITID); unique per (account_id, external_transaction_id)
    # via a partial index (FITIDs are unique per account, not globally). Null for Plaid/manual entries.
    external_transaction_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # On a posted Plaid row, the `plaid_transaction_id` of the pending charge it replaced (Plaid's value, kept
    # as a plain string - NOT a FK, since the pending row gets deleted). Lets the app point a user from a
    # since-posted pending transaction to its posted twin (`pending_transaction_id == old.plaid_transaction_id`).
    pending_transaction_id: Mapped[str | None] = mapped_column(String(128), nullable=True, index=True)
    source: Mapped[TransactionSource] = mapped_column(
        Enum(TransactionSource, name="transaction_source"), nullable=False
    )
    description: Mapped[str] = mapped_column(String(512), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    date: Mapped[date_type] = mapped_column(Date, nullable=False)
    category: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # Per-user state (category override + budget inclusion) lives in `transaction_overrides`, keyed by
    # (owner_identifier, transaction_id), so it's independent per user (future shared transactions). The
    # transactions router populates the caller's override onto the response. Plaid sync never touches it.
    # The local identifier this transaction belongs to (per-caller scoping); inherited from its account
    # (the linker) for Plaid rows, or the creator for manual ones. Null = legacy/unowned.
    owner_identifier: Mapped[str | None] = mapped_column(String(128), nullable=True)
    pending: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # Client-supplied Idempotency-Key: dedups a retried create (partial unique index on (owner_identifier,
    # client_key) via migration 0053, DB-only). Null when the caller omits the header.
    client_key: Mapped[str | None] = mapped_column(String(64), nullable=True)

    account: Mapped["Account | None"] = relationship(  # noqa: F821
        back_populates="transactions"
    )
    items: Mapped[list["TransactionItem"]] = relationship(  # noqa: F821
        back_populates="transaction", cascade="all, delete-orphan", passive_deletes=True
    )
    receipts: Mapped[list["Receipt"]] = relationship(  # noqa: F821
        back_populates="transaction", cascade="all, delete-orphan", passive_deletes=True
    )
