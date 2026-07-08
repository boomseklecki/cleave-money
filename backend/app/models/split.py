import uuid
from decimal import Decimal

from sqlalchemy import ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Split(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "splits"

    expense_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("expenses.id", ondelete="CASCADE"), nullable=False
    )
    # Person identifier (e.g. "alice", "bob"); maps to Splitwise user on synced groups
    user_identifier: Mapped[str] = mapped_column(String(128), nullable=False)
    paid_share: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False, default=0)
    owed_share: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False, default=0)

    expense: Mapped["Expense"] = relationship(back_populates="splits")  # noqa: F821
