"""Admin-curated merchant→logo catalog (the favicon keyword→domain map the app resolves against). GET is
readable by any enrolled member so the client can resolve favicons; PUT (replace-all) is admin-only. The
table is seeded from the app's built-in catalog by migration 0054, so admins start from the shipped defaults
and can add / edit / delete any row."""
from fastapi import APIRouter, Depends
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_admin, require_auth
from app.db import get_session
from app.models import BrandOverride
from app.schemas.brand import BrandOverrideItem, BrandOverridesUpdate

router = APIRouter(prefix="/brand-overrides", tags=["brand-overrides"])


async def _ordered(session: AsyncSession) -> list[BrandOverrideItem]:
    rows = await session.scalars(
        select(BrandOverride).order_by(BrandOverride.position, BrandOverride.pattern)
    )
    return [BrandOverrideItem(pattern=r.pattern, name=r.name, domain=r.domain) for r in rows]


@router.get("", response_model=list[BrandOverrideItem])
async def list_brand_overrides(
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[BrandOverrideItem]:
    return await _ordered(session)


@router.put("", response_model=list[BrandOverrideItem])
async def replace_brand_overrides(
    body: BrandOverridesUpdate,
    caller: str = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
) -> list[BrandOverrideItem]:
    # Replace-all: the editor sends the full desired catalog; drop and re-insert in the given order so add /
    # edit / delete are one uniform operation. De-dupe by normalized pattern (last wins) to keep the primary
    # key unique. The explicit Core DELETE runs before the ORM inserts flush, avoiding a PK clash when a
    # pattern is both removed and re-added in the same request.
    seen: dict[str, BrandOverrideItem] = {}
    for item in body.items:
        key = item.pattern.strip().lower()
        if key:
            seen[key] = item
    await session.execute(delete(BrandOverride))
    for pos, item in enumerate(seen.values()):
        session.add(BrandOverride(
            pattern=item.pattern.strip(), name=item.name.strip(), domain=item.domain.strip(), position=pos
        ))
    await session.commit()
    return await _ordered(session)
