import base64
import hashlib
from urllib.parse import parse_qs, urlparse

from app.integrations.splitwise import oauth, pkce


def test_verifier_length_and_charset():
    verifier = pkce.generate_code_verifier()
    assert 43 <= len(verifier) <= 128
    # base64url, no padding
    assert "=" not in verifier
    assert "+" not in verifier and "/" not in verifier


def test_challenge_is_s256_of_verifier():
    verifier = pkce.generate_code_verifier()
    challenge = pkce.code_challenge_s256(verifier)
    expected = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
        .decode()
        .rstrip("=")
    )
    assert challenge == expected


def test_state_unique():
    assert pkce.generate_state() != pkce.generate_state()


def test_authorize_url_carries_pkce_params():
    url = oauth.build_authorize_url("state-123", "challenge-abc")
    parsed = urlparse(url)
    assert parsed.netloc == "secure.splitwise.com"
    qs = parse_qs(parsed.query)
    assert qs["response_type"] == ["code"]
    assert qs["state"] == ["state-123"]
    assert qs["code_challenge"] == ["challenge-abc"]
    assert qs["code_challenge_method"] == ["S256"]


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
