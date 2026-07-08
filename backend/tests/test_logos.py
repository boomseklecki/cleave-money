"""Logo proxy: fetches a brand logo from upstream, caches it in MinIO, and serves it; rejects bad
domains. Hits the running api like the other integration tests and cleans up its own MinIO object.
"""
import urllib.error
import urllib.request

from app.integrations.storage import minio_client

API = "http://localhost:8000"
DOMAIN = "github.com"


def _get(path):
    req = urllib.request.Request(API + path, method="GET")
    try:
        resp = urllib.request.urlopen(req)
        return resp.status, resp.read(), resp.headers.get("Content-Type")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("Content-Type")


def test_logo_proxy_caches_and_serves():
    key = f"logos/{DOMAIN}.img"
    try:
        status, body, ctype = _get(f"/logos/{DOMAIN}")
        assert status == 200, (status, ctype, body[:200])
        assert ctype == "image/png"
        assert len(body) > 0
        assert minio_client.object_exists(key)
        # Second call is served straight from the MinIO cache.
        status2, body2, _ = _get(f"/logos/{DOMAIN}")
        assert status2 == 200 and len(body2) == len(body)
    finally:
        try:
            minio_client.remove(key)
        except Exception:
            pass


def test_logo_proxy_rejects_bad_domain():
    # Too short / invalid → 404, no upstream fetch.
    assert _get("/logos/x")[0] == 404


async def test_negative_cache_marks_skips_and_self_heals():
    """Favicon-less domains are negative-cached: a miss writes a `.missing.img` marker, a fresh marker
    short-circuits WITHOUT re-fetching upstream, and a stale marker re-fetches + clears on recovery.
    Unit-level (the real upstream returns a default globe, so it never yields None). Monkeypatched."""
    from fastapi import HTTPException

    from app.integrations import logos as logos_int
    from app.routers import logos as logos_router

    domain = "no-such-brand-zzz.example"
    missing_key = f"logos/{domain}.missing.img"
    positive_key = f"logos/{domain}.img"
    calls = {"fetch": 0}
    puts: list = []
    removed: list = []

    orig = (minio_client.object_exists, minio_client.age_seconds, minio_client.put_object,
            minio_client.remove, logos_int.fetch_favicon)
    try:
        minio_client.object_exists = lambda k: False                    # positive-cache miss
        minio_client.put_object = lambda k, d, ct: puts.append(k)
        minio_client.remove = lambda k: removed.append(k)

        def _fetch_none(d):
            calls["fetch"] += 1
            return None
        logos_int.fetch_favicon = _fetch_none

        # 1) no marker yet → fetch runs, returns None → marker written, 404
        minio_client.age_seconds = lambda k: None
        raised = None
        try:
            await logos_router.brand_logo(domain)
        except HTTPException as e:
            raised = e.status_code
        assert raised == 404
        assert calls["fetch"] == 1
        assert missing_key in puts

        # 2) fresh marker → 404 short-circuit, fetch NOT called again
        minio_client.age_seconds = lambda k: 10.0                       # < TTL
        try:
            await logos_router.brand_logo(domain)
        except HTTPException as e:
            assert e.status_code == 404
        assert calls["fetch"] == 1                                      # unchanged - no re-fetch

        # 3) stale marker + upstream now has a favicon → re-fetch, write positive, clear stale marker
        minio_client.age_seconds = lambda k: logos_router.NEGATIVE_TTL_SECONDS + 1
        logos_int.fetch_favicon = lambda d: b"\x89PNG"
        resp = await logos_router.brand_logo(domain)
        assert resp.status_code == 200
        assert positive_key in puts
        assert removed == [missing_key]
    finally:
        (minio_client.object_exists, minio_client.age_seconds, minio_client.put_object,
         minio_client.remove, logos_int.fetch_favicon) = orig


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
