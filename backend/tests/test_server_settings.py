"""server_settings registry: typed get/set round-trip + coercion; PATCH is admin-only and a reader reflects
the change. DB-backed."""
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import delete

from app import server_settings
from app.auth import require_admin
from app.db import async_session
from app.models import ServerSetting, User
from app.models.enums import UserSource
from app.routers.server_settings import update_server_settings
from app.schemas.server_settings import ServerSettingsUpdate

PREFIX = "sset-zzz"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(User).where(User.identifier.like(f"{PREFIX}%")))
        await s.commit()


async def test_set_get_roundtrip_and_coercion():
    async with async_session() as s:
        original = await server_settings.get(s, "sync_interval_hours")
    try:
        async with async_session() as s:
            await server_settings.set_value(s, "sync_interval_hours", 9)
            await s.commit()
        async with async_session() as s:
            assert await server_settings.get(s, "sync_interval_hours") == 9
        # A string value coerces to the registry int type.
        async with async_session() as s:
            await server_settings.set_value(s, "sync_interval_hours", "13")
            await s.commit()
        async with async_session() as s:
            assert await server_settings.get(s, "sync_interval_hours") == 13
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "sync_interval_hours", original)
            await s.commit()


async def test_patch_admin_gate_and_subset_update():
    await _purge()
    async with async_session() as s:
        s.add_all([
            User(identifier=f"{PREFIX}-admin", display_name="A", source=UserSource.app,
                 enrolled=True, is_admin=True),
            User(identifier=f"{PREFIX}-member", display_name="M", source=UserSource.app, enrolled=True),
        ])
        await s.commit()
        original = await server_settings.get(s, "splitwise_receipt_download_enabled")
    try:
        # require_admin forbids a non-admin member.
        async with async_session() as s:
            try:
                await require_admin(f"{PREFIX}-member", s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
        # An admin PATCH updates only the provided key; a reader reflects it.
        async with async_session() as s:
            resp = await update_server_settings(
                ServerSettingsUpdate(splitwise_receipt_download_enabled=True),
                caller=f"{PREFIX}-admin", session=s)
            assert resp.splitwise_receipt_download_enabled is True
        async with async_session() as s:
            assert await server_settings.get(s, "splitwise_receipt_download_enabled") is True
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "splitwise_receipt_download_enabled", original)
            await s.commit()
        await _purge()


async def test_notifications_retention_roundtrip():
    """The new notifications_retention_count key is in the registry and PATCH/GET round-trips."""
    async with async_session() as s:
        original = await server_settings.get(s, "notifications_retention_count")
    try:
        async with async_session() as s:
            await server_settings.set_value(s, "notifications_retention_count", 42)
            await s.commit()
        async with async_session() as s:
            assert await server_settings.get(s, "notifications_retention_count") == 42
            assert (await server_settings.get_all(s))["notifications_retention_count"] == 42
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "notifications_retention_count", original)
            await s.commit()


async def test_push_enabled_and_default_currency_roundtrip():
    """The push_enabled + default_currency keys are in the registry, surface in get_all (alongside
    budget_push_enabled), and PATCH/GET round-trip."""
    async with async_session() as s:
        orig_push = await server_settings.get(s, "push_enabled")
        orig_cur = await server_settings.get(s, "default_currency")
        all0 = await server_settings.get_all(s)
    assert "push_enabled" in all0 and "budget_push_enabled" in all0 and "default_currency" in all0
    try:
        async with async_session() as s:
            await server_settings.set_value(s, "push_enabled", False)
            await server_settings.set_value(s, "default_currency", "EUR")
            await s.commit()
        async with async_session() as s:
            assert await server_settings.get(s, "push_enabled") is False
            assert await server_settings.get(s, "default_currency") == "EUR"
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "push_enabled", orig_push)
            await server_settings.set_value(s, "default_currency", orig_cur)
            await s.commit()


async def test_simplefin_settings_roundtrip():
    """The SimpleFIN keys are in the registry, surface in get_all, and PATCH/GET round-trip."""
    async with async_session() as s:
        orig_stale = await server_settings.get(s, "refresh_simplefin_stale_minutes")
        orig_enabled = await server_settings.get(s, "simplefin_enabled")
        all0 = await server_settings.get_all(s)
    assert "refresh_simplefin_stale_minutes" in all0 and "simplefin_enabled" in all0
    assert "plaid_enabled" in all0
    assert all0["simplefin_enabled"] is True and all0["plaid_enabled"] is True  # registry defaults
    try:
        async with async_session() as s:
            await server_settings.set_value(s, "refresh_simplefin_stale_minutes", 360)
            await server_settings.set_value(s, "simplefin_enabled", False)
            await s.commit()
        async with async_session() as s:
            assert await server_settings.get(s, "refresh_simplefin_stale_minutes") == 360
            assert await server_settings.get(s, "simplefin_enabled") is False
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "refresh_simplefin_stale_minutes", orig_stale)
            await server_settings.set_value(s, "simplefin_enabled", orig_enabled)
            await s.commit()


async def test_internal_timestamp_marker():
    key = f"{PREFIX}-marker"
    when = datetime(2025, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    try:
        async with async_session() as s:
            await server_settings.set_timestamp(s, key, when)
            await s.commit()
        async with async_session() as s:
            assert await server_settings.get_timestamp(s, key) == when  # round-trips
            assert await server_settings.get_timestamp(s, f"{PREFIX}-absent") is None
            assert key not in await server_settings.get_all(s)  # internal markers stay out of the API dict
    finally:
        async with async_session() as s:
            await s.execute(delete(ServerSetting).where(ServerSetting.key == key))
            await s.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
