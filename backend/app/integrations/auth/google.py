"""Google Sign-In ID-token verification (iOS client).

Verifies the ID token from the Google Sign-In SDK: RS256 signature via Google's JWKS,
issuer = accounts.google.com, audience = the iOS OAuth client id (`google_client_id`).
The JWKS fetch is blocking - call via asyncio.to_thread.
"""
import jwt
from jwt import PyJWKClient

from app.config import settings
from app.integrations.auth import ProviderVerificationError, verified_email

_ISSUERS = ["accounts.google.com", "https://accounts.google.com"]
_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
_jwks_client = PyJWKClient(_JWKS_URL)


def verify_id_token(token: str) -> dict:
    """Returns {sub, email, name, picture} for a valid Google ID token; raises on failure."""
    try:
        signing_key = _jwks_client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.google_client_id,
            issuer=_ISSUERS,
        )
    except (jwt.PyJWTError, jwt.PyJWKClientError) as exc:
        raise ProviderVerificationError(str(exc)) from exc
    return {
        "sub": claims["sub"],
        "email": verified_email(claims),
        "name": claims.get("name"),
        "picture": claims.get("picture"),
    }
