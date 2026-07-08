"""ECIES seal for push payloads so the relay (and Apple) stay blind to notification content.

Ephemeral-static ECDH on P-256 → HKDF-SHA256 → AES-256-GCM. The recipient device holds the static
private key in its Keychain and publishes the static *public* key (X9.63 uncompressed point) via
`/devices`. We seal each message to that key with a fresh ephemeral keypair; only the ciphertext +
ephemeral public key transit the relay. The wire encoding is chosen to round-trip exactly with Swift
CryptoKit on the device:

  - `epk`: ephemeral public key as X9.63 uncompressed point (0x04‖X‖Y, 65 B) == CryptoKit `.x963Representation`.
  - `box`: nonce(12)‖ciphertext‖tag(16) == CryptoKit `AES.GCM.SealedBox(combined:)`.
  - HKDF salt/info are the fixed constants below; CryptoKit derives with the same
    `hkdfDerivedSymmetricKey(using: SHA256, salt:, sharedInfo:, outputByteCount: 32)`.
"""
import base64
import json
import os

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

_SALT = b"Cleave-push-v1"
_INFO = b"Cleave-push-v1"
_CURVE = ec.SECP256R1()


def _derive_key(shared: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=_SALT, info=_INFO).derive(shared)


def seal(title: str, body: str, recipient_pub_x963: bytes,
         target: dict | None = None) -> dict[str, str]:
    """Seals `{title, body[, target]}` to a recipient's P-256 public key. Returns base64 `epk` + `box`.
    `target` is an optional deep-link payload (`{type, id}`) the device surfaces for the tap handler."""
    recipient_pub = ec.EllipticCurvePublicKey.from_encoded_point(_CURVE, recipient_pub_x963)
    ephemeral = ec.generate_private_key(_CURVE)
    shared = ephemeral.exchange(ec.ECDH(), recipient_pub)
    key = _derive_key(shared)
    nonce = os.urandom(12)
    payload = {"title": title, "body": body}
    if target:
        payload["target"] = target
    plaintext = json.dumps(payload).encode()
    box = nonce + AESGCM(key).encrypt(nonce, plaintext, None)  # nonce‖ciphertext‖tag
    epk = ephemeral.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return {"epk": base64.b64encode(epk).decode(), "box": base64.b64encode(box).decode()}


def _open(epk_b64: str, box_b64: str, recipient_priv: ec.EllipticCurvePrivateKey) -> dict:
    """Inverse of `seal` - for the Python self-consistency test only (the device does this in CryptoKit)."""
    epk = ec.EllipticCurvePublicKey.from_encoded_point(_CURVE, base64.b64decode(epk_b64))
    shared = recipient_priv.exchange(ec.ECDH(), epk)
    key = _derive_key(shared)
    raw = base64.b64decode(box_b64)
    nonce, sealed = raw[:12], raw[12:]
    return json.loads(AESGCM(key).decrypt(nonce, sealed, None))
