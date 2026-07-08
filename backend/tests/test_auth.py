"""Unit tests for the bearer-auth dependency (open vs enforced modes)."""
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials

from app.auth import require_auth
from app.config import settings


def _creds(token):
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


async def _expect_401(credentials):
    try:
        await require_auth(credentials)
    except HTTPException as exc:
        assert exc.status_code == 401
        return
    raise AssertionError("expected 401")


async def test_open_mode_allows_without_token():
    original = settings.api_tokens
    settings.api_tokens = {}
    try:
        assert await require_auth(None) is None
        # A stray token is also fine in open mode.
        assert await require_auth(_creds("anything")) is None
    finally:
        settings.api_tokens = original


async def test_enforced_rejects_missing_and_wrong():
    original = settings.api_tokens
    settings.api_tokens = {"tok-alice": "alice"}
    try:
        await _expect_401(None)
        await _expect_401(_creds("wrong-token"))
    finally:
        settings.api_tokens = original


async def test_enforced_accepts_valid_and_returns_identifier():
    original = settings.api_tokens
    settings.api_tokens = {"tok-alice": "alice", "tok-bob": "bob"}
    try:
        assert await require_auth(_creds("tok-alice")) == "alice"
        assert await require_auth(_creds("tok-bob")) == "bob"
    finally:
        settings.api_tokens = original


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
