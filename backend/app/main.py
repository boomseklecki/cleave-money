import asyncio
import contextlib
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI

from app.auth import require_auth
from app.http_hardening import install_hardening
from app.config import settings
from app.integrations.storage import minio_client
from app.routers import (
    accounts,
    auth,
    avatars,
    backups,
    balances,
    brand_overrides,
    categories,
    connections,
    devices,
    expenses,
    exports,
    goals,
    groups,
    health,
    institutions,
    invites,
    logos,
    notification_mutes,
    notifications,
    plaid,
    preferences,
    public,
    receipts,
    server_settings,
    simplefin,
    statements,
    splitwise,
    splitwise_auth,
    users,
)
from app.services.backup_scheduler import run_scheduler as run_backup_scheduler
from app.services.demo_prune_scheduler import run_scheduler as run_demo_prune_scheduler
from app.services.notifications_scheduler import run_scheduler as run_notifications_scheduler
from app.services.sync_scheduler import run_scheduler as run_sync_scheduler
from app.security.key_check import check_encryption_key_health


@asynccontextmanager
async def lifespan(app: FastAPI):
    # MinIO may start a moment after the API; retry the bucket check briefly.
    for _ in range(10):
        try:
            await asyncio.to_thread(minio_client.ensure_bucket)
            break
        except Exception:
            await asyncio.sleep(1)
    # Warn early if the configured ENCRYPTION_KEYS can't decrypt the stored tokens (e.g. a DB restored
    # without its key) - integrations would silently fail otherwise. Best-effort; never blocks startup.
    with contextlib.suppress(Exception):
        await check_encryption_key_health()
    # Background loops: scheduled backups + periodic data sync (each polls and re-reads its interval from the
    # server settings every tick, paused while <= 0), plus the demo-guest pruner (no-op unless DEMO_MODE).
    tasks = [
        asyncio.create_task(run_backup_scheduler()),
        asyncio.create_task(run_sync_scheduler()),
        asyncio.create_task(run_notifications_scheduler()),  # fast notifications-only poll (off unless enabled)
        asyncio.create_task(run_demo_prune_scheduler()),
    ]
    try:
        yield
    finally:
        for task in tasks:
            task.cancel()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await task


app = FastAPI(title=settings.app_name, version="0.1.0", lifespan=lifespan)
install_hardening(
    app,
    allowed_hosts=settings.allowed_hosts,
    cors_allowed_origins=settings.cors_allowed_origins,
)

# Open: healthchecks, sign-in, and the Splitwise OAuth browser redirect can't carry a bearer.
app.include_router(health.router)
app.include_router(public.router)
app.include_router(auth.router)
app.include_router(splitwise_auth.router)
app.include_router(logos.router)  # public: token-less AsyncImage loads brand logos; not user data

# Guarded by bearer auth when API_TOKENS is configured (pass-through otherwise).
_protected = [Depends(require_auth)]
app.include_router(groups.router, dependencies=_protected)
app.include_router(expenses.router, dependencies=_protected)
app.include_router(exports.router, dependencies=_protected)
app.include_router(receipts.router, dependencies=_protected)
app.include_router(avatars.router, dependencies=_protected)
app.include_router(plaid.router, dependencies=_protected)
app.include_router(simplefin.router, dependencies=_protected)
app.include_router(accounts.router, dependencies=_protected)
app.include_router(statements.router, dependencies=_protected)
app.include_router(users.router, dependencies=_protected)
app.include_router(balances.router, dependencies=_protected)
app.include_router(splitwise.router, dependencies=_protected)
app.include_router(goals.router, dependencies=_protected)
app.include_router(connections.router, dependencies=_protected)
app.include_router(devices.router, dependencies=_protected)
app.include_router(notifications.router, dependencies=_protected)
app.include_router(notification_mutes.router, dependencies=_protected)
app.include_router(preferences.router, dependencies=_protected)
app.include_router(categories.router, dependencies=_protected)
app.include_router(institutions.router, dependencies=_protected)  # reference data (OFX-importable banks)
app.include_router(brand_overrides.router)  # self-gates: GET require_auth, PUT require_admin
app.include_router(backups.router)  # each route self-gates with require_admin
app.include_router(invites.router)  # self-gates: require_can_invite (admin, or any member when allowed)
app.include_router(server_settings.router)  # self-gates: GET require_auth, PATCH require_admin


@app.get("/")
async def root() -> dict[str, str]:
    return {"app": settings.app_name, "status": "running"}
