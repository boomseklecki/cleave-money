from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class ReceiptResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    # Exactly one is set - the receipt is owned by an expense or a transaction.
    expense_id: UUID | None = None
    transaction_id: UUID | None = None
    bucket: str
    object_key: str
    content_type: str | None
    created_at: datetime
