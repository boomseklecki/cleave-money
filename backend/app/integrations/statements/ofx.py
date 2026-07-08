"""Tolerant OFX statement parser (no third-party dep). OFX is finicky SGML (1.x, leaf tags often unclosed) or
XML (2.x); rather than strict-parse we scan tags. Extracts the account meta + each `<STMTTRN>`. The amount is
flipped to Cleave's convention (positive = outflow) - OFX `<TRNAMT>` is negative for purchases - matching
the Plaid mapper (which stores positive for money leaving the account)."""
import html
import logging
import re
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal, InvalidOperation

log = logging.getLogger(__name__)

_STMTTRN = re.compile(r"<STMTTRN>(.*?)</STMTTRN>", re.I | re.S)
_LEDGERBAL = re.compile(r"<LEDGERBAL>(.*?)</LEDGERBAL>", re.I | re.S)
_AVAILBAL = re.compile(r"<AVAILBAL>(.*?)</AVAILBAL>", re.I | re.S)
# One statement aggregate per account - a single "export all accounts" OFX can carry several (checking +
# savings + credit). We parse each block independently so their transactions don't merge into one account.
_STMT_BLOCK = re.compile(r"<(STMTRS|CCSTMTRS)>(.*?)</\1>", re.I | re.S)

# OFX <TRNTYPE> direction families (OFX 11.4.4.3). Only the unambiguously-directional types override the
# TRNAMT sign; ambiguous ones (PAYMENT/XFER/CASH/OTHER) fall back to the TRNAMT sign. This fixes the banks
# that send a positive TRNAMT for a debit and rely on TRNTYPE, without regressing the common case.
_DEBIT_TYPES = {"DEBIT", "POS", "ATM", "FEE", "SRVCHG", "CHECK", "DIRECTDEBIT"}
_CREDIT_TYPES = {"CREDIT", "DEP", "DIRECTDEP", "INT", "DIV"}

# Some banks put the payment *method* in <NAME> ("DEBIT CARD PURCHASE 1234") and the real merchant in
# <MEMO>; others do the opposite, and most put the merchant in <NAME>. We can't blindly swap (that would
# break the common case), so we detect method-boilerplate NAMEs and prefer/combine MEMO for those.
_METHOD_BOILERPLATE = re.compile(
    r"\b(?:DEBIT|CREDIT|CHECK)\s*CARD|\bCHECKCARD|\bPURCHASE\s+AUTHORIZED|\bPOS\b|\bPOINT\s+OF\s+SALE|"
    r"\bACH\b|\b(?:E?\s*-?\s*)?TRANSFER\b|\bWITHDRAWAL\b|\bDEPOSIT\b|\bPREAUTH|\bRECURRING\s+PAYMENT|"
    r"\bBILL\s*PAY|\bDIRECT\s+(?:DEP|DEBIT)|\bELECTRONIC|\bWEB\s+PMT|\bONLINE\s+(?:PMT|PAYMENT)",
    re.I)


@dataclass
class ParsedTxn:
    fitid: str
    date: date
    amount: Decimal  # Cleave convention: positive = outflow (spend), negative = inflow (payment/credit)
    description: str


@dataclass
class ParsedStatement:
    org: str | None
    acctid: str | None
    currency: str
    currency_explicit: bool = True             # False when CURDEF was absent (currency is the USD default)
    ledger_balance: Decimal | None = None      # OFX <LEDGERBAL><BALAMT> (negative-when-owed; caller flips)
    available_balance: Decimal | None = None   # OFX <AVAILBAL><BALAMT> (available credit; positive)
    ledger_as_of: date | None = None           # <LEDGERBAL><DTASOF> - the date the balances reflect
    transactions: list[ParsedTxn] = field(default_factory=list)
    dropped: int = 0                           # STMTTRN rows that failed to parse (bad amount / no FITID/date)


def _leaf(tag: str, text: str) -> str | None:
    """The value of a leaf element `<TAG>value` - up to the next tag or end of line. Works for SGML (unclosed
    leaves) and XML (`<TAG>value</TAG>`) alike, since we stop at the next `<`."""
    m = re.search(rf"<{tag}>([^<\r\n]*)", text, re.I)
    return m.group(1).strip() if m else None


def _describe(name: str | None, memo: str | None) -> str:
    """The most useful merchant description from a transaction's <NAME>/<MEMO>.

    Default: prefer NAME (where most banks put the merchant). But when NAME is payment-method boilerplate
    ("DEBIT CARD PURCHASE ...") and MEMO carries something else, lead with MEMO and append the rest so no
    detail is lost - covering the banks that flip the two fields without regressing the common case.
    """
    # Unescape SGML/XML entities (OFX 2.x XML emits "Barnes &amp; Noble") so they don't render literally.
    name = html.unescape((name or "").strip())
    memo = html.unescape((memo or "").strip())
    if not name and not memo:
        return "Transaction"
    if name and memo and name.lower() != memo.lower():
        primary, secondary = (memo, name) if _METHOD_BOILERPLATE.search(name) else (name, memo)
        # When one field subsumes the other, keep the cleaner primary (the merchant) - avoids
        # "STARBUCKS - STARBUCKS" and "STARBUCKS - POS DEBIT STARBUCKS".
        if secondary.lower() in primary.lower() or primary.lower() in secondary.lower():
            return primary
        return f"{primary} — {secondary}"
    return name or memo


