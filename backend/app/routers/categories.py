from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.db import get_session
from app.models.category_map import CategoryMap
from app.models.spend_category import SpendCategory
from app.schemas.category import (
    CategoryConfig,
    CategoryConfigUpsert,
    CategoryMapItem,
    SpendCategoryItem,
)

router = APIRouter(tags=["categories"])


@router.get("/categories", response_model=CategoryConfig)
async def get_categories(
    caller: str | None = Depends(require_auth), session: AsyncSession = Depends(get_session)
) -> CategoryConfig:
    """The caller's category taxonomy + raw→canonical map (empty in open mode). `updated_at` is the newest
    row timestamp - the client's last-write-wins watermark, replacing the old `categories.v1` blob's."""
    if caller is None:
        return CategoryConfig()
    cats = list(
        await session.scalars(
            select(SpendCategory)
            .where(SpendCategory.owner_identifier == caller)
            .order_by(SpendCategory.position)
        )
    )
    maps = list(
        await session.scalars(
            select(CategoryMap).where(CategoryMap.owner_identifier == caller)
        )
    )
    stamps = [r.updated_at for r in (*cats, *maps)]
    return CategoryConfig(
        categories=[SpendCategoryItem.model_validate(c) for c in cats],
        maps=[CategoryMapItem.model_validate(m) for m in maps],
        updated_at=max(stamps) if stamps else None,
    )


@router.put("/categories", response_model=CategoryConfig)
async def put_categories(
    body: CategoryConfigUpsert,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> CategoryConfig:
    """Idempotent owner-scoped replace-set: the caller's taxonomy + map become exactly the payload (rows
    absent from it are deleted), in one transaction - mirroring the old whole-blob snapshot semantics
    relationally. Device-authoritative; the app owns the set and pushes it after local edits."""
    if caller is None:
        raise HTTPException(status_code=401, detail="Sign in to save categories")
    await session.execute(delete(SpendCategory).where(SpendCategory.owner_identifier == caller))
    await session.execute(delete(CategoryMap).where(CategoryMap.owner_identifier == caller))
    # De-dupe by key within the payload (the unique constraints would otherwise reject a malformed set).
    seen_names: set[str] = set()
    for c in body.categories:
        if c.name in seen_names:
            continue
        seen_names.add(c.name)
        session.add(
            SpendCategory(
                owner_identifier=caller,
                name=c.name,
                icon=c.icon,
                color=c.color,
                position=c.position,
                builtin=c.builtin,
            )
        )
    seen_raw: set[str] = set()
    for m in body.maps:
        if m.raw_category in seen_raw:
            continue
        seen_raw.add(m.raw_category)
        session.add(
            CategoryMap(
                owner_identifier=caller,
                raw_category=m.raw_category,
                canonical_category=m.canonical_category,
                source=m.source,
            )
        )
    await session.commit()
    return await get_categories(caller=caller, session=session)
