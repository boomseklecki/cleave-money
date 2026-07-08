import base64

from cryptography.hazmat.primitives.asymmetric import ec
from pydantic import BaseModel, field_validator


class DeviceRegister(BaseModel):
    token: str
    platform: str = "ios"
    # Base64 X9.63 P-256 public key for E2E-encrypted (relay-blind) pushes; omitted by older builds.
    public_key: str | None = None

    @field_validator("public_key")
    @classmethod
    def _valid_p256_point(cls, v: str | None) -> str | None:
        """Reject anything that isn't a real P-256 key. A bad/empty key would otherwise be stored and then
        treated as "no key" (empty) or fail to seal - either way silently downgrading that device's pushes.
        Validating here means only a usable key is ever persisted (mirrors `crypto_push.seal`'s decode)."""
        if v is None:
            return v
        try:
            raw = base64.b64decode(v, validate=True)
            ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw)  # 65-byte 0x04 point, on-curve
        except Exception as exc:
            raise ValueError("public_key must be a base64 X9.63 uncompressed P-256 point (65 bytes)") from exc
        return v
