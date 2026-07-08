from sqlalchemy import JSON, Boolean, Enum, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.models.enums import UserSource


class User(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "users"

    # Join key matching splits.user_identifier (directory, no hard FK on splits).
    identifier: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(255), nullable=False)
    source: Mapped[UserSource] = mapped_column(Enum(UserSource, name="user_source"), nullable=False)
    splitwise_user_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    email: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Splitwise registration_status: "confirmed" | "invited" | "dummy" (null for non-Splitwise users).
    registration_status: Mapped[str | None] = mapped_column(String(32), nullable=True)
    # Provider subject ids captured at sign-in (find-or-create/link key); each unique when set.
    apple_sub: Mapped[str | None] = mapped_column(String(255), unique=True, nullable=True)
    google_sub: Mapped[str | None] = mapped_column(String(255), unique=True, nullable=True)
    avatar_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    # Custom avatar in MinIO (overrides avatar_url when set). object_key = served display square,
    # original_key = full-res original kept for re-editing, crop = pinch/pan transform {scale,dx,dy}.
    avatar_object_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    avatar_original_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    avatar_content_type: Mapped[str | None] = mapped_column(String(128), nullable=True)
    avatar_crop: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    # DB-backed access: enrolled users may authenticate (replaces the .env allowlist). Set at sign-in by
    # redeeming an invite, or by claiming a fresh (no-enrolled-users) server. is_admin gates operator actions.
    enrolled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_admin: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
