import uuid
from decimal import Decimal

from sqlalchemy import ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class TransactionItem(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "transaction_items"

    transaction_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("transactions.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    quantity: Mapped[Decimal] = mapped_column(Numeric(10, 3), nullable=False, default=1)
    price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    category: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # Provenance (added-by / edited-by; added-on / edited-on are created_at / updated_at). No owner - 
    # a transaction is wholly the viewer's, so items count at full price under their category.
    created_by: Mapped[str | None] = mapped_column(String(255), nullable=True)
    updated_by: Mapped[str | None] = mapped_column(String(255), nullable=True)

    transaction: Mapped["Transaction"] = relationship(back_populates="items")  # noqa: F821
