"""SimpleFIN consumer client (read-only).

Sync HTTP via `requests`, like the other outbound integrations; the async sync layer wraps calls in
`asyncio.to_thread`, matching the Plaid client. Flow (see SIMPLEFIN_SPEC.md):
  - a base64 *setup token* decodes to a claim URL; POST it -> a permanent *Access URL* that embeds HTTP
    Basic-Auth creds in its userinfo (`https://user:pass@host/...`);
  - GET `<access_url>/accounts?start-date=&end-date=&pending=1&version=2` -> an Account Set.
"""
import base64
import binascii

import requests

_TIMEOUT = 30


class SimpleFinError(Exception):
    """A SimpleFIN request failed. `reauth` flags a credential problem (403) the connection should surface for
    a re-paste; `payment` flags 402 (the SimpleFIN subscription needs paying)."""

    def __init__(self, message: str, *, reauth: bool = False, payment: bool = False):
        super().__init__(message)
        self.reauth = reauth
        self.payment = payment


def make_client() -> "SimpleFinClient":
    """SimpleFIN needs no server-side creds (the per-user Access URL lives in the DB), so this is stateless -
    the factory exists for parity with plaid_client.make_client() and easy monkeypatching in tests."""
    return SimpleFinClient()


class SimpleFinClient:
    def claim(self, setup_token: str) -> str:
        """Base64-decode the setup token to its claim URL and POST it for a permanent Access URL."""
        try:
            claim_url = base64.b64decode(setup_token.strip(), validate=True).decode().strip()
        except (binascii.Error, ValueError, UnicodeDecodeError) as exc:
            raise SimpleFinError("Not a valid SimpleFIN setup token") from exc
        if not claim_url.startswith("https://"):
            raise SimpleFinError("Setup token did not decode to an https claim URL")
        resp = requests.post(claim_url, timeout=_TIMEOUT)
        if resp.status_code == 403:
            raise SimpleFinError("Setup token is invalid or was already claimed", reauth=True)
        resp.raise_for_status()
        access_url = resp.text.strip()
        if not access_url.startswith("https://"):
            raise SimpleFinError("Claim did not return an access URL")
        return access_url

    def fetch_account_set(self, access_url: str, start_date: int, end_date: int | None = None,
                          pending: bool = True) -> dict:
        """GET `<access_url>/accounts` for a [start_date, end_date) epoch window. The Access URL carries
        Basic-Auth in its userinfo, which `requests` applies automatically."""
        params: dict[str, object] = {"start-date": start_date, "pending": 1 if pending else 0, "version": 2}
        if end_date is not None:
            params["end-date"] = end_date
        resp = requests.get(f"{access_url.rstrip('/')}/accounts", params=params, timeout=_TIMEOUT)
        if resp.status_code == 403:
            raise SimpleFinError("SimpleFIN authentication failed", reauth=True)
        if resp.status_code == 402:
            raise SimpleFinError("SimpleFIN payment required", payment=True)
        resp.raise_for_status()
        return resp.json()
