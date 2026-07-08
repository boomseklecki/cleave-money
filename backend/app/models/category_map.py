from sqlalchemy import String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class CategoryMap(UUIDMixin, TimestampMixin, Base):
    """A user's raw→canonical category mapping, keyed by `(owner_identifier, raw_category)`. The per-owner
    relational home of the `maps` array that used to ride the `categories.v1` blob. `source` distinguishes a
    hand-mapped entry ("manual") from one the on-device AI wrote ("ondevice") - surfaced as provenance and
    consulted by the server-side resolver above the built-in Plaid/Splitwise tables."""

    __tablename__ = "category_maps"
    __table_args__ = (
        UniqueConstraint("owner_identifier", "raw_category", name="uq_category_maps_owner_raw"),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    raw_category: Mapped[str] = mapped_column(String(128), nullable=False)
    canonical_category: Mapped[str] = mapped_column(String(64), nullable=False)
    source: Mapped[str] = mapped_column(String(16), nullable=False, default="manual")
