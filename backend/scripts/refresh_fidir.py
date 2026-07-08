"""Regenerate the bundled institution dataset from Intuit's FIDIR (the canonical OFX file-list).

Intuit publishes every financial institution that supports OFX at
https://ofx-prod-filist.intuit.com/qm2400/data/fidir.txt - a tab-delimited file whose capability
columns encode the delivery channel:
  * ``...&DIRECT`` - OFX Direct Connect (app pulls with the user's bank creds)
  * ``...&WEB-CONNECT`` - file download (the .ofx/.qfx a user exports)  ← what Cleave imports
  * ``...&EXP-WEB-CONNECT`` - Intuit-hosted aggregation (NOT a downloadable file)

We keep institutions that offer a *direct* Web Connect file export (a ``WEB-CONNECT`` token that is
not ``EXP-WEB-CONNECT``) for BANKING or CREDIT, and emit ``{name, domain, home_url, kinds}`` to
``app/integrations/statements/institutions_data.json``. That file is committed and read at runtime;
the backend never calls Intuit live.

    python backend/scripts/refresh_fidir.py                       # fetch live
    python backend/scripts/refresh_fidir.py --from-file /tmp/fidir.txt   # offline (from a saved file)
"""
import argparse
import json
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

FIDIR_URL = "https://ofx-prod-filist.intuit.com/qm2400/data/fidir.txt"
OUT = Path(__file__).resolve().parents[1] / "app/integrations/statements/institutions_data.json"

# FIDIR row layout (14 tab-separated columns). The first two lines are a "FILIST"/count header.
NAME, HOME_URL = 3, 4          # 0-based: id,id,id,NAME,HOME_URL,phone,ofx_url,status,cap1..cap4,qbp,region
CAP_COLS = range(8, 12)        # the four capability columns


def _domain(home_url: str) -> str | None:
    """The brand domain from a home URL: netloc minus a leading ``www.``, lowercased."""
    host = urlsplit(home_url.strip()).netloc.lower()
    if not host:
        return None
    host = host.split("@")[-1].split(":")[0]          # drop any user-info / port
    return host[4:] if host.startswith("www.") else host or None


def _kinds(caps: list[str]) -> list[str]:
    """Which account kinds this institution exports via Web Connect (banking/credit), in caps order."""
    out: list[str] = []
    for token in ("BANKING", "CREDIT"):
        if any(token in c and "WEB-CONNECT" in c and "EXP-WEB-CONNECT" not in c for c in caps):
            out.append(token.lower())
    return out


def _load(args: argparse.Namespace) -> str:
    # FIDIR is Windows-1252 (cp1252) - smart quotes (Cabela's) and accents (français) are single bytes.
    if args.from_file:
        return Path(args.from_file).read_bytes().decode("cp1252", "replace")
    with urllib.request.urlopen(FIDIR_URL, timeout=60) as resp:  # noqa: S310 (trusted Intuit host)
        return resp.read().decode("cp1252", "replace")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--from-file", help="read fidir.txt from a local path instead of fetching")
    args = ap.parse_args()

    rows = _load(args).splitlines()[2:]  # skip the "FILIST" + count header lines
    seen: dict[str, dict] = {}           # normalized name → record (first wins; dedups FIDIR repeats)
    for line in rows:
        cols = line.split("\t")
        if len(cols) < 12:
            continue
        caps = [cols[i] for i in CAP_COLS]
        kinds = _kinds(caps)
        if not kinds:                    # no direct banking/credit Web Connect export
            continue
        name = cols[NAME].strip()
        domain = _domain(cols[HOME_URL])
        if not name or not domain:
            continue
        key = " ".join(name.lower().split())
        seen.setdefault(key, {"name": name, "domain": domain,
                              "home_url": cols[HOME_URL].strip(), "kinds": kinds})

    institutions = sorted(seen.values(), key=lambda r: r["name"].lower())
    OUT.write_text(json.dumps(institutions, ensure_ascii=False, indent=0) + "\n", encoding="utf-8")
    print(f"wrote {len(institutions)} institutions → {OUT.relative_to(Path.cwd())}", file=sys.stderr)


if __name__ == "__main__":
    main()
