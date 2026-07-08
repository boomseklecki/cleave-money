"""GET /server-info: identity shape + requires_auth/auth_providers reflect config (name now comes from the
server_settings `public_hostname`); GET /.well-known/apple-app-site-association: 404 until APPLE_TEAM_ID set."""
import json

from fastapi import HTTPException

from app.config import settings
from app.db import async_session
from app.routers.public import apple_app_site_association, demo, server_info


async def test_server_info_shape():
    async with async_session() as s:
        info = await server_info(session=s)
    assert info.app == settings.app_name
    assert info.version
    assert info.name  # public_hostname (server setting) or app_name
    assert isinstance(info.auth_providers, list)


async def test_requires_auth_reflects_config():
    orig = (settings.auth_required, settings.api_tokens,
            settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key)
    try:
        # No providers, no auth_required, no tokens -> open.
        settings.apple_audience = settings.google_client_id = settings.splitwise_consumer_key = ""
        settings.auth_required, settings.api_tokens = False, {}
        async with async_session() as s:
            assert (await server_info(session=s)).requires_auth is False
        # Any of auth_required / api_tokens / a configured provider flips the gate on.
        settings.auth_required = True
        async with async_session() as s:
            assert (await server_info(session=s)).requires_auth is True
        settings.auth_required, settings.api_tokens = False, {"tok": "alice"}
        async with async_session() as s:
            assert (await server_info(session=s)).requires_auth is True
        settings.api_tokens, settings.google_client_id = {}, "gid"
        async with async_session() as s:
            assert (await server_info(session=s)).requires_auth is True
    finally:
        (settings.auth_required, settings.api_tokens,
         settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key) = orig


async def test_auth_providers_reflect_config():
    orig = (settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key)
    try:
        settings.apple_audience = "money.cleave.app"
        settings.google_client_id = ""
        settings.splitwise_consumer_key = "key"
        async with async_session() as s:
            providers = (await server_info(session=s)).auth_providers
        assert "apple" in providers
        assert "splitwise" in providers
        assert "google" not in providers
    finally:
        settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key = orig


async def test_aasa_404_until_team_id_set():
    orig = settings.apple_team_id
    try:
        settings.apple_team_id = ""
        try:
            await apple_app_site_association()
        except HTTPException as exc:
            assert exc.status_code == 404
        else:
            raise AssertionError("expected 404")
    finally:
        settings.apple_team_id = orig


async def test_aasa_appid_when_configured():
    orig_team, orig_aud = settings.apple_team_id, settings.apple_audience
    try:
        settings.apple_team_id = "ABCDE12345"
        settings.apple_audience = "money.cleave.app"
        resp = await apple_app_site_association()
        body = json.loads(resp.body)
        appid = body["applinks"]["details"][0]["appID"]
        assert appid == "ABCDE12345.money.cleave.app"
        # The demo landing is claimed as a universal link alongside join + Plaid OAuth.
        paths = [c["/"] for c in body["applinks"]["details"][0]["components"]]
        assert "/demo*" in paths and "/join*" in paths
    finally:
        settings.apple_team_id, settings.apple_audience = orig_team, orig_aud


async def test_push_configured_reflects_relay():
    """/server-info exposes push_configured (relay URL + key both set) so the app shows the push toggle only
    where a relay exists."""
    orig = (settings.push_relay_url, settings.push_relay_api_key)
    try:
        settings.push_relay_url = settings.push_relay_api_key = ""
        async with async_session() as s:
            assert (await server_info(session=s)).push_configured is False
        settings.push_relay_url, settings.push_relay_api_key = "https://relay.example", "k"
        async with async_session() as s:
            assert (await server_info(session=s)).push_configured is True
    finally:
        settings.push_relay_url, settings.push_relay_api_key = orig


async def test_bank_link_capabilities():
    """/server-info exposes plaid_configured (Plaid creds set) + simplefin_enabled so the app offers only the
    enabled "connect a bank" methods."""
    orig = (settings.plaid_client_id, settings.plaid_secret)
    try:
        settings.plaid_client_id = settings.plaid_secret = ""
        async with async_session() as s:
            info = await server_info(session=s)
        assert info.plaid_configured is False
        assert info.plaid_enabled is True      # admin toggle, registry default on (app ANDs it with configured)
        assert info.simplefin_enabled is True  # SimpleFIN needs no server creds -> registry default on
        settings.plaid_client_id, settings.plaid_secret = "cid", "sec"
        async with async_session() as s:
            assert (await server_info(session=s)).plaid_configured is True
    finally:
        settings.plaid_client_id, settings.plaid_secret = orig


async def test_plaid_linking_gate():
    """New Plaid links require creds AND the plaid_enabled toggle; existing items sync regardless."""
    from fastapi import HTTPException

    from app import server_settings
    from app.routers.plaid import _plaid_linking_enabled_or_404

    async def _raises() -> bool:
        async with async_session() as s:
            try:
                await _plaid_linking_enabled_or_404(s)
                return False
            except HTTPException as e:
                return e.status_code == 404

    orig = (settings.plaid_client_id, settings.plaid_secret)
    try:
        settings.plaid_client_id = settings.plaid_secret = ""
        assert await _raises() is True                      # no creds -> blocked
        settings.plaid_client_id, settings.plaid_secret = "cid", "sec"
        assert await _raises() is False                     # creds + enabled (default) -> allowed
        async with async_session() as s:
            await server_settings.set_value(s, "plaid_enabled", False)
            await s.commit()
        assert await _raises() is True                      # creds + admin-disabled -> blocked
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "plaid_enabled", True)
            await s.commit()
        settings.plaid_client_id, settings.plaid_secret = orig


async def test_demo_landing_gated_on_demo_mode():
    orig = settings.demo_mode
    try:
        # Off (prod/dev): the friend-facing demo page 404s, mirroring POST /auth/demo.
        settings.demo_mode = False
        try:
            await demo()
        except HTTPException as exc:
            assert exc.status_code == 404
        else:
            raise AssertionError("expected 404 when demo_mode off")
        # On (demo backend): serves the landing page.
        settings.demo_mode = True
        resp = await demo()
        assert resp.media_type == "text/html" and str(resp.path).endswith("demo.html")
    finally:
        settings.demo_mode = orig


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
