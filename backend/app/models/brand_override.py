from datetime import datetime

from sqlalchemy import DateTime, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class BrandOverride(Base):
    """A server-managed merchant to logo mapping. `pattern` is matched case-insensitively against a
    transaction/expense merchant or note (the matching itself runs on-device): plain text is a substring, `*`
    and `?` are glob wildcards, and a value wrapped in slashes is a regular expression. `name` is the display
    label and `domain` drives the `/logos/{domain}` favicon (empty = name only, no logo). Admin-curated in-app
    and seeded from the app's built-in catalog by migration 0054, so a fresh install works out of the box and
    any default can be edited or deleted. `position` sets match order: the first matching pattern wins, so a
    broad pattern must sit below a more specific one."""

    __tablename__ = "brand_overrides"

    pattern: Mapped[str] = mapped_column(String(64), primary_key=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    domain: Mapped[str] = mapped_column(String(255), nullable=False, default="")
    position: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
