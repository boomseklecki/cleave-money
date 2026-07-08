import uuid
from datetime import date as date_type
from decimal import Decimal

from sqlalchemy import Date, Enum, ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.models.enums import ShareLevel, TransactionSource


class Account(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "accounts"

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    # Per-user overrides (display_name, kind, include_in_spending, include_in_cash_flow) live in
    # `account_overrides`, keyed by (owner_identifier, account_id) so they're independent per user (future
    # shared accounts). The accounts router attaches the caller's override onto the response. Plaid sync only
    # touches name/type/balance/currency/mask/institution_* - see plaid/sync.py _upsert_account.
    # Plaid account type/subtype (e.g. depository/checking); free-form for now
    type: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # The account number's last few digits (Plaid `mask`), for display on the account row; null for manual.
    mask: Mapped[str | None] = mapped_column(String(32), nullable=True)
    plaid_account_id: Mapped[str | None] = mapped_column(String(128), unique=True, nullable=True)
    # Set for Plaid-linked accounts; null for manual ones
    plaid_item_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("plaid_items.id", ondelete="CASCADE"), nullable=True
    )
    # SimpleFIN linkage (the second aggregator): set for SimpleFIN-synced accounts, null otherwise.
    # simplefin_account_id is SimpleFIN's per-connection-unique account id; the sync upsert key is the pair
    # (simplefin_connection_id, simplefin_account_id). Branding reuses institution_name/domain below, filled
    # from each SimpleFIN account's `org`.
    simplefin_account_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    simplefin_connection_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("simplefin_connections.id", ondelete="CASCADE"), nullable=True
    )
    balance: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False, default=0)
    # Available balance / credit (Plaid `balances.available`; OFX `<AVAILBAL>`). Null when unknown.
    available_balance: Mapped[Decimal | None] = mapped_column(Numeric(12, 2), nullable=True)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    # Stable account id from an imported statement (OFX `<ACCTID>`) - the find-or-create / dedup key for
    # statement imports. Null for Plaid/manual accounts. The statement date the cached balance reflects.
    external_account_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    balance_as_of: Mapped[date_type | None] = mapped_column(Date, nullable=True)
    # The local identifier this account belongs to (per-caller scoping). For Plaid accounts this is the
    # linker (plaid_items.user_identifier); for manual accounts, the creator. Null = legacy/unowned.
    owner_identifier: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # Owner-set visibility toward the owner's accepted connections (partners): private (default) / balances /
    # full. Not a per-user override (it's the owner's outbound choice); Plaid sync never touches it.
    share_level: Mapped[ShareLevel] = mapped_column(
        Enum(ShareLevel, name="share_level"), nullable=False, default=ShareLevel.private
    )
    # Institution branding denormalized from the account's PlaidItem (so AccountResponse carries it without a
    # join). Refreshed on each Plaid sync; null for manual accounts.
    institution_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    institution_domain: Mapped[str | None] = mapped_column(String(255), nullable=True)
    institution_color: Mapped[str | None] = mapped_column(String(16), nullable=True)
    institution_status: Mapped[str | None] = mapped_column(String(32), nullable=True)
    # Cross-source merge (same real-world account reached via >1 source). NULL = a normal single-source account
    # (its one linkage feeds it, unchanged). When set, ONLY this source writes balance + transactions; the
    # other linked sources are recognized-but-suppressed (so they don't re-create a duplicate). `merged_from_date`
    # is the feed boundary: the primary only imports transactions dated AFTER it, so the preserved history from
    # the other source isn't re-imported/duplicated (uniform feed-forward). See the merge endpoint + SPEC.
    primary_source: Mapped[TransactionSource | None] = mapped_column(
        Enum(TransactionSource, name="transaction_source"), nullable=True
    )
    merged_from_date: Mapped[date_type | None] = mapped_column(Date, nullable=True)

    plaid_item: Mapped["PlaidItem | None"] = relationship(  # noqa: F821
        back_populates="accounts"
    )
    simplefin_connection: Mapped["SimpleFinConnection | None"] = relationship(  # noqa: F821
        back_populates="accounts"
    )
    transactions: Mapped[list["Transaction"]] = relationship(  # noqa: F821
        back_populates="account"
    )
