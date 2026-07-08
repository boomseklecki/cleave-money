"""EncryptedString: round-trips with a key, passes through without one, and tolerates legacy plaintext.
Exercises the column type's processors directly (no DB). Toggles settings in-process and restores them.
"""
from cryptography.fernet import Fernet

from app.config import settings
from app.security.crypto import EncryptedString


def test_encrypted_string_roundtrip_passthrough_and_legacy():
    t = EncryptedString()
    saved = settings.encryption_keys
    try:
        # No key (dev): plaintext passthrough.
        settings.encryption_keys = []
        assert t.process_bind_param("plain", None) == "plain"
        assert t.process_result_value("plain", None) == "plain"

        # With a key: ciphertext differs from plaintext and round-trips.
        settings.encryption_keys = [Fernet.generate_key().decode()]
        enc = t.process_bind_param("secret-token", None)
        assert enc != "secret-token"
        assert t.process_result_value(enc, None) == "secret-token"

        # Legacy plaintext row written before encryption still reads (InvalidToken fallback).
        assert t.process_result_value("legacy-plaintext", None) == "legacy-plaintext"

        # None always passes through.
        assert t.process_bind_param(None, None) is None
        assert t.process_result_value(None, None) is None

        # MultiFernet rotation: a value encrypted under an old key still decrypts when a new key is prepended.
        old = settings.encryption_keys[0]
        new = Fernet.generate_key().decode()
        settings.encryption_keys = [old]
        enc_old = t.process_bind_param("rotate-me", None)
        settings.encryption_keys = [new, old]  # new first (encrypts), old still decrypts
        assert t.process_result_value(enc_old, None) == "rotate-me"
    finally:
        settings.encryption_keys = saved


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
