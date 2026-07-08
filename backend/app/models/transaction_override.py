import uuid

from sqlalchemy import Boolean, ForeignKey, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class TransactionOverride(UUIDMixin, TimestampMixin, Base):
    """A user's per-transaction overrides, keyed by `(owner_identifier, transaction_id)` so they're per-user - 
    independent state survives a future shared transaction (a shared bank account viewed by two users). Holds
    the canonical-category override and the per-user budget-inclusion toggles. The base transaction columns
    stay on `transactions`; Plaid sync never touches this table. A row exists while any field is set."""

    __tablename__ = "transaction_overrides"
    __table_args__ = (
        UniqueConstraint("owner_identifier", "transaction_id", name="uq_txn_override_owner_txn"),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    transaction_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("transactions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # Canonical-category override applied over the local label map; null = auto.
    category: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # Per-transaction on-device AI refinement (provenance .aiRefined) for vague rows - synced so a
    # non-AI-capable device inherits it. Distinct from `category` (the explicit user override): read at a
    # lower precedence rank and never promoted to override.
    refined_category: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # Per-user budget inclusion; null = the default (derive from the account). Excludes this transaction from
    # spending / cash-flow analytics.
    include_in_spending: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    include_in_cash_flow: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    # Per-user free-text note - a personal annotation (e.g. "Apple" → "Duolingo subscription"). Never synced
    # to Splitwise; survives Plaid/Splitwise resync since it lives here, not on the base row.
    note: Mapped[str | None] = mapped_column(String(500), nullable=True)
