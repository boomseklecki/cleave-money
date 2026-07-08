"""Server-side category resolver - the backend analogue of iOS `CategoryMapping.resolve(...)`.

Resolves a transaction's (or expense's) canonical category through the same 5-rank precedence chain the app
uses, so server-side spend computation agrees with what the user sees on-device:

  transaction: override → owner map → built-in Plaid (≠ "Other") → refined → built-in "Other"/raw
  expense:     owner map → built-in Plaid → Splitwise taxonomy → raw

The resolver is built once per owner from their `category_maps` (see `for_owner`, added once the table
exists) and resolves many rows cheaply - `override`/`refined` are passed in per row (they live on the
transaction's override row, not the base transaction).
"""
from __future__ import annotations

from dataclasses import dataclass

from ..category_builtin import plaid_canonical, splitwise_canonical
from ..categories import CATEGORIES

# Provenance labels mirror iOS `CategoryOrigin` (kept as strings - only spend needs the category; parity
# tests assert the origin too).
ORIGIN_OVERRIDE = "override"
ORIGIN_MAPPED_BY_YOU = "mappedByYou"
ORIGIN_MAPPED_BY_AI = "mappedByAI"
ORIGIN_DETERMINISTIC = "deterministic"
ORIGIN_AI_REFINED = "aiRefined"
ORIGIN_EXPLICIT = "explicit"
ORIGIN_RAW = "raw"

_CANONICAL = frozenset(CATEGORIES)


@dataclass(frozen=True)
class Resolution:
    """A resolved category plus how it was derived. `category` is None only when there's nothing to show."""

    category: str | None
    origin: str
    raw: str | None


class CategoryResolver:
    """Holds an owner's raw→canonical map (+ source) and resolves transactions/expenses against it."""

    def __init__(self, lookup: dict[str, str], sources: dict[str, str] | None = None) -> None:
        self.lookup = lookup
        self.sources = sources or {}

    @classmethod
    async def for_owner(cls, session, owner: str | None) -> "CategoryResolver":
        """Build a resolver from the owner's `category_maps` (loaded once), so many rows resolve cheaply.
        Open mode / no owner → just the built-in tables."""
        if owner is None:
            return cls(lookup={})
        # Imported here to keep the pure resolver core importable without the ORM (Phase-0 parity tests).
        from sqlalchemy import select

        from ..models.category_map import CategoryMap

        rows = list(
            await session.scalars(
                select(CategoryMap).where(CategoryMap.owner_identifier == owner)
            )
        )
        return cls(
            lookup={r.raw_category: r.canonical_category for r in rows},
            sources={r.raw_category: r.source for r in rows},
        )

    def _mapped_origin(self, raw: str) -> str:
        return ORIGIN_MAPPED_BY_AI if self.sources.get(raw) == "ondevice" else ORIGIN_MAPPED_BY_YOU

    def _passthrough_origin(self, value: str) -> str:
        return ORIGIN_EXPLICIT if value in _CANONICAL else ORIGIN_RAW

    def resolve(
        self, raw: str | None, *, override: str | None = None, refined: str | None = None
    ) -> Resolution:
        """A transaction's category with provenance (mirrors `CategoryMapping.resolve(for:)`)."""
        if override:
            return Resolution(override, ORIGIN_OVERRIDE, raw)
        if not raw:
            return Resolution(None, ORIGIN_RAW, raw)
        mapped = self.lookup.get(raw)
        if mapped is not None:
            return Resolution(mapped, self._mapped_origin(raw), raw)
        builtin = plaid_canonical(raw)
        if builtin is not None and builtin != "Other":
            return Resolution(builtin, ORIGIN_DETERMINISTIC, raw)
        if refined:
            return Resolution(refined, ORIGIN_AI_REFINED, raw)
        if builtin is not None:  # "Other"
            return Resolution(builtin, ORIGIN_DETERMINISTIC, raw)
        return Resolution(raw, self._passthrough_origin(raw), raw)

    def resolve_expense(self, raw: str | None) -> Resolution:
        """A raw expense/label category with provenance (mirrors `CategoryMapping.resolve(expenseCategory:)`)."""
        if not raw:
            return Resolution(None, ORIGIN_RAW, raw)
        mapped = self.lookup.get(raw)
        if mapped is not None:
            return Resolution(mapped, self._mapped_origin(raw), raw)
        builtin = plaid_canonical(raw)
        if builtin is not None:
            return Resolution(builtin, ORIGIN_DETERMINISTIC, raw)
        sw = splitwise_canonical(raw)
        if sw is not None:
            return Resolution(sw, ORIGIN_DETERMINISTIC, raw)
        return Resolution(raw, self._passthrough_origin(raw), raw)
