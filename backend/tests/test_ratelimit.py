"""In-process rate limiter: allows up to `max` per window per IP, then 429s; distinct IPs are independent."""
from fastapi import HTTPException

from app.ratelimit import rate_limit


class _FakeURL:
    def __init__(self, path): self.path = path


class _FakeRequest:
    def __init__(self, ip, path):
        self.headers = {"cf-connecting-ip": ip}
        self.url = _FakeURL(path)
        self.client = None


async def test_allows_then_blocks():
    dep = rate_limit(2, 3600)
    req = _FakeRequest("1.2.3.4", "/test/ratelimit/a")
    await dep(req)
    await dep(req)  # 2 allowed
    try:
        await dep(req)
        raise AssertionError("expected 429 on the 3rd request")
    except HTTPException as e:
        assert e.status_code == 429


async def test_distinct_ips_independent():
    dep = rate_limit(1, 3600)
    path = "/test/ratelimit/b"
    await dep(_FakeRequest("10.0.0.1", path))           # IP #1 uses its one slot
    await dep(_FakeRequest("10.0.0.2", path))           # IP #2 still has its own slot
    try:
        await dep(_FakeRequest("10.0.0.1", path))
        raise AssertionError("expected 429 for the repeated IP")
    except HTTPException as e:
        assert e.status_code == 429


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
