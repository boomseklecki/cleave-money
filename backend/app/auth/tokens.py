"""Stateless session JWTs (HS256) issued by the backend after a provider sign-in.

No session table - mass-revoke by rotating `auth_jwt_secret`. Refresh tokens are deferred.
"""
import uuid
from datetime import datetime, timedelta, timezone

import jwt

from app.config import settings
from app.models import User

_ALGORITHM = "HS256"
_TTL = timedelta(days=90)


def issue(user: User) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user.id),
        "identifier": user.identifier,
        "iat": int(now.timestamp()),
        "exp": int((now + _TTL).timestamp()),
    }
    return jwt.encode(payload, settings.auth_jwt_secret, algorithm=_ALGORITHM)


def verify(token: str) -> uuid.UUID | None:
    """Returns the user id from a valid token, or None if it's missing/invalid/expired."""
    try:
        payload = jwt.decode(token, settings.auth_jwt_secret, algorithms=[_ALGORITHM])
    except jwt.PyJWTError:
        return None
    sub = payload.get("sub")
    try:
        return uuid.UUID(sub) if sub else None
    except (ValueError, TypeError):
        return None
