from sqlalchemy import String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Friend(UUIDMixin, TimestampMixin, Base):
    """A cached Splitwise friend of a token owner. Splitwise friends exist independently of shared
    groups, so this fills the gap where a friend with no shared group has no cached name/avatar (the
    `users` directory is only populated from group members + expense participants). Balances stay
    live via `/balances/friends` (getFriends) - this caches identity only. `updated_at` is the last
    sync time (the freshness signal smart-refresh reads)."""

    __tablename__ = "friends"
    __table_args__ = (
        UniqueConstraint("owner_identifier", "splitwise_friend_id", name="uq_friends_owner_friend"),
    )

    # Whose friend list this row belongs to (the SplitwiseToken user_identifier).
    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False)
    splitwise_friend_id: Mapped[str] = mapped_column(String(64), nullable=False)
    # The local user identifier this friend resolves to (matches users.identifier / splits), when known.
    identifier: Mapped[str | None] = mapped_column(String(128), nullable=True)
    first_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    last_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    email: Mapped[str | None] = mapped_column(String(255), nullable=True)
    avatar_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
