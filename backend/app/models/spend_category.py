from sqlalchemy import Boolean, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class SpendCategory(UUIDMixin, TimestampMixin, Base):
    """A user's category taxonomy entry, keyed by `(owner_identifier, name)`. The per-owner relational home
    of what used to ride the opaque `categories.v1` preferences blob - so the backend can resolve and reason
    about categories (server-side spend/budgets). Device-authoritative: the app owns the taxonomy and
    set-replaces it via `PUT /categories`."""

    __tablename__ = "spend_categories"
    __table_args__ = (
        UniqueConstraint("owner_identifier", "name", name="uq_spend_categories_owner_name"),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    name: Mapped[str] = mapped_column(String(64), nullable=False)
    builtin: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    position: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    icon: Mapped[str | None] = mapped_column(String(64), nullable=True)
    color: Mapped[str | None] = mapped_column(String(32), nullable=True)  # hex like "#34C759"
