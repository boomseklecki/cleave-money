import uuid

from sqlalchemy import CheckConstraint, ForeignKey, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Receipt(UUIDMixin, TimestampMixin, Base):
    """A receipt image, owned by exactly one of an expense or a transaction (polymorphic; the check constraint
    enforces exactly-one). Bytes live in MinIO; the app fetches via GET /receipts/{id}/content."""

    __tablename__ = "receipts"
    __table_args__ = (
        CheckConstraint(
            "(expense_id IS NULL) <> (transaction_id IS NULL)",
            name="receipts_expense_xor_transaction",
        ),
    )

    expense_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("expenses.id", ondelete="CASCADE"), nullable=True
    )
    transaction_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("transactions.id", ondelete="CASCADE"), nullable=True
    )
    # MinIO object reference; the app fetches bytes via the API (GET /receipts/{id}/content)
    bucket: Mapped[str] = mapped_column(String(128), nullable=False)
    object_key: Mapped[str] = mapped_column(String(512), nullable=False)
    content_type: Mapped[str | None] = mapped_column(String(128), nullable=True)

    expense: Mapped["Expense | None"] = relationship(back_populates="receipts")  # noqa: F821
    transaction: Mapped["Transaction | None"] = relationship(back_populates="receipts")  # noqa: F821
