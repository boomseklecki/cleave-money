"""Device-token registration (idempotent + owner-scoped) and relay dispatch. The APNs sender lives in the
relay; push is E2E-only - real content is ONLY ever sent sealed to a device's P-256 key, so the relay stays
blind. A device with no key (older build) or a seal failure is skipped (never a plaintext fallback)."""
import base64

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException
from sqlalchemy import delete, select

from app.config import settings
from app.db import async_session
from app.models import DeviceToken
from app.routers.devices import register_device, unregister_device
from app.schemas.device import DeviceRegister
from app.services import push

ALICE = "dev-alice"


def _pubkey_b64() -> str:
    pub = ec.generate_private_key(ec.SECP256R1()).public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return base64.b64encode(pub).decode()


async def _purge():
    async with async_session() as s:
        await s.execute(delete(DeviceToken).where(DeviceToken.user_identifier == ALICE))
        await s.commit()


async def _count() -> int:
    async with async_session() as s:
        return len(list(await s.scalars(
            select(DeviceToken).where(DeviceToken.user_identifier == ALICE))))


async def test_register_idempotent():
    await _purge()
    try:
        for _ in range(2):
            async with async_session() as s:
                await register_device(DeviceRegister(token="tok-1"), caller=ALICE, session=s)
        assert await _count() == 1
    finally:
        await _purge()


async def test_unregister_removes():
    await _purge()
    try:
        async with async_session() as s:
            await register_device(DeviceRegister(token="tok-x"), caller=ALICE, session=s)
        async with async_session() as s:
            await unregister_device(DeviceRegister(token="tok-x"), caller=ALICE, session=s)
        assert await _count() == 0
    finally:
        await _purge()


async def test_register_requires_auth():
    async with async_session() as s:
        try:
            await register_device(DeviceRegister(token="t"), caller=None, session=s)
            raise AssertionError("expected 401")
        except HTTPException as e:
            assert e.status_code == 401


async def test_register_stores_and_rotates_public_key():
    await _purge()
    try:
        key1, key2 = _pubkey_b64(), _pubkey_b64()
        async with async_session() as s:
            await register_device(DeviceRegister(token="tok-k", public_key=key1), caller=ALICE, session=s)
        async with async_session() as s:
            dt = await s.scalar(select(DeviceToken).where(DeviceToken.user_identifier == ALICE))
            assert dt.public_key == key1
        async with async_session() as s:  # re-register with a rotated key updates it
            await register_device(DeviceRegister(token="tok-k", public_key=key2), caller=ALICE, session=s)
        async with async_session() as s:
            dt = await s.scalar(select(DeviceToken).where(DeviceToken.user_identifier == ALICE))
            assert dt.public_key == key2 and await _count() == 1
    finally:
        await _purge()


class _FakeResp:
    def __init__(self, dead): self._dead = dead
    status_code = 200
    def json(self): return {"dead": self._dead}


class _FakeClient:
    """Captures relay POSTs; reports the plaintext token as dead so we exercise cleanup."""
    calls: list[dict] = []

    def __init__(self, *a, **k): pass
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False

    async def post(self, url, headers=None, json=None):
        _FakeClient.calls.append(json)
        return _FakeResp(json.get("tokens", []))  # report plaintext tokens dead so we exercise pruning


async def test_push_seals_keyed_and_skips_keyless():
    """E2E only: the keyed device gets a sealed message; the keyless device is skipped - the relay never sees
    a plaintext 'tokens' payload with the real content."""
    await _purge()
    orig_url, orig_key, orig_cls = (settings.push_relay_url, settings.push_relay_api_key, push.httpx.AsyncClient)
    settings.push_relay_url, settings.push_relay_api_key = "http://relay.test", "k"
    push.httpx.AsyncClient = _FakeClient
    _FakeClient.calls = []
    try:
        async with async_session() as s:
            s.add(DeviceToken(user_identifier=ALICE, token="tok-keyed", public_key=_pubkey_b64()))
            s.add(DeviceToken(user_identifier=ALICE, token="tok-plain"))  # keyless (older build)
            await s.commit()
        await push._send({ALICE}, "Cleave", "Alice added 'Dinner'")

        assert all("tokens" not in c for c in _FakeClient.calls)   # no plaintext-content payload ever
        enc = next(c for c in _FakeClient.calls if "messages" in c)
        assert enc["messages"][0]["token"] == "tok-keyed"
        assert {"epk", "box"} <= set(enc["messages"][0])
        assert "Dinner" not in str(_FakeClient.calls)              # content never leaves in cleartext

        async with async_session() as s:                          # keyless device untouched (skipped)
            left = {dt.token for dt in await s.scalars(
                select(DeviceToken).where(DeviceToken.user_identifier == ALICE))}
        assert left == {"tok-keyed", "tok-plain"}
    finally:
        settings.push_relay_url, settings.push_relay_api_key = orig_url, orig_key
        push.httpx.AsyncClient = orig_cls
        await _purge()


async def test_push_skips_keyed_device_on_seal_failure():
    """A seal failure for a keyed device (e.g. a corrupt stored key) is skipped - NEVER a plaintext fallback,
    so no relay POST happens at all rather than leaking the real content."""
    await _purge()
    orig = (settings.push_relay_url, settings.push_relay_api_key, push.httpx.AsyncClient, push.crypto_push.seal)
    settings.push_relay_url, settings.push_relay_api_key = "http://relay.test", "k"
    push.httpx.AsyncClient = _FakeClient
    _FakeClient.calls = []

    def _boom(*a, **k):
        raise ValueError("bad key")
    push.crypto_push.seal = _boom
    try:
        async with async_session() as s:
            s.add(DeviceToken(user_identifier=ALICE, token="tok-keyed", public_key=_pubkey_b64()))
            await s.commit()
        await push._send({ALICE}, "Cleave", "Alice added 'Dinner'")
        assert _FakeClient.calls == []   # no messages -> no relay call, no plaintext leak
    finally:
        (settings.push_relay_url, settings.push_relay_api_key,
         push.httpx.AsyncClient, push.crypto_push.seal) = orig
        await _purge()


async def test_register_rejects_invalid_public_key():
    from pydantic import ValidationError
    for bad in ("", "not base64 @@@", base64.b64encode(b"too-short").decode()):
        try:
            DeviceRegister(token="t", public_key=bad)
            raise AssertionError(f"expected rejection for {bad!r}")
        except ValidationError:
            pass
    DeviceRegister(token="t", public_key=_pubkey_b64())  # a valid P-256 point is accepted


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
