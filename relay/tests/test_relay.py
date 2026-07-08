"""Relay: registration (issue + per-IP limit), /push auth + forwarding + dead-token return, and the
ES256 provider JWT. No real APNs calls - `apns.send` is monkeypatched."""
import base64
import re

import jwt as pyjwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app import apns, db
from app.config import settings
from app.main import app


@pytest.fixture
def client(tmp_path):
    settings.db_path = str(tmp_path / "relay.db")
    db.init()
    with TestClient(app) as c:
        yield c


def _register(client, ip: str):
    return client.post("/register", data={"email": "a@x.com", "instance": "house"},
                       headers={"X-Forwarded-For": ip})


def test_register_issues_key_then_rate_limits(client):
    resp = _register(client, "1.1.1.1")
    assert resp.status_code == 200
    assert "relaysk_" in resp.text                       # key shown once
    for _ in range(settings.register_max_per_hour):
        last = _register(client, "1.1.1.1")
    assert last.status_code == 429                        # per-IP limit hit


def test_push_rejects_bad_key(client):
    resp = client.post("/push", json={"tokens": ["t"], "title": "x", "body": "y"},
                       headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 401


def test_push_503_when_unconfigured(client):
    key = db.create_key("a@x.com", None)
    resp = client.post("/push", json={"tokens": ["t"], "title": "x", "body": "y"},
                       headers={"Authorization": f"Bearer {key}"})
    assert resp.status_code == 503                        # APNs creds absent


def test_push_forwards_and_returns_dead(client, monkeypatch):
    key = db.create_key("a@x.com", None)
    saved = (settings.apns_key_id, settings.apns_team_id, settings.apns_bundle_id, settings.apns_auth_key)
    settings.apns_key_id, settings.apns_team_id = "K", "T"
    settings.apns_bundle_id, settings.apns_auth_key = "money.cleave.app", "x"

    async def fake_send(_client, token, title, body):
        return token == "dead-token"                     # one token is dead
    monkeypatch.setattr(apns, "send", fake_send)
    try:
        resp = client.post("/push", json={"tokens": ["good", "dead-token"], "title": "Hi", "body": "yo"},
                           headers={"Authorization": f"Bearer {key}"})
        assert resp.status_code == 200
        assert resp.json()["dead"] == ["dead-token"]
    finally:
        (settings.apns_key_id, settings.apns_team_id,
         settings.apns_bundle_id, settings.apns_auth_key) = saved


def _configure_apns():
    saved = (settings.apns_key_id, settings.apns_team_id, settings.apns_bundle_id, settings.apns_auth_key)
    settings.apns_key_id, settings.apns_team_id = "K", "T"
    settings.apns_bundle_id, settings.apns_auth_key = "money.cleave.app", "x"
    return saved


def test_push_forwards_encrypted_messages(client, monkeypatch):
    key = db.create_key("a@x.com", None)
    saved = _configure_apns()
    seen = []

    async def fake_enc(_c, token, ft, fb, epk, box):
        seen.append((token, ft, fb, epk, box))
        return token == "dead-enc"
    monkeypatch.setattr(apns, "send_encrypted", fake_enc)
    try:
        resp = client.post("/push", json={
            "messages": [{"token": "good", "epk": "E1", "box": "B1"},
                         {"token": "dead-enc", "epk": "E2", "box": "B2"}],
            "fallback_title": "Cleave", "fallback_body": "New activity"},
            headers={"Authorization": f"Bearer {key}"})
        assert resp.status_code == 200
        assert resp.json()["dead"] == ["dead-enc"]
        assert seen[0] == ("good", "Cleave", "New activity", "E1", "B1")
    finally:
        (settings.apns_key_id, settings.apns_team_id,
         settings.apns_bundle_id, settings.apns_auth_key) = saved


def test_require_e2ee_rejects_plaintext_accepts_messages(client, monkeypatch):
    key = db.create_key("a@x.com", None)
    saved = _configure_apns()
    settings.require_e2ee = True

    async def fake_enc(*a):
        return False
    monkeypatch.setattr(apns, "send_encrypted", fake_enc)
    try:
        plain = client.post("/push", json={"tokens": ["t"], "title": "x", "body": "secret"},
                            headers={"Authorization": f"Bearer {key}"})
        assert plain.status_code == 400                       # plaintext refused
        enc = client.post("/push", json={"messages": [{"token": "t", "epk": "E", "box": "B"}]},
                          headers={"Authorization": f"Bearer {key}"})
        assert enc.status_code == 200                         # ciphertext accepted
    finally:
        settings.require_e2ee = False
        (settings.apns_key_id, settings.apns_team_id,
         settings.apns_bundle_id, settings.apns_auth_key) = saved


def test_provider_token_builds():
    pem = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    saved = (settings.apns_key_id, settings.apns_team_id, settings.apns_auth_key)
    apns._token_cache = None
    settings.apns_key_id, settings.apns_team_id = "KID", "TEAM"
    settings.apns_auth_key = base64.b64encode(pem).decode()
    try:
        header = pyjwt.get_unverified_header(apns._provider_token())
        assert header["alg"] == "ES256" and header["kid"] == "KID"
    finally:
        settings.apns_key_id, settings.apns_team_id, settings.apns_auth_key = saved
        apns._token_cache = None


def test_health(client):
    assert client.get("/health").json()["status"] == "ok"


def _basic(user: str, password: str) -> dict:
    return {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}


def test_admin_requires_auth_and_challenges(client):
    saved = settings.admin_token
    settings.admin_token = "s3cret"
    try:
        resp = client.get("/admin/keys")
        assert resp.status_code == 401
        assert resp.headers["WWW-Authenticate"].startswith("Basic ")
    finally:
        settings.admin_token = saved


def test_admin_basic_auth_lists_and_rejects_wrong_password(client):
    saved = settings.admin_token
    settings.admin_token = "s3cret"
    try:
        db.create_key("a@x.com", "house")
        ok = client.get("/admin/keys", headers=_basic("admin", "s3cret"))
        assert ok.status_code == 200
        keys = ok.json()["keys"]
        assert len(keys) == 1 and keys[0]["email"] == "a@x.com"
        assert "key_hash" not in keys[0]
        assert client.get("/admin/keys", headers=_basic("admin", "wrong")).status_code == 401
    finally:
        settings.admin_token = saved


def test_admin_issue_key_authenticates_push(client, monkeypatch):
    saved_token = settings.admin_token
    settings.admin_token = "s3cret"
    saved_apns = _configure_apns()

    async def fake_send(_client, token, title, body):
        return False
    monkeypatch.setattr(apns, "send", fake_send)
    try:
        issued = client.post("/admin/keys", json={"email": "a@x.com", "instance": "house"},
                             headers=_basic("admin", "s3cret"))
        assert issued.status_code == 200
        key = issued.json()["key"]
        assert key.startswith("relaysk_")
        push = client.post("/push", json={"tokens": ["t"], "title": "x", "body": "y"},
                           headers={"Authorization": f"Bearer {key}"})
        assert push.status_code == 200                        # active immediately
    finally:
        settings.admin_token = saved_token
        (settings.apns_key_id, settings.apns_team_id,
         settings.apns_bundle_id, settings.apns_auth_key) = saved_apns


def test_admin_delete_key(client):
    saved = settings.admin_token
    settings.admin_token = "s3cret"
    try:
        db.create_key("a@x.com", None)
        key_id = db.list_keys()[0]["id"]
        assert client.delete(f"/admin/keys/{key_id}", headers=_basic("admin", "s3cret")).status_code == 200
        assert db.list_keys() == []
        assert client.delete(f"/admin/keys/{key_id}", headers=_basic("admin", "s3cret")).status_code == 404
    finally:
        settings.admin_token = saved


def test_admin_bearer_still_works(client):
    saved = settings.admin_token
    settings.admin_token = "s3cret"
    try:
        db.create_key("a@x.com", None)
        key_id = db.list_keys()[0]["id"]
        resp = client.post(f"/admin/keys/{key_id}/revoke",
                           headers={"Authorization": "Bearer s3cret"})
        assert resp.status_code == 200
    finally:
        settings.admin_token = saved
