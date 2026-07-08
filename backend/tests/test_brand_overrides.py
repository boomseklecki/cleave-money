"""brand_overrides: migration seeds the built-in catalog; the replace-all PUT (admin-only) adds/edits/deletes
and de-dupes, preserving order. Patterns (substring / glob / regex) are stored verbatim; matching is on-device.
DB-backed."""
from fastapi import HTTPException
from sqlalchemy import delete, select

from app.auth import require_admin
from app.db import async_session
from app.models import BrandOverride, User
from app.models.enums import UserSource
from app.routers.brand_overrides import list_brand_overrides, replace_brand_overrides
from app.schemas.brand import BrandOverrideItem, BrandOverridesUpdate

PREFIX = "brand-zzz"


async def _snapshot() -> list[BrandOverride]:
    async with async_session() as s:
        rows = (await s.scalars(select(BrandOverride).order_by(BrandOverride.position))).all()
        return [BrandOverride(pattern=r.pattern, name=r.name, domain=r.domain, position=r.position) for r in rows]


async def _restore(rows: list[BrandOverride]) -> None:
    async with async_session() as s:
        await s.execute(delete(BrandOverride))
        for r in rows:
            s.add(BrandOverride(pattern=r.pattern, name=r.name, domain=r.domain, position=r.position))
        await s.commit()


async def test_migration_seeded_builtins():
    """A fresh migrated DB carries the shipped catalog, so favicons work before any admin curation."""
    async with async_session() as s:
        items = await list_brand_overrides(caller=None, session=s)
    patterns = {i.pattern for i in items}
    assert "netflix" in patterns and "spotify" in patterns
    netflix = next(i for i in items if i.pattern == "netflix")
    assert netflix.domain == "netflix.com"


async def test_admin_replace_add_edit_delete_and_dedupe():
    saved = await _snapshot()
    try:
        # pattern upper-cased + whitespaced (dedupes to "netflix"), duplicated (last wins), plus a new brand.
        body = BrandOverridesUpdate(items=[
            BrandOverrideItem(pattern=" NETFLIX ", name="Netflix", domain="netflix.com"),
            BrandOverrideItem(pattern="netflix", name="Netflix Reordered", domain="netflix.com"),
            BrandOverrideItem(pattern="duolingo", name="Duolingo", domain="duolingo.com"),
        ])
        async with async_session() as s:
            resp = await replace_brand_overrides(body, caller=f"{PREFIX}-admin", session=s)
        # De-duped to two, in submission order; the second netflix entry won.
        assert [i.pattern for i in resp] == ["netflix", "duolingo"]
        netflix = next(i for i in resp if i.pattern == "netflix")
        assert netflix.name == "Netflix Reordered"
        # Everything else from the seed was deleted (replace-all).
        async with async_session() as s:
            remaining = {i.pattern for i in await list_brand_overrides(caller=None, session=s)}
        assert remaining == {"netflix", "duolingo"}
    finally:
        await _restore(saved)


async def test_glob_and_regex_patterns_stored_verbatim():
    """Glob and regex patterns round-trip unchanged, with case preserved (matching is case-insensitive
    on-device, so a regex can keep its original casing for display)."""
    saved = await _snapshot()
    try:
        body = BrandOverridesUpdate(items=[
            BrandOverrideItem(pattern="aldi*", name="Aldi", domain="aldi.us"),
            BrandOverrideItem(pattern="giant?eagle", name="Giant Eagle", domain="gianteagle.com"),
            BrandOverrideItem(pattern="/Lidl|Kroger/", name="Grocery", domain=""),
        ])
        async with async_session() as s:
            resp = await replace_brand_overrides(body, caller=f"{PREFIX}-admin", session=s)
        assert [i.pattern for i in resp] == ["aldi*", "giant?eagle", "/Lidl|Kroger/"]
        assert next(i for i in resp if i.pattern == "/Lidl|Kroger/").domain == ""
    finally:
        await _restore(saved)


async def test_replace_is_admin_only():
    async with async_session() as s:
        s.add(User(identifier=f"{PREFIX}-member", display_name="M", source=UserSource.app, enrolled=True))
        await s.commit()
    try:
        async with async_session() as s:
            try:
                await require_admin(f"{PREFIX}-member", s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
    finally:
        async with async_session() as s:
            await s.execute(delete(User).where(User.identifier.like(f"{PREFIX}%")))
            await s.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
