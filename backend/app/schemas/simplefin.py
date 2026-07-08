from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from app.models.enums import TransactionSource
from app.schemas.account import AccountResponse


class SimpleFinCandidate(BaseModel):
    """An existing (Plaid/OFX/manual) account a just-connected SimpleFIN account might duplicate."""
    account_id: UUID
    name: str
    institution_name: str | None = None
    institution_domain: str | None = None
    mask: str | None = None
    source: str            # the existing account's source: "plaid" | "manual" (OFX imports are manual)
    strong: bool = False   # institution + last-4 both match (vs institution-only)


class SimpleFinAccountMatch(BaseModel):
    """A newly-created SimpleFIN account plus the existing accounts it may duplicate (for the resolve sheet)."""
    account_id: UUID
    name: str
    institution_domain: str | None = None
    mask: str | None = None
    candidates: list[SimpleFinCandidate]


class SimpleFinConnectRequest(BaseModel):
    setup_token: str


class SimpleFinConnectionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    status: str | None
    error: str | None
    last_synced_at: datetime | None
    user_identifier: str | None
    accounts: list[AccountResponse] = []
    created_at: datetime
    updated_at: datetime


class SimpleFinConnectResponse(BaseModel):
    connection_id: UUID
    status: str | None
    error: str | None
    accounts: list[AccountResponse]
    warnings: list[str] = []  # SimpleFIN errlist / quota notices; always shown to the user
    matches: list[SimpleFinAccountMatch] = []  # accounts that may duplicate existing ones -> the resolve sheet


class SimpleFinMergeRequest(BaseModel):
    incoming_account_id: UUID           # the just-connected SimpleFIN account to fold in
    target_account_id: UUID             # the existing account to keep
    primary_source: TransactionSource   # which source feeds the merged account going forward


class SimpleFinMaskRequest(BaseModel):
    mask: str | None = None             # last-4 to set on a SimpleFIN account (null clears it)


class SimpleFinSyncRequest(BaseModel):
    connection_id: UUID | None = None


class SimpleFinSyncResponse(BaseModel):
    connections_synced: int
    skipped_fresh: int  # connections skipped because they were synced within the quota-protecting window
    accounts: int
    transactions: int
    reaped: int
    warnings: list[str] = []
