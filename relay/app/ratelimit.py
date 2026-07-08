"""In-memory sliding-window rate limiter (per-process), mirroring the backend's. Keyed by an arbitrary
string (a client IP for /register, the API key hash for /push)."""
import time
from collections import defaultdict, deque

from fastapi import HTTPException, Request, status

_hits: dict[str, deque[float]] = defaultdict(deque)
_last_sweep = 0.0


def _sweep(now: float) -> None:
    global _last_sweep
    if now - _last_sweep < 600:
        return
    _last_sweep = now
    for key in [k for k, b in _hits.items() if not b or now - b[-1] > 3600]:
        _hits.pop(key, None)


def client_ip(request: Request) -> str:
    cf = request.headers.get("CF-Connecting-IP")
    if cf:
        return cf
    fwd = request.headers.get("X-Forwarded-For")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def check(key: str, max_requests: int, window_seconds: int) -> None:
    """Raises 429 once `key` exceeds `max_requests` within `window_seconds`."""
    now = time.monotonic()
    _sweep(now)
    bucket = _hits[key]
    cutoff = now - window_seconds
    while bucket and bucket[0] < cutoff:
        bucket.popleft()
    if len(bucket) >= max_requests:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                            detail="Too many requests. Try again later.")
    bucket.append(now)
