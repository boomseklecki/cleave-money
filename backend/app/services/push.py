"""Fire-and-forget push dispatch via the standalone relay (a separate push host). The backend holds no Apple
creds - it POSTs to the relay, which forwards to APNs and reports dead tokens. No-op unless a relay URL + key
are configured.

Push is **unconditionally end-to-end encrypted**: the real title/body (and any deep-link `target`) are sealed
to each device's published P-256 public key (`DeviceToken.public_key`; see `crypto_push.seal`), so only
ciphertext plus a generic "New activity" fallback alert ever transits the relay. The on-device Notification
Service Extension decrypts and swaps in the real content. There is NO plaintext path: a device with no
published key (an older build) or one whose seal fails (unusable key) is SKIPPED - never downgraded to a
cleartext push. Registration validates the key up front (`DeviceRegister.public_key` requires a base64 X9.63
65-byte on-curve P-256 point, 422 otherwise), so a stored key that fails to seal is a genuine edge case, not
malformed input.

(The relay still accepts a legacy plaintext `tokens` form for other back-compat callers, gated off by its own
`RELAY_REQUIRE_E2EE` flag - but this backend never emits it.)"""
import asyncio
import base64
import logging

import httpx
from sqlalchemy import delete, select

from app import server_settings
from app.config import settings
from app.db import async_session
from app.models import DeviceToken
from app.services import crypto_push

log = logging.getLogger(__name__)

_FALLBACK_TITLE = "Cleave"
_FALLBACK_BODY = "New activity"


def enqueue(owners: set[str], title: str, body: str, target: dict | None = None) -> None:
    """Schedules a best-effort push to the owners' devices, without blocking the request. `target` is an
    optional deep-link payload ({type, id}) sealed into the E2E push for the tap handler to route on."""
    if not settings.push_configured or not owners:
        return
    asyncio.create_task(_send(set(owners), title, body, target))


async def _post(client: httpx.AsyncClient, payload: dict) -> list[str]:
    """POSTs one push request to the relay; returns dead tokens (empty on any failure)."""
    try:
        resp = await client.post(
            f"{settings.push_relay_url.rstrip('/')}/push",
            headers={"Authorization": f"Bearer {settings.push_relay_api_key}"},
            json=payload)
        if resp.status_code == 200:
            return resp.json().get("dead", [])
        # A non-200 (401 bad key, 429 rate limit, 400, 503 no APNs creds) is a BROKEN pipeline - log it so it
        # isn't silently indistinguishable from "no devices / no dead tokens".
        log.warning("relay push rejected: %s %s", resp.status_code, resp.text[:200])
    except Exception:
        log.warning("relay push failed", exc_info=True)
    return []


async def _send(owners: set[str], title: str, body: str, target: dict | None = None) -> None:
    try:
        async with async_session() as session:
            # Runtime master switch (relay creds are the .env gate in `enqueue`; this is the admin's off-switch).
            if not await server_settings.get(session, "push_enabled"):
                return
            devices = list(await session.scalars(
                select(DeviceToken).where(DeviceToken.user_identifier.in_(owners))))
            if not devices:
                return
            # E2E only: the real content is ONLY ever sent sealed to a device's P-256 key, so the relay stays
            # blind to it. A device with no key (older build) or one whose seal fails (bad key) is SKIPPED - 
            # we never fall back to sending the real title/body in cleartext.
            messages = []
            for dt in devices:
                if not dt.public_key:
                    continue  # keyless (older build) → no push until it publishes a key
                try:
                    sealed = crypto_push.seal(title, body, base64.b64decode(dt.public_key), target=target)
                except Exception:
                    log.warning("seal failed for a keyed device; skipping (no plaintext fallback)",
                                exc_info=True)
                    continue
                messages.append({"token": dt.token, **sealed})
            if not messages:
                return

            async with httpx.AsyncClient(timeout=10) as client:
                dead = await _post(client, {"messages": messages,
                                            "fallback_title": _FALLBACK_TITLE,
                                            "fallback_body": _FALLBACK_BODY})
            if dead:
                await session.execute(delete(DeviceToken).where(DeviceToken.token.in_(dead)))
                await session.commit()
    except Exception:
        log.warning("push dispatch failed", exc_info=True)
