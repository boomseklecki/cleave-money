"""Apple 'Sign in with Apple' identity-token verification (native iOS flow).

Verifies the identity token Apple issues to the app: RS256 signature via Apple's JWKS,
issuer = appleid.apple.com, audience = the app bundle id (`apple_audience`). Native token
verification needs no client secret. The JWKS fetch is blocking - call via asyncio.to_thread.
"""
import jwt
from jwt import PyJWKClient

from app.config import settings
from app.integrations.auth import ProviderVerificationError, verified_email

_ISSUER = "https://appleid.apple.com"
_JWKS_URL = "https://appleid.apple.com/auth/keys"
_jwks_client = PyJWKClient(_JWKS_URL)


def verify_identity_token(token: str) -> dict:
    """Returns {sub, email} for a valid Apple identity token; raises ProviderVerificationError."""
    try:
        signing_key = _jwks_client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.apple_audience,
            issuer=_ISSUER,
        )
    except (jwt.PyJWTError, jwt.PyJWKClientError) as exc:
        raise ProviderVerificationError(str(exc)) from exc
    return {"sub": claims["sub"], "email": verified_email(claims)}
