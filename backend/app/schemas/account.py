from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class AccountCreate(BaseModel):
    name: str
    type: str | None = None
    balance: Decimal = Decimal(0)
    currency: str | None = None


# Allowed account-kind overrides (null = derive from the Plaid subtype).
ACCOUNT_KINDS = {"cash_flow", "liability", "savings"}


class AccountUpdate(BaseModel):
    # All overrides leave the value unchanged when omitted (applied via exclude_unset). An empty-string
    # display_name resets to Plaid's name (normalized to null in the router).
    display_name: str | None = None
    kind: str | None = None
    include_in_spending: bool | None = None
    include_in_cash_flow: bool | None = None
    # Owner-only outbound sharing toward partners: "private" | "balances" | "full" (a real account column,
    # not a per-user override).
    share_level: str | None = None


class AccountResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    # The caller's per-user overrides (from `account_overrides`); the router attaches them.
    display_name: str | None = None
    type: str | None
    kind: str | None = None
    mask: str | None
    plaid_account_id: str | None
    balance: Decimal
    available_balance: Decimal | None = None
    currency: str
    include_in_spending: bool | None = None
    include_in_cash_flow: bool | None = None
    institution_name: str | None
    institution_domain: str | None
    institution_color: str | None
    institution_status: str | None
    # Sharing: `share_level` is the owner's outbound setting on own accounts, or the level granted to the
    # caller on a shared-in account. `shared_by*` are set only on shared-in (partner-owned) accounts.
    share_level: str
    shared_by: str | None = None
    shared_by_identifier: str | None = None
    created_at: datetime
    updated_at: datetime
