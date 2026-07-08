"""Session JWT issue/verify round-trip and rejection of tampered/expired tokens."""
import uuid
from datetime import datetime, timedelta, timezone

import jwt as pyjwt

from app.auth import tokens
from app.config import settings
from app.models import User
from app.models.enums import UserSource

_SECRET = "test-jwt-secret-abc123"


def _user() -> User:
    user = User(identifier="jwtuser", display_name="JWT User", source=UserSource.app)
    user.id = uuid.uuid4()
    return user


def test_issue_verify_round_trip():
    original = settings.auth_jwt_secret
    settings.auth_jwt_secret = _SECRET
    try:
        user = _user()
        token = tokens.issue(user)
        assert tokens.verify(token) == user.id
    finally:
        settings.auth_jwt_secret = original


def test_rejects_tampered_signature():
    original = settings.auth_jwt_secret
    settings.auth_jwt_secret = _SECRET
    try:
        token = tokens.issue(_user())
        settings.auth_jwt_secret = _SECRET + "-different"
        assert tokens.verify(token) is None
    finally:
        settings.auth_jwt_secret = original


def test_rejects_expired():
    original = settings.auth_jwt_secret
    settings.auth_jwt_secret = _SECRET
    try:
        past = datetime.now(timezone.utc) - timedelta(days=1)
        token = pyjwt.encode(
            {"sub": str(uuid.uuid4()), "exp": int(past.timestamp())}, _SECRET, algorithm="HS256"
        )
        assert tokens.verify(token) is None
    finally:
        settings.auth_jwt_secret = original


def test_rejects_garbage():
    original = settings.auth_jwt_secret
    settings.auth_jwt_secret = _SECRET
    try:
        assert tokens.verify("not-a-jwt") is None
    finally:
        settings.auth_jwt_secret = original


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
