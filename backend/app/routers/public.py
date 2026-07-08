"""Unguarded public endpoints used during onboarding (before the app has adopted this backend),
plus the browser/Apple-facing join site (this backend serves it directly - no separate static host)."""
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app import server_settings
from app.config import settings
from app.db import get_session
from app.schemas.public import ServerInfo

router = APIRouter(tags=["public"])

_VERSION = "0.1.0"
_STATIC = Path(__file__).resolve().parent.parent / "static"
_JOIN_HTML = _STATIC / "join.html"
_DEMO_HTML = _STATIC / "demo.html"


@router.get("/server-info", response_model=ServerInfo)
async def server_info(session: AsyncSession = Depends(get_session)) -> ServerInfo:
    """Identity the iOS app pings to verify a URL is really a Cleave backend before adopting it
    (the join-link confirm screen). Reveals nothing sensitive."""
    providers: list[str] = []
    if settings.apple_audience:
        providers.append("apple")
    if settings.google_client_id:
        providers.append("google")
    if settings.splitwise_consumer_key:
        providers.append("splitwise")
    public_hostname = await server_settings.get(session, "public_hostname")
    return ServerInfo(
        app=settings.app_name,
        version=_VERSION,
        name=public_hostname or settings.app_name,
        # A server that can sign people in always shows the gate (incl. a fresh, unclaimed one).
        requires_auth=bool(providers or settings.auth_required or settings.api_tokens),
        auth_providers=providers,
        demo=settings.demo_mode,
        push_configured=settings.push_configured,
        plaid_configured=settings.plaid_configured,
        plaid_enabled=bool(await server_settings.get(session, "plaid_enabled")),
        simplefin_enabled=bool(await server_settings.get(session, "simplefin_enabled")),
    )


@router.get("/.well-known/apple-app-site-association", include_in_schema=False)
async def apple_app_site_association() -> JSONResponse:
    """Universal Links association, served as application/json. 404 until APPLE_TEAM_ID is set."""
    if not settings.apple_team_id or not settings.apple_audience:
        raise HTTPException(status_code=404, detail="Universal Links not configured")
    app_id = f"{settings.apple_team_id}.{settings.apple_audience}"
    return JSONResponse(
        {
            "applinks": {
                "details": [
                    {
                        "appID": app_id,
                        # /join* = onboarding deep link; /demo* = demo landing; /plaid/oauth* = Plaid OAuth return.
                        "components": [{"/": "/join*"}, {"/": "/demo*"}, {"/": "/plaid/oauth*"}],
                    }
                ]
            }
        }
    )


@router.get("/join", include_in_schema=False)
async def join() -> FileResponse:
    """The onboarding landing page (install + invite QR + endpoint). Reads ?api= / &name=
    client-side, defaulting to this host."""
    return FileResponse(_JOIN_HTML, media_type="text/html")


@router.get("/demo", include_in_schema=False)
async def demo() -> FileResponse:
    """Friend-facing demo landing page: install the app + one tap into a guest session against THIS
    backend (which defaults its own origin as the api). Only meaningful on a demo backend, so 404 when
    DEMO_MODE is off - the guest login (POST /auth/demo) 404s there too."""
    if not settings.demo_mode:
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(_DEMO_HTML, media_type="text/html")
