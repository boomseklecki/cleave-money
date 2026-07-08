"""Pure mapping from a SimpleFIN Account Set to Cleave row data.

Amount sign: SimpleFIN reports POSITIVE for deposits (money in) and negative for withdrawals. Cleave's
convention is the opposite (positive = outflow/spend), so we NEGATE here - the same normalization the OFX
importer does. Dates: SimpleFIN gives Unix epochs; we take the transaction's calendar date in UTC (a
deterministic choice - the app displays dates in the device tz per the date-only convention).
"""
import re
from datetime import UTC, date, datetime
from decimal import Decimal, InvalidOperation

from app.integrations.statements import institutions

# A last-4 embedded in an account name, only when a mask indicator precedes it (x1234, ****1234, ...1234,
# "ending in 1234", acct/#/- 1234) - never a bare 4-digit run, which could be a year or branch. SimpleFIN has
# no mask field, so this is the only place we can recover one for display + cross-source matching.
_MASK_RE = re.compile(r"(?:ending(?:\s+in)?|acct\.?|account|[x*#•·.\-])[\sx*#•·.\-]*(\d{4})(?!\d)", re.IGNORECASE)


def _epoch_to_date(epoch) -> date:
    return datetime.fromtimestamp(int(epoch), tz=UTC).date()


def _decimal(value) -> Decimal | None:
    if value is None:
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None


def _currency(value) -> str:
    # SimpleFIN currency is an ISO 4217 code OR a URL (custom currency). Our column is 3 chars, so keep only a
    # clean ISO code and otherwise fall back to USD.
    code = (value or "").strip().upper()
    return code if len(code) == 3 and code.isalpha() else "USD"


def _mask(name: str) -> str | None:
    m = _MASK_RE.search(name or "")
    return m.group(1) if m else None


def map_account(account: dict) -> dict:
    org = account.get("org") or {}
    raw_name = account.get("name") or "Account"
    # Resolve org through the shared OFX institution catalog for canonical branding + a domain that matches
    # what OFX/Plaid store (so cross-source dedup lines up); fall back to SimpleFIN's raw org when unknown.
    inst = institutions.resolve(org.get("name"), org.get("domain"))
    return {
        "simplefin_account_id": account["id"],
        "name": raw_name[:255],
        "currency": _currency(account.get("currency")),
        "balance": _decimal(account.get("balance")) or Decimal("0"),
        "available_balance": _decimal(account.get("available-balance")),
        "institution_name": inst.name if inst else org.get("name"),
        "institution_domain": inst.domain if inst else org.get("domain"),
        "mask": _mask(raw_name),
    }


def map_transaction(txn: dict) -> dict:
    amount = _decimal(txn.get("amount")) or Decimal("0")
    when = txn.get("transacted_at") or txn.get("posted") or 0
    return {
        "external_transaction_id": txn["id"],
        "description": (txn.get("description") or "")[:512],
        "amount": -amount,  # NEGATE: SimpleFIN + = inflow; Cleave + = outflow (see module docstring)
        "date": _epoch_to_date(when),
        "pending": bool(txn.get("pending")),
    }
