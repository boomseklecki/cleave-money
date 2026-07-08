import uuid

from sqlalchemy import Boolean, ForeignKey, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class AccountOverride(UUIDMixin, TimestampMixin, Base):
    """A user's per-account overrides, keyed by `(owner_identifier, account_id)` so they're per-user - 
    independent name/classification/inclusion survive a future shared account (one Plaid account viewed by two
    users). The Plaid-sourced columns (name/type/balance/currency/mask/institution_*) stay on `accounts`; only
    these client overrides are per-user. The accounts router attaches the caller's override onto the response.
    Plaid sync never touches them (they live in their own table)."""

    __tablename__ = "account_overrides"
    __table_args__ = (
        UniqueConstraint("owner_identifier", "account_id", name="uq_account_override_owner_account"),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    account_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # User-set display name overriding Plaid's `name`; null = show `name`.
    display_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Classification override ("cash_flow" | "liability" | "savings"); null = derive from the Plaid subtype.
    kind: Mapped[str | None] = mapped_column(String(16), nullable=True)
    # Goals-analytics inclusion overrides; null = derive from the classification.
    include_in_spending: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    include_in_cash_flow: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
