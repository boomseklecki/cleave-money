"""Shared brand/institution logo helpers.

A logo is cached in MinIO under `logos/{domain}.img` and served by the `/logos/{domain}` proxy. Both the proxy
(on-demand) and the Plaid institution resolver (pre-warm at sync) fetch favicons through `fetch_favicon`, so
there's a single upstream code path. All calls here are blocking - wrap in asyncio.to_thread.
"""
import re

import requests

from app.config import settings

# Conservative domain shape (lowercased host, e.g. "netflix.com"). Keeps the cache key + upstream URL safe.
DOMAIN_RE = re.compile(r"^[a-z0-9.-]{3,255}$")


def object_key(domain: str, variant: str | None = None) -> str:
    """Cache key for a domain's logo. The default (favicon) lives at `logos/{domain}.img`; a named variant
    (e.g. Plaid's full logo) lives alongside it at `logos/{domain}.{variant}.img`."""
    return f"logos/{domain}.{variant}.img" if variant else f"logos/{domain}.img"


def fetch_favicon(domain: str) -> bytes | None:
    """Image bytes for a domain's favicon from the configured upstream, or None on any failure / non-image."""
    url = settings.logo_upstream_template.format(domain=domain)
    try:
        resp = requests.get(url, timeout=8, allow_redirects=True)
    except requests.RequestException:
        return None
    if resp.status_code != 200 or not resp.content:
        return None
    if not resp.headers.get("Content-Type", "").startswith("image/"):
        return None
    return resp.content
