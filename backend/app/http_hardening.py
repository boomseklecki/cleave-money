"""HTTP hardening middleware (security headers + optional Host allow-list / CORS).

Factored out of `main.py` so it can be installed on a minimal app in tests without importing the full app
(which would trigger the infra-touching lifespan). All three are safe defaults: the headers are always on,
Host/CORS are opt-in (empty lists ⇒ not mounted, so dev/default behavior is unchanged).
"""
from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware


def install_hardening(
    app: FastAPI, *, allowed_hosts: list[str], cors_allowed_origins: list[str]
) -> None:
    """Add baseline security headers to every response, plus (when configured) a Host allow-list and CORS.

    Order matters: Host/CORS are added AFTER the header middleware so they run outermost - a spoofed Host is
    rejected before it reaches any handler."""

    @app.middleware("http")
    async def _security_headers(request: Request, call_next):
        # Most relevant for the browser-facing pages this backend serves itself (join.html, the Splitwise
        # OAuth redirects); inert on JSON. The CSP is limited to non-resource-restricting directives so it
        # doesn't break join.html's inline styles + CDN QR script.
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("Content-Security-Policy", "frame-ancestors 'none'; base-uri 'none'")
        response.headers.setdefault("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
        return response

    if cors_allowed_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=cors_allowed_origins,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )
    if allowed_hosts:
        app.add_middleware(TrustedHostMiddleware, allowed_hosts=allowed_hosts)
