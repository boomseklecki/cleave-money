import base64
import hashlib
import secrets

AUTHORIZE_URL = "https://secure.splitwise.com/oauth/authorize"
TOKEN_URL = "https://secure.splitwise.com/oauth/token"


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def generate_code_verifier() -> str:
    # 32 random bytes -> 43-char base64url string, within RFC 7636's 43-128 range.
    return _b64url(secrets.token_bytes(32))


def code_challenge_s256(code_verifier: str) -> str:
    digest = hashlib.sha256(code_verifier.encode("ascii")).digest()
    return _b64url(digest)


def generate_state() -> str:
    return secrets.token_urlsafe(24)
