"""Phase 1: relational category sync (GET/PUT /categories, set-replace, owner-scoped) + the per-transaction
`refined_category` override (set/read-back, drop-guard). DB-backed (calls router fns directly)."""
import uuid
from datetime import date
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete, select

from app.db import async_session
from app.models import CategoryMap, SpendCategory, Transaction, TransactionOverride
from app.models.enums import TransactionSource
from app.routers.accounts import _attach_overrides, update_transaction, update_transaction_override
from app.routers.categories import get_categories, put_categories
from app.schemas.category import CategoryConfigUpsert, CategoryMapItem, SpendCategoryItem
from app.schemas.transaction import TransactionOverrideUpdate, TransactionUpdate

CALLER = "cat-alice"
OTHER = "cat-bob"


async def _cleanup_categories(owner: str) -> None:
    async with async_session() as s:
        await s.execute(delete(SpendCategory).where(SpendCategory.owner_identifier == owner))
        await s.execute(delete(CategoryMap).where(CategoryMap.owner_identifier == owner))
        await s.commit()


async def test_put_then_get_roundtrip_and_watermark():
    try:
        async with async_session() as s:
            cfg = await put_categories(
                CategoryConfigUpsert(
                    categories=[
                        SpendCategoryItem(name="Dining", icon="fork.knife", position=0, builtin=True),
                        SpendCategoryItem(name="Surf", icon="water.waves", position=1),
                    ],
                    maps=[
                        CategoryMapItem(raw_category="FOOD_AND_DRINK", canonical_category="Dining",
                                        source="manual"),
                        CategoryMapItem(raw_category="GENERAL_SERVICES", canonical_category="Surf",
                                        source="ondevice"),
                    ],
                ),
                caller=CALLER, session=s,
            )
        assert {c.name for c in cfg.categories} == {"Dining", "Surf"}
        assert {m.raw_category: m.source for m in cfg.maps} == {
            "FOOD_AND_DRINK": "manual", "GENERAL_SERVICES": "ondevice"}
        assert cfg.updated_at is not None  # the LWW watermark

        async with async_session() as s:
            got = await get_categories(caller=CALLER, session=s)
        assert {c.name for c in got.categories} == {"Dining", "Surf"}
        assert got.updated_at == cfg.updated_at
    finally:
        await _cleanup_categories(CALLER)


async def test_put_is_set_replace():
    try:
        async with async_session() as s:
            await put_categories(
                CategoryConfigUpsert(
                    categories=[SpendCategoryItem(name="A"), SpendCategoryItem(name="B")],
                    maps=[CategoryMapItem(raw_category="R1", canonical_category="A")],
                ),
                caller=CALLER, session=s,
            )
        # A smaller set replaces, not merges - B and R1 are gone.
        async with async_session() as s:
            cfg = await put_categories(
                CategoryConfigUpsert(
                    categories=[SpendCategoryItem(name="A")],
                    maps=[CategoryMapItem(raw_category="R2", canonical_category="A")],
                ),
                caller=CALLER, session=s,
            )
        assert [c.name for c in cfg.categories] == ["A"]
        assert [m.raw_category for m in cfg.maps] == ["R2"]
    finally:
        await _cleanup_categories(CALLER)


async def test_categories_owner_scoped():
    try:
        async with async_session() as s:
            await put_categories(
                CategoryConfigUpsert(categories=[SpendCategoryItem(name="Mine")]),
                caller=CALLER, session=s,
            )
        async with async_session() as s:
            other = await get_categories(caller=OTHER, session=s)
        assert other.categories == [] and other.updated_at is None
    finally:
        await _cleanup_categories(CALLER)


async def _seed_txn(owner: str) -> uuid.UUID:
    async with async_session() as s:
        t = Transaction(source=TransactionSource.plaid, description="x", amount=Decimal("5.00"),
                        currency="USD", date=date(2026, 6, 1), category="GENERAL_SERVICES",
                        owner_identifier=owner)
        s.add(t)
        await s.commit()
        return t.id


async def _drop_txn(txn_id: uuid.UUID) -> None:
    async with async_session() as s:
        await s.execute(delete(TransactionOverride).where(
            TransactionOverride.transaction_id == txn_id))
        await s.execute(delete(Transaction).where(Transaction.id == txn_id))
        await s.commit()


async def test_refined_category_set_readback_and_scoped():
    txn_id = await _seed_txn(CALLER)
    try:
        async with async_session() as s:
            t = await update_transaction_override(
                txn_id, TransactionOverrideUpdate(refined_category="Shopping"), caller=CALLER, session=s)
            assert t.refined_category == "Shopping"
        # Another caller sees no refinement (per-user).
        async with async_session() as s:
            t = await s.get(Transaction, txn_id)
            await _attach_overrides(s, OTHER, [t])
            assert t.refined_category is None
    finally:
        await _drop_txn(txn_id)


async def test_refined_coexists_with_category_and_drop_guard():
    txn_id = await _seed_txn(CALLER)
    try:
        # Refined + an explicit category override coexist on the one row at different ranks.
        async with async_session() as s:
            await update_transaction_override(
                txn_id, TransactionOverrideUpdate(refined_category="Shopping"), caller=CALLER, session=s)
        async with async_session() as s:
            t = await update_transaction(
                txn_id, TransactionUpdate(category_override="Travel"), caller=CALLER, session=s)
            assert t.category_override == "Travel" and t.refined_category == "Shopping"
        # Clearing the category leaves the row (refined still set).
        async with async_session() as s:
            await update_transaction(txn_id, TransactionUpdate(category_override=None),
                                     caller=CALLER, session=s)
            assert (await s.scalar(select(TransactionOverride).where(
                TransactionOverride.transaction_id == txn_id))) is not None
        # Clearing refined too - now every field is null → the row is dropped.
        async with async_session() as s:
            await update_transaction_override(
                txn_id, TransactionOverrideUpdate(refined_category=None), caller=CALLER, session=s)
            assert (await s.scalar(select(TransactionOverride).where(
                TransactionOverride.transaction_id == txn_id))) is None
    finally:
        await _drop_txn(txn_id)


async def test_put_categories_dedups_within_payload():
    """Duplicate names / raw_categories in a single PUT are silently de-duped (the unique constraints would
    otherwise reject the set)."""
    try:
        async with async_session() as s:
            cfg = await put_categories(
                CategoryConfigUpsert(
                    categories=[SpendCategoryItem(name="Dining"), SpendCategoryItem(name="Dining", icon="x")],
                    maps=[CategoryMapItem(raw_category="R", canonical_category="Dining"),
                          CategoryMapItem(raw_category="R", canonical_category="Other")],
                ),
                caller=CALLER, session=s,
            )
        assert [c.name for c in cfg.categories] == ["Dining"]     # one kept, dup skipped
        assert [m.raw_category for m in cfg.maps] == ["R"]        # first mapping wins
        assert cfg.maps[0].canonical_category == "Dining"
    finally:
        await _cleanup_categories(CALLER)


async def test_put_categories_rejects_open_mode():
    """No caller (open mode) can't own categories → 401."""
    async with async_session() as s:
        try:
            await put_categories(CategoryConfigUpsert(), caller=None, session=s)
            assert False, "expected HTTPException(401)"
        except HTTPException as e:
            assert e.status_code == 401


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
