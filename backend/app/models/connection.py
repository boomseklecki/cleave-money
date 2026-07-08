from sqlalchemy import Enum, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.models.enums import ConnectionStatus


class Connection(UUIDMixin, TimestampMixin, Base):
    """A mutually-accepted link between two users for sharing finances (UX: "Partner"). Kept generic and
    pairwise so it extends to more members later only by widening `scope.audience()` - the one resolver every
    share read-path consults. The pair is stored unordered-unique (`requester` is just who invited)."""

    __tablename__ = "connections"
    __table_args__ = (
        UniqueConstraint("requester_identifier", "addressee_identifier", name="uq_connection_pair"),
    )

    requester_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    addressee_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    status: Mapped[ConnectionStatus] = mapped_column(
        Enum(ConnectionStatus, name="connection_status"), nullable=False,
        default=ConnectionStatus.pending,
    )
