"""ECIES seal/open round-trips, and the sealed bytes never leak the plaintext. The cross-language
interop with Swift CryptoKit is pinned separately by a committed test vector on the iOS side."""
import base64
import json

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.services import crypto_push


def _keypair() -> tuple[ec.EllipticCurvePrivateKey, bytes]:
    priv = ec.generate_private_key(ec.SECP256R1())
    pub = priv.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return priv, pub


def test_seal_open_roundtrip():
    priv, pub = _keypair()
    sealed = crypto_push.seal("Cleave", "Alice added 'Dinner'", pub)
    out = crypto_push._open(sealed["epk"], sealed["box"], priv)
    assert out == {"title": "Cleave", "body": "Alice added 'Dinner'"}


def test_seal_includes_optional_deeplink_target():
    priv, pub = _keypair()
    target = {"type": "expense", "id": "11111111-1111-1111-1111-111111111111"}
    sealed = crypto_push.seal("Cleave", "Alice added 'Dinner'", pub, target=target)
    out = crypto_push._open(sealed["epk"], sealed["box"], priv)
    assert out == {"title": "Cleave", "body": "Alice added 'Dinner'", "target": target}
    # No target → key omitted (back-compat with older NSE builds).
    plain = crypto_push.seal("t", "b", pub)
    assert "target" not in crypto_push._open(plain["epk"], plain["box"], priv)


def test_epk_is_x963_uncompressed_point():
    _, pub = _keypair()
    sealed = crypto_push.seal("t", "b", pub)
    epk = base64.b64decode(sealed["epk"])
    assert len(epk) == 65 and epk[0] == 0x04  # matches CryptoKit .x963Representation


def test_ciphertext_does_not_leak_plaintext():
    _, pub = _keypair()
    secret = "BURRITO-PALACE-$42.00"
    sealed = crypto_push.seal("Cleave", secret, pub)
    blob = (base64.b64decode(sealed["box"]) + base64.b64decode(sealed["epk"]))
    assert secret.encode() not in blob


def test_fresh_ephemeral_key_each_seal():
    _, pub = _keypair()
    a = crypto_push.seal("t", "b", pub)
    b = crypto_push.seal("t", "b", pub)
    assert a["epk"] != b["epk"] and a["box"] != b["box"]


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
