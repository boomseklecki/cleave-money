from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from app.schemas.account import AccountResponse


class PlaidItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    plaid_item_id: str
    institution_name: str | None
    institution_domain: str | None
    institution_color: str | None
    institution_status: str | None
    user_identifier: str | None
    accounts: list[AccountResponse] = []
    created_at: datetime
    updated_at: datetime


class LinkTokenRequest(BaseModel):
    user_identifier: str = "alice"


class LinkTokenResponse(BaseModel):
    link_token: str


class ExchangeRequest(BaseModel):
    public_token: str
    user_identifier: str = "alice"
    institution_name: str | None = None


class ExchangeResponse(BaseModel):
    item_id: UUID
    plaid_item_id: str
    accounts: list[AccountResponse]


class SyncRequest(BaseModel):
    item_id: UUID | None = None
    # When true, clears the saved cursor first so transactions are re-pulled from scratch (used to
    # backfill fields like category after a mapping change).
    reset: bool = False


class SyncResponse(BaseModel):
    items_synced: int
    accounts: int
    added: int
    modified: int
    removed: int
