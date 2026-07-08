from datetime import date as date_type
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, field_validator

from app.models.enums import TransactionSource
from app.schemas.receipt import ReceiptResponse


class TransactionItemInput(BaseModel):
    id: UUID | None = None  # existing item to update in place (preserves added-by/on); null = new
    name: str
    quantity: Decimal = Decimal(1)
    price: Decimal
    category: str | None = None


class TransactionItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    quantity: Decimal
    price: Decimal
    category: str | None
    created_by: str | None
    updated_by: str | None
    created_at: datetime
    updated_at: datetime


class TransactionCreate(BaseModel):
    account_id: UUID | None = None
    description: str
    amount: Decimal
    currency: str | None = None
    date: date_type
    category: str | None = None
    pending: bool = False


class TransactionUpdate(BaseModel):
    # Per-transaction canonical category override; null clears it (revert to the label map/auto).
    category_override: str | None = None


class TransactionOverrideUpdate(BaseModel):
    # The caller's per-user budget overrides (in `transaction_overrides`). Only provided fields change; null
    # clears that field (revert to the account default). Toggles, never touch balances.
    include_in_spending: bool | None = None
    include_in_cash_flow: bool | None = None
    # The on-device AI category refinement to mirror server-side (provenance .aiRefined). Synced through this
    # row so other devices inherit it; distinct from the explicit `category_override`.
    refined_category: str | None = None
    # Per-user free-text note. The client always sends it on a note edit (blank to clear); a blank value
    # normalizes to None so the drop-guard can retire an empty override row.
    note: str | None = None

    @field_validator("note")
    @classmethod
    def _blank_note_is_none(cls, v: str | None) -> str | None:
        return v.strip() or None if v is not None else None


class TransactionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    account_id: UUID | None
    plaid_transaction_id: str | None
    # On a posted row, the pending charge's plaid id it replaced (lets the app link to a since-posted pending).
    pending_transaction_id: str | None = None
    source: TransactionSource
    description: str
    amount: Decimal
    currency: str
    date: date_type
    category: str | None
    # The caller's per-user overrides (from `transaction_overrides`); the router attaches them. null = default.
    category_override: str | None = None
    include_in_spending: bool | None = None
    include_in_cash_flow: bool | None = None
    # The on-device AI refinement mirrored from `transaction_overrides` (provenance .aiRefined). null = none.
    refined_category: str | None = None
    # The caller's per-user free-text note (from `transaction_overrides`). null = none.
    note: str | None = None
    pending: bool
    # The id of the expense linked to this transaction (reverse of `expense.transaction_id`), if any - lets the
    # client resolve the linked expense directly instead of scanning its (possibly-evicted) local cache. The
    # router attaches it. null = not linked.
    linked_expense_id: UUID | None = None
    items: list[TransactionItemResponse] = []
    receipts: list[ReceiptResponse] = []
    created_at: datetime
    updated_at: datetime
