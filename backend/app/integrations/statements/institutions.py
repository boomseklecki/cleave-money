"""Resolves a statement's issuing institution (OFX `<ORG>`) to a canonical name + brand domain. The
domain feeds `Account.institution_domain`, from which the logos service resolves a brand logo (e.g.
apple.com → the Apple logo).

Two layers: a small curated `_OVERRIDES` (wins - covers issuers whose `<ORG>` doesn't equal their
FIDIR name, e.g. the statement says "Apple Card" but FIDIR lists "Apple Card WC"), then an exact
normalized-name match into `institutions_data.json` (generated from Intuit's FIDIR Web Connect list
by `scripts/refresh_fidir.py`). Exact-only - a wrong logo is worse than no logo."""
import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

_DATA = Path(__file__).with_name("institutions_data.json")

@dataclass(frozen=True)
class Institution:
    name: str
    domain: str
    home_url: str = ""


# Lowercased OFX <ORG> → the canonical Institution, overriding the FIDIR dataset. Every known <ORG> variant of
# an issuer maps to the SAME Institution (name + domain) so an import never splits one bank across two names
# (FIDIR lists Apple Card as "Apple Card WC"; statements say "Apple Card").
_OVERRIDES: dict[str, Institution] = {
    "apple card": Institution("Apple Card", "apple.com"),
    "apple card wc": Institution("Apple Card", "apple.com"),
}


def _normalize(org: str) -> str:
    return " ".join(org.lower().split())


@lru_cache(maxsize=1)
def _dataset() -> list[Institution]:
    """The FIDIR Web Connect institutions, loaded once. Missing data file → empty (overrides still work)."""
    try:
        rows = json.loads(_DATA.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []
    return [Institution(r["name"], r["domain"], r.get("home_url", "")) for r in rows]


@lru_cache(maxsize=1)
def _by_name() -> dict[str, Institution]:
    """normalized FIDIR name → institution (first wins on collisions, matching the dataset's dedup)."""
    index: dict[str, Institution] = {}
    for inst in _dataset():
        index.setdefault(_normalize(inst.name), inst)
    return index


def search(query: str, limit: int = 50) -> list[Institution]:
    """Case-insensitive name search over the dataset, ranked prefix-before-substring, then alphabetical.
    De-duped by normalized name (FIDIR carries multiple records per bank) so each bank appears once."""
    q = _normalize(query)
    if not q:
        return []
    prefix: list[Institution] = []
    other: list[Institution] = []
    seen: set[str] = set()
    for inst in _dataset():
        key = _normalize(inst.name)
        if key in seen:
            continue
        name = inst.name.lower()
        if name.startswith(q):
            seen.add(key)
            prefix.append(inst)
        elif q in name:
            seen.add(key)
            other.append(inst)
    return (prefix + other)[:limit]


def resolve_institution(org: str | None) -> Institution | None:
    """The canonical institution for an OFX `<ORG>`, or None when unknown."""
    if not org:
        return None
    key = _normalize(org)
    if (inst := _OVERRIDES.get(key)) is not None:
        return inst
    return _by_name().get(key)


def resolve_domain(org: str | None) -> str | None:
    """Backward-compatible: just the brand domain for an OFX `<ORG>`."""
    inst = resolve_institution(org)
    return inst.domain if inst else None


def normalize_domain(domain: str | None) -> str:
    """Registrable-ish host: lowercased, scheme + path + `www.` stripped. "" when absent."""
    if not domain:
        return ""
    d = domain.strip().lower().split("//", 1)[-1].split("/", 1)[0]
    return d[4:] if d.startswith("www.") else d


@lru_cache(maxsize=1)
def _by_domain() -> dict[str, Institution]:
    """Brand domain → a representative institution. A domain can host several FIDIR records (co-branded cards
    share the bank's domain), so the shortest canonical name wins - "Chase" outranks "Marriott Rewards Credit
    Card" on chase.com - giving a sensible default when we match by domain rather than exact name."""
    index: dict[str, Institution] = {}
    for inst in _dataset():
        d = normalize_domain(inst.domain)
        if not d:
            continue
        cur = index.get(d)
        if cur is None or len(inst.name) < len(cur.name):
            index[d] = inst
    return index


def resolve(name: str | None, domain: str | None) -> Institution | None:
    """Canonical institution for an aggregator account (Plaid/SimpleFIN `org`): prefer an exact name match
    (which picks the right co-brand when several share a domain), then fall back to the registrable domain.
    Lets those sources resolve to the SAME curated institution (name + brand domain) that OFX imports use, so
    branding + cross-source dedup line up. None when neither matches."""
    if inst := resolve_institution(name):
        return inst
    if (d := normalize_domain(domain)) and (inst := _by_domain().get(d)):
        return inst
    return None
