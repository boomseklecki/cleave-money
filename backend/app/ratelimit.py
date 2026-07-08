"""In-process per-client-IP sliding-window rate limiter for the unauthenticated write endpoints.

Best-effort and **per-process** (not shared across uvicorn workers) - Cloudflare remains the primary DDoS /
abuse layer; this just bounds cheap scripted abuse (e.g. spamming `/auth/demo`). Keyed by client IP, read from
`CF-Connecting-IP` (set by the Cloudflare tunnel), else the first `X-Forwarded-For` hop, else the peer address.
"""
import time
from collections import defaultdict, deque

from fastapi import HTTPException, Request, status

_hits: dict[str, deque[float]] = defaultdict(deque)
_last_sweep = 0.0
_SWEEP_EVERY = 600.0  # seconds; drop idle buckets so the dict can't grow unbounded
_SWEEP_STALE = 3600.0  # a bucket whose newest hit is older than this is dropped


def _client_ip(request: Request) -> str:
    cf = request.headers.get("cf-connecting-ip")
    if cf:
        return cf.strip()
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _sweep(now: float) -> None:
    global _last_sweep
    if now - _last_sweep < _SWEEP_EVERY:
        return
    _last_sweep = now
    for key in list(_hits.keys()):
        bucket = _hits[key]
        if not bucket or bucket[-1] < now - _SWEEP_STALE:
            del _hits[key]


def rate_limit(max_requests: int, window_seconds: int):
    """A FastAPI dependency that raises 429 once an IP exceeds `max_requests` within `window_seconds`."""
    async def _dependency(request: Request) -> None:
        now = time.monotonic()
        _sweep(now)
        bucket = _hits[f"{request.url.path}:{_client_ip(request)}"]
        cutoff = now - window_seconds
        while bucket and bucket[0] < cutoff:
            bucket.popleft()
        if len(bucket) >= max_requests:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Too many requests. Try again later.",
            )
        bucket.append(now)
    return _dependency
