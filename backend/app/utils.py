import re
from datetime import datetime, timezone


def slugify(name: str) -> str:
    """A lowercase alphanumeric identifier derived from a display name."""
    slug = re.sub(r"[^a-z0-9]+", "", name.lower())
    return slug or "user"


def ensure_utc(value: datetime | None) -> datetime | None:
    """Treat a naive datetime as UTC so it compares cleanly against timestamptz."""
    if value is not None and value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value
