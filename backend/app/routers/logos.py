"""Brand logo proxy for the Subscriptions feature.

The iOS app points `AvatarView` at `GET /logos/{domain}`; this resolves the logo from a configurable
upstream the first time, caches the bytes in MinIO, and serves them thereafter - so merchant domains only
ever leave the *self-hosted* backend, never the app. Public (no bearer): the token-less AsyncImage loads
it directly, and a brand logo is not user data.

Favicon-less domains are negative-cached (a tiny `logos/{domain}.missing.img` marker) for
`NEGATIVE_TTL_SECONDS`, so a long list of resolvable-but-favicon-less merchants doesn't re-run the
up-to-8s upstream fetch on every request. `fetch_favicon` returns None for both a definite miss and a
transient upstream timeout, so a transient failure negatively-caches until the TTL lapses - bounded and
self-healing (a domain that later gains a favicon clears its stale marker on the next miss).
"""
import asyncio

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response

from app.integrations import logos
from app.integrations.storage import minio_client

router = APIRouter(tags=["logos"])

NEGATIVE_TTL_SECONDS = 7 * 24 * 3600  # a favicon-less domain re-checks upstream at most weekly


@router.get("/logos/{domain}")
async def brand_logo(domain: str, variant: str | None = None) -> Response:
    domain = domain.lower()
    if not logos.DOMAIN_RE.match(domain):
        raise HTTPException(status_code=404, detail="Not found")

    # `variant=plaid` serves Plaid's full logo if it's been seeded; any other/absent variant (and the
    # plaid fallback below) serves the default favicon, resolving it on demand on a cache miss.
    if variant == "plaid":
        plaid_key = logos.object_key(domain, "plaid")
        if await asyncio.to_thread(minio_client.object_exists, plaid_key):
            data = await asyncio.to_thread(minio_client.get_bytes, plaid_key)
            return Response(content=data, media_type="image/png")
        # fall through to the default favicon so an un-seeded bank still shows an icon rather than 404ing

    object_key = logos.object_key(domain)
    if await asyncio.to_thread(minio_client.object_exists, object_key):
        data = await asyncio.to_thread(minio_client.get_bytes, object_key)
        return Response(content=data, media_type="image/png")

    missing_key = logos.object_key(domain, "missing")
    age = await asyncio.to_thread(minio_client.age_seconds, missing_key)
    if age is not None and age < NEGATIVE_TTL_SECONDS:
        raise HTTPException(status_code=404, detail="No logo")  # fast 404, no upstream fetch

    data = await asyncio.to_thread(logos.fetch_favicon, domain)
    if data is None:
        await asyncio.to_thread(minio_client.put_object, missing_key, b"", "application/octet-stream")
        raise HTTPException(status_code=404, detail="No logo")

    await asyncio.to_thread(minio_client.put_object, object_key, data, "image/png")
    if age is not None:  # a stale marker existed and upstream now has a favicon → clear it (self-heal)
        await asyncio.to_thread(minio_client.remove, missing_key)
    return Response(content=data, media_type="image/png")
