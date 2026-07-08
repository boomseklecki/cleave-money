"""Startup health check for ENCRYPTION_KEYS drift.

Only `plaid_items.access_token` / `splitwise_tokens.access_token` are Fernet-encrypted at rest, keyed by
`ENCRYPTION_KEYS` (env only - never in a backup). If a DB is restored on a host whose `ENCRYPTION_KEYS`
doesn't match the data (or the key was lost), those tokens can't be decrypted and Plaid/Splitwise auth
silently fails while everything else looks fine. This samples a few stored ciphertexts at startup and warns
loudly when the configured key decrypts none of them, so the operator learns immediately instead of via
broken syncs. See docs/OPERATIONS.md.
"""
import logging

from cryptography.fernet import InvalidToken
from sqlalchemy import text

from app.db import async_session
from app.security.crypto import cipher

log = logging.getLogger(__name__)

_SAMPLE = 20
# (table, encrypted column) sources to sample.
_TOKEN_SOURCES = (("plaid_items", "access_token"), ("splitwise_tokens", "access_token"))


async def check_encryption_key_health() -> tuple[int, int]:
    """Sample stored token ciphertexts and try to decrypt with the current key(s).

    Returns (sampled, decryptable). No-op returning (0, 0) when no key is configured (plaintext/dev). Emits
    a WARNING when token rows exist but none decrypt - i.e. the configured ENCRYPTION_KEYS doesn't match the
    data at rest.
    """
    fernet = cipher()
    if fernet is None:
        return (0, 0)
    sampled = decryptable = 0
    async with async_session() as session:
        for table, col in _TOKEN_SOURCES:
            result = await session.execute(
                text(f"SELECT {col} FROM {table} WHERE {col} IS NOT NULL LIMIT :n"), {"n": _SAMPLE})
            for (raw,) in result:
                sampled += 1
                try:
                    fernet.decrypt(raw.encode())
                    decryptable += 1
                except InvalidToken:
                    pass
    if sampled and decryptable == 0:
        log.warning(
            "ENCRYPTION_KEYS cannot decrypt any of %d sampled stored token(s): the configured key does not "
            "match the data at rest (e.g. a DB restored without its ENCRYPTION_KEYS). Plaid/Splitwise "
            "integrations will fail until the correct key is restored - see docs/OPERATIONS.md.",
            sampled)
    return (sampled, decryptable)
