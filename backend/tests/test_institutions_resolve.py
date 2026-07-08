"""institutions.resolve / normalize_domain: name-first then domain fallback, used so SimpleFIN (and later
Plaid) accounts resolve to the same curated institution OFX imports use (shared branding + cross-source dedup)."""
from app.integrations.statements import institutions as I


def test_resolve_by_name_then_domain():
    assert I.resolve("Chase", "chase.com").domain == "chase.com"          # exact name
    assert I.resolve(None, "chase.com").domain == "chase.com"             # domain fallback
    assert I.resolve("no-such-name", "chase.com").domain == "chase.com"   # name misses -> domain
    assert I.resolve(None, "https://www.chase.com/login").domain == "chase.com"  # normalized domain
    assert I.resolve("Totally Fake CU", "nope.example") is None           # neither matches


def test_normalize_domain():
    assert I.normalize_domain("https://www.Chase.COM/login") == "chase.com"
    assert I.normalize_domain("WWW.Foo.org") == "foo.org"
    assert I.normalize_domain("") == "" and I.normalize_domain(None) == ""


def test_domain_index_prefers_the_shorter_bank_name():
    # chase.com hosts co-branded cards too; the domain index should surface the primary "Chase".
    assert I.resolve(None, "chase.com").name == "Chase"


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