def _parse_date(value: str | None) -> date | None:
    if not value:
        return None
    digits = re.sub(r"[^0-9]", "", value)[:8]  # OFX dates: YYYYMMDD[HHMMSS][.xxx][+TZ]
    if len(digits) < 8:
        return None
    try:
        return date(int(digits[0:4]), int(digits[4:6]), int(digits[6:8]))
    except ValueError:
        return None


def _decimal(value: str | None) -> Decimal | None:
    """Parse an OFX amount, tolerating a comma decimal separator (European exports send `42,50` / `1.234,56`)
    which plain Decimal() would reject - silently dropping the row."""
    if value is None:
        return None
    v = value.strip()
    if "," in v and "." in v:  # both present: the RIGHTMOST separator is the decimal, the other is grouping
        dec, thou = (",", ".") if v.rfind(",") > v.rfind(".") else (".", ",")
        v = v.replace(thou, "").replace(dec, ".")
    elif "," in v:  # lone comma = decimal comma
        v = v.replace(",", ".")
    try:
        return Decimal(v)
    except InvalidOperation:
        return None


def _decode(content: bytes) -> str:
    """Decode OFX bytes honoring the declared charset. A blind utf-8 decode with `errors="ignore"` silently
    deletes cp1252 high bytes (smart quotes / accents - the same issue `scripts/refresh_fidir.py` documents),
    mangling merchant names. Prefer cp1252 when the SGML header / XML decl declares 1252; else utf-8, falling
    back to cp1252 (which maps every byte) when utf-8 fails."""
    header = content[:2048].split(b"<OFX", 1)[0].upper()  # SGML header / xml decl, before the body
    if b"1252" in header:  # CHARSET:1252 / WINDOWS-1252 / encoding="windows-1252"
        return content.decode("cp1252", "replace")
    try:
        return content.decode("utf-8")
    except UnicodeDecodeError:
        return content.decode("cp1252", "replace")


def parse(content: bytes | str) -> list[ParsedStatement]:
    """One `ParsedStatement` per account statement in the file. A multi-account export yields several; a
    single-statement file (or one with no STMTRS/CCSTMTRS markers) yields exactly one."""
    text = _decode(content) if isinstance(content, bytes) else content
    org = _leaf("ORG", text)  # FI-level (SONRS) - shared across the file's accounts
    # Each account aggregate carries its OWN ACCTID/CURDEF/balances/transactions; parse them independently.
    # No aggregate markers (minimal OFX) → treat the whole document as a single statement (back-compat).
    blocks = [m.group(2) for m in _STMT_BLOCK.finditer(text)] or [text]
    return [_parse_block(block, org) for block in blocks]


def _parse_block(text: str, org: str | None) -> ParsedStatement:
    acctid = _leaf("ACCTID", text)
    curdef = _leaf("CURDEF", text)
    currency = (curdef or "USD").upper()[:3]

    # Balances - scope BALAMT to its own aggregate so LEDGERBAL and AVAILBAL don't collide.
    ledger_balance = ledger_as_of = available_balance = None
    if (m := _LEDGERBAL.search(text)):
        ledger_balance = _decimal(_leaf("BALAMT", m.group(1)))
        ledger_as_of = _parse_date(_leaf("DTASOF", m.group(1)))
    if (m := _AVAILBAL.search(text)):
        available_balance = _decimal(_leaf("BALAMT", m.group(1)))

    txns: list[ParsedTxn] = []
    dropped = 0
    for block in _STMTTRN.findall(text):
        fitid = _leaf("FITID", block)
        # Prefer the transaction (purchase) date when the institution emits it; fall back to the posted/
        # settled date. Note: Apple Card's OFX carries only DTPOSTED, so this is a no-op there.
        when = _parse_date(_leaf("DTUSER", block)) or _parse_date(_leaf("DTPOSTED", block))
        description = _describe(_leaf("NAME", block), _leaf("MEMO", block))
        raw = _decimal(_leaf("TRNAMT", block))  # comma-aware; None if blank/unparseable
        if not fitid or raw is None or when is None:
            dropped += 1  # counted (not silently vanished) so import totals reflect it
            continue
        # Cleave convention is positive = outflow. Trust an unambiguous TRNTYPE for direction (handles the
        # banks whose TRNAMT sign disagrees); otherwise fall back to the TRNAMT sign (OFX: negative = debit).
        trntype = (_leaf("TRNTYPE", block) or "").upper()
        if trntype in _DEBIT_TYPES:
            amount = abs(raw)
        elif trntype in _CREDIT_TYPES:
            amount = -abs(raw)
        else:
            amount = -raw
        txns.append(ParsedTxn(fitid=fitid, date=when, amount=amount, description=description[:512]))
    if dropped:
        log.warning("OFX: dropped %d unparseable transaction row(s) (missing FITID/date or bad amount)", dropped)
    return ParsedStatement(org=org, acctid=acctid, currency=currency, currency_explicit=curdef is not None,
                           ledger_balance=ledger_balance, available_balance=available_balance,
                           ledger_as_of=ledger_as_of, transactions=txns, dropped=dropped)
