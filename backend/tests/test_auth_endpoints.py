"""Sign-in endpoints + require_auth enforcement, exercised in-process.

The verifiers are monkeypatched (no live JWKS); the router functions are called directly with a
real DB session (the running server is a separate process, so HTTP-level mocking wouldn't apply).
"""
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy import delete

from app.auth import require_auth, tokens
from app.auth.identity import resolve_user
from app.config import settings
from app.db import async_session
from app.integrations.auth import ProviderVerificationError, apple, google
from app.models import User
from app.routers.auth import auth_apple, auth_google
from app.schemas.auth import AppleAuthRequest, GoogleAuthRequest

_SECRET = "test-endpoint-secret"
APPLE_EMAIL = "endpoint-apple@example.com"
GOOGLE_EMAIL = "endpoint-google@example.com"
RA_EMAIL = "endpoint-ra@example.com"


def _creds(token):
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


async def _purge(*emails):
    async with async_session() as session:
        for email in emails:
            await session.execute(delete(User).where(User.email == email))
        await session.commit()


async def test_apple_signin_issues_jwt():
    original = settings.auth_jwt_secret
    settings.auth_jwt_secret = _SECRET
    orig = apple.verify_identity_token
    apple.verify_identity_token = lambda tok: {"sub": "apple-endpoint", "email": APPLE_EMAIL}
    await _purge(APPLE_EMAIL)
    try:
        async with async_session() as session:
            resp = await auth_apple(
                AppleAuthRequest(identity_token="ignored", full_name="Apple Endpoint"), session
            )
        assert resp.user.email == APPLE_EMAIL
        assert tokens.verify(resp.token) == resp.user.id
    finally:
        apple.verify_identity_token = orig
        settings.auth_jwt_secret = original
        await _purge(APPLE_EMAIL)


async def test_google_signin_issues_jwt():
    original = settings.auth_jwt_secret
    settings.auth_jwt_secret = _SECRET
    orig = google.verify_id_token
    google.verify_id_token = lambda tok: {
        "sub": "google-endpoint", "email": GOOGLE_EMAIL, "name": "Google Endpoint", "picture": None,
    }
    await _purge(GOOGLE_EMAIL)
    try:
        async with async_session() as session:
            resp = await auth_google(GoogleAuthRequest(id_token="ignored"), session)
        assert resp.user.email == GOOGLE_EMAIL
        assert tokens.verify(resp.token) == resp.user.id
    finally:
        google.verify_id_token = orig
        settings.auth_jwt_secret = original
        await _purge(GOOGLE_EMAIL)


async def test_bad_provider_token_401():
    orig = apple.verify_identity_token

    def boom(tok):
        raise ProviderVerificationError("bad token")

    apple.verify_identity_token = boom
    try:
        async with async_session() as session:
            try:
                await auth_apple(AppleAuthRequest(identity_token="bad"), session)
            except HTTPException as exc:
                assert exc.status_code == 401
            else:
                raise AssertionError("expected 401")
    finally:
        apple.verify_identity_token = orig


async def test_require_auth_accepts_issued_jwt():
    original = settings.auth_jwt_secret
    settings.auth_jwt_secret = _SECRET
    await _purge(RA_EMAIL)
    try:
        async with async_session() as session:
            user = await resolve_user(
                session, provider="google", sub="ra-sub", email=RA_EMAIL, name="RA Test", avatar=None
            )
            identifier = user.identifier
            token = tokens.issue(user)
        async with async_session() as session:
            assert await require_auth(_creds(token), session) == identifier
    finally:
        settings.auth_jwt_secret = original
        await _purge(RA_EMAIL)


async def test_require_auth_enforced_rejects_bad_token():
    orig_req, orig_tok = settings.auth_required, settings.api_tokens
    settings.auth_required = True
    settings.api_tokens = {}
    try:
        async with async_session() as session:
            try:
                await require_auth(_creds("not-a-jwt"), session)
            except HTTPException as exc:
                assert exc.status_code == 401
            else:
                raise AssertionError("expected 401")
    finally:
        settings.auth_required = orig_req
        settings.api_tokens = orig_tok


async def test_require_auth_open_passthrough():
    orig_req, orig_tok = settings.auth_required, settings.api_tokens
    settings.auth_required = False
    settings.api_tokens = {}
    try:
        async with async_session() as session:
            assert await require_auth(_creds("not-a-jwt"), session) is None
            assert await require_auth(None, session) is None
    finally:
        settings.auth_required = orig_req
        settings.api_tokens = orig_tok


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
