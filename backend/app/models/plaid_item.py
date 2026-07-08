from sqlalchemy import String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.security.crypto import EncryptedString


class PlaidItem(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "plaid_items"

    # Plaid Item = one linked bank login; owns one or more accounts.
    plaid_item_id: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    access_token: Mapped[str] = mapped_column(EncryptedString, nullable=False)  # encrypted at rest
    institution_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Institution branding cached from Plaid (institutions_get_by_id, optional metadata + status), resolved
    # once per item. `institution_domain` keys the /logos proxy + the website link.
    institution_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    institution_domain: Mapped[str | None] = mapped_column(String(255), nullable=True)
    institution_color: Mapped[str | None] = mapped_column(String(16), nullable=True)
    institution_status: Mapped[str | None] = mapped_column(String(32), nullable=True)
    # Cursor for incremental /transactions/sync; null until the first sync.
    transactions_cursor: Mapped[str | None] = mapped_column(Text, nullable=True)
    user_identifier: Mapped[str | None] = mapped_column(String(128), nullable=True)

    accounts: Mapped[list["Account"]] = relationship(  # noqa: F821
        back_populates="plaid_item", cascade="all, delete-orphan", passive_deletes=True
    )
