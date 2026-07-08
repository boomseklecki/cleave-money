from datetime import date as date_type
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, field_validator

from app.schemas.receipt import ReceiptResponse


class SplitInput(BaseModel):
    user_identifier: str
    paid_share: Decimal
    owed_share: Decimal


class ItemInput(BaseModel):
    id: UUID | None = None  # existing item to update in place (preserves added-by/on); null = new
    name: str
    quantity: Decimal = Decimal(1)
    price: Decimal
    category: str | None = None
    owner_identifier: str | None = None


class ExpenseCreate(BaseModel):
    group_id: UUID
    description: str
    amount: Decimal
    currency: str | None = None
    date: date_type
    category: str | None = None
    notes: str | None = None
    created_by: str | None = None  # who added it (the app sends the signed-in user)
    transaction_id: UUID | None = None
    splits: list[SplitInput] = []
    items: list[ItemInput] = []


class ExpenseUpdate(BaseModel):
    group_id: UUID | None = None
    description: str | None = None
    amount: Decimal | None = None
    currency: str | None = None
    date: date_type | None = None
    category: str | None = None
    notes: str | None = None
    updated_by: str | None = None  # who edited it (the app sends the signed-in user)
    transaction_id: UUID | None = None
    splits: list[SplitInput] | None = None
    items: list[ItemInput] | None = None


class ExpenseTransactionLink(BaseModel):
    # Set to link this expense to a bank/manual transaction (dedupes the gross transaction in spending in
    # favor of your owed share), or null to unlink. A local-only field - never pushed to Splitwise.
    transaction_id: UUID | None = None


class ExpenseOverrideUpdate(BaseModel):
    # The caller's per-user budget overrides (in `expense_overrides`). Only provided fields change; null
    # clears that field (revert to the default = included). Never touches balances or other users.
    include_in_spending: bool | None = None
    include_in_cash_flow: bool | None = None
    # Per-user free-text note (personal annotation, never synced to Splitwise). Blank normalizes to None so an
    # empty override row is dropped.
    note: str | None = None

    @field_validator("note")
    @classmethod
    def _blank_note_is_none(cls, v: str | None) -> str | None:
        return v.strip() or None if v is not None else None


class SplitResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_identifier: str
    paid_share: Decimal
    owed_share: Decimal


class ItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    quantity: Decimal
    price: Decimal
    category: str | None
    owner_identifier: str | None
    created_by: str | None
    updated_by: str | None
    created_at: datetime
    updated_at: datetime


class ExpenseResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    group_id: UUID
    transaction_id: UUID | None
    splitwise_expense_id: str | None
    description: str
    amount: Decimal
    currency: str
    date: date_type
    category: str | None
    created_by: str | None
    updated_by: str | None
    splitwise_created_at: datetime | None
    splitwise_updated_at: datetime | None
    notes: str | None
    comments_count: int | None
    repeats: bool | None
    repeat_interval: str | None
    expense_bundle_id: str | None
    splitwise_receipt_url: str | None
    repayments: list | None
    # The caller's per-user budget overrides (from `expense_overrides`); the router attaches them. null = default.
    include_in_spending: bool | None = None
    include_in_cash_flow: bool | None = None
    # The caller's per-user free-text note (from `expense_overrides`). null = none.
    note: str | None = None
    created_at: datetime
    updated_at: datetime
    splits: list[SplitResponse] = []
    items: list[ItemResponse] = []
    receipts: list[ReceiptResponse] = []
