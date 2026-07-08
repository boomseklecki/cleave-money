"""Tiny sqlite store for issued API keys. No ORM - the relay stays dependency-light and portable."""
import hashlib
import secrets
import sqlite3
from datetime import datetime, timezone

from app.config import settings

_SCHEMA = """
CREATE TABLE IF NOT EXISTS api_keys (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    key_hash    TEXT NOT NULL UNIQUE,
    email       TEXT NOT NULL,
    instance    TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    approved    INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    last_used_at TEXT,
    push_count  INTEGER NOT NULL DEFAULT 0
);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(settings.db_path)
    conn.row_factory = sqlite3.Row
    return conn


def init() -> None:
    with connect() as conn:
        conn.executescript(_SCHEMA)


def create_key(email: str, instance: str | None, *, approved: bool | None = None) -> str:
    """Issues a new API key (returned in plaintext once); stores only its hash.

    `approved=None` follows RELAY_AUTO_ISSUE; admin issuance passes approved=True to activate now."""
    key = "relaysk_" + secrets.token_urlsafe(32)
    auto = settings.relay_auto_issue if approved is None else approved
    approved = 1 if auto else 0
    with connect() as conn:
        conn.execute(
            "INSERT INTO api_keys (key_hash, email, instance, active, approved, created_at) "
            "VALUES (?, ?, ?, 1, ?, ?)",
            (hash_key(key), email, instance, approved, _now()))
        conn.commit()
    return key


def valid_key(key: str) -> bool:
    """True if the key exists and is active + approved; bumps usage."""
    with connect() as conn:
        row = conn.execute(
            "SELECT id FROM api_keys WHERE key_hash = ? AND active = 1 AND approved = 1",
            (hash_key(key),)).fetchone()
        if row is None:
            return False
        conn.execute("UPDATE api_keys SET last_used_at = ?, push_count = push_count + 1 WHERE id = ?",
                     (_now(), row["id"]))
        conn.commit()
        return True


def list_keys() -> list[dict]:
    """All keys with metadata (no hashes, no plaintext), newest first."""
    with connect() as conn:
        rows = conn.execute(
            "SELECT id, email, instance, active, approved, created_at, last_used_at, push_count "
            "FROM api_keys ORDER BY created_at DESC").fetchall()
        return [dict(row) for row in rows]


def delete_key(key_id: int) -> bool:
    with connect() as conn:
        cur = conn.execute("DELETE FROM api_keys WHERE id = ?", (key_id,))
        conn.commit()
        return cur.rowcount > 0


def set_flags(key_id: int, *, active: int | None = None, approved: int | None = None) -> bool:
    sets, args = [], []
    if active is not None:
        sets.append("active = ?"); args.append(active)
    if approved is not None:
        sets.append("approved = ?"); args.append(approved)
    if not sets:
        return False
    args.append(key_id)
    with connect() as conn:
        cur = conn.execute(f"UPDATE api_keys SET {', '.join(sets)} WHERE id = ?", args)
        conn.commit()
        return cur.rowcount > 0
