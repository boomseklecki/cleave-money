"""Field-level encryption for secrets at rest (Fernet).

`EncryptedString` is a SQLAlchemy column type that encrypts on write and decrypts on read, transparently - 
the Python attribute is always plaintext. Keyed by `settings.encryption_keys` (a `MultiFernet`: the first
key encrypts, any decrypts, so keys can be rotated). With no key configured (dev/tests) it stores plaintext,
and reads fall back to the raw value on a decrypt failure - so legacy plaintext rows and the no-key case
coexist with encrypted rows.
"""
from cryptography.fernet import Fernet, InvalidToken, MultiFernet
from sqlalchemy import types

from app.config import settings


def cipher() -> MultiFernet | None:
    keys = [k.strip() for k in settings.encryption_keys if k and k.strip()]
    if not keys:
        return None
    return MultiFernet([Fernet(k.encode()) for k in keys])


def encrypt(value: str) -> str:
    f = cipher()
    return f.encrypt(value.encode()).decode() if f else value


def decrypt(value: str) -> str:
    f = cipher()
    if f is None:
        return value
    try:
        return f.decrypt(value.encode()).decode()
    except InvalidToken:
        return value  # legacy plaintext row (written before encryption was enabled)


class EncryptedString(types.TypeDecorator):
    """Text column whose value is Fernet-encrypted at rest."""

    impl = types.Text
    cache_ok = True

    def process_bind_param(self, value: str | None, dialect) -> str | None:
        return None if value is None else encrypt(value)

    def process_result_value(self, value: str | None, dialect) -> str | None:
        return None if value is None else decrypt(value)
