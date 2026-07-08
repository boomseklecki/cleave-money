import uuid
from decimal import Decimal

from sqlalchemy import ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class ExpenseItem(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "expense_items"

    expense_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("expenses.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    quantity: Mapped[Decimal] = mapped_column(Numeric(10, 3), nullable=False, default=1)
    price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    category: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # Budget attribution: the participant this item is assigned to (null = shared/split).
    owner_identifier: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Provenance (added-by / edited-by; added-on / edited-on are created_at / updated_at).
    created_by: Mapped[str | None] = mapped_column(String(255), nullable=True)
    updated_by: Mapped[str | None] = mapped_column(String(255), nullable=True)

    expense: Mapped["Expense"] = relationship(back_populates="items")  # noqa: F821
