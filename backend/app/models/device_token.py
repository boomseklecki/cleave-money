from sqlalchemy import String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class DeviceToken(UUIDMixin, TimestampMixin, Base):
    """An APNs device token registered for a user's push notifications. Unique per (user, token)."""

    __tablename__ = "device_tokens"
    __table_args__ = (UniqueConstraint("user_identifier", "token", name="uq_device_token"),)

    user_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    token: Mapped[str] = mapped_column(String(256), nullable=False)
    platform: Mapped[str] = mapped_column(String(16), nullable=False, default="ios")
    # Base64 X9.63 (uncompressed-point) P-256 public key for ECIES push sealing (see services/crypto_push).
    # Nullable: older app builds register without one and get plaintext pushes (back-compat).
    public_key: Mapped[str | None] = mapped_column(String(128), nullable=True)
