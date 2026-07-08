"""HTTP hardening: security headers on every response + opt-in Host allow-list. Runs against a minimal app so
no DB/MinIO/lifespan is involved (install_hardening is the same helper main.py uses)."""
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.http_hardening import install_hardening


def _client(allowed_hosts=None, cors=None) -> TestClient:
    app = FastAPI()
    install_hardening(app, allowed_hosts=allowed_hosts or [], cors_allowed_origins=cors or [])

    @app.get("/ping")
    async def ping() -> dict[str, str]:
        return {"ok": "1"}

    return TestClient(app)


def test_security_headers_on_every_response():
    r = _client().get("/ping")
    assert r.status_code == 200
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "DENY"
    assert r.headers["Referrer-Policy"] == "no-referrer"
    assert "frame-ancestors 'none'" in r.headers["Content-Security-Policy"]
    assert "max-age=" in r.headers["Strict-Transport-Security"]


def test_trusted_host_allows_configured_and_rejects_others():
    client = _client(allowed_hosts=["testserver", "good.example"])  # TestClient's default Host is "testserver"
    assert client.get("/ping", headers={"host": "good.example"}).status_code == 200
    assert client.get("/ping", headers={"host": "evil.example"}).status_code == 400


def test_host_filter_off_by_default():
    # Empty allowed_hosts ⇒ TrustedHost not mounted ⇒ any Host passes (dev/default behavior unchanged).
    assert _client().get("/ping", headers={"host": "anything.example"}).status_code == 200


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
