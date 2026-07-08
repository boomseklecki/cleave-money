from urllib.parse import urlencode

import requests

from app.config import settings
from app.integrations.splitwise.pkce import AUTHORIZE_URL, TOKEN_URL


def build_authorize_url(state: str, code_challenge: str) -> str:
    params = {
        "response_type": "code",
        "client_id": settings.splitwise_consumer_key,
        "redirect_uri": settings.splitwise_redirect_uri,
        "state": state,
        # PKCE - sent per project spec; Splitwise ignores these harmlessly if unsupported.
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
    }
    return f"{AUTHORIZE_URL}?{urlencode(params)}"


def exchange_code(code: str, code_verifier: str) -> dict:
    """Exchange an authorization code for an access token. Blocking; call via to_thread."""
    resp = requests.post(
        TOKEN_URL,
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": settings.splitwise_redirect_uri,
            "client_id": settings.splitwise_consumer_key,
            "client_secret": settings.splitwise_consumer_secret,
            "code_verifier": code_verifier,
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()
