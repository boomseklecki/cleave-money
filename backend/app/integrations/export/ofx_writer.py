"""Minimal OFX 1.x (SGML) writer for the caller's transactions.

OFX has no concept of a shared/split expense, so only bank/manual `transactions` are exported here. The output
is written to round-trip cleanly back through the inbound reader in `app/integrations/statements/ofx.py` and
its importer in `app/routers/statements.py`, so an export -> import re-attaches to the SAME accounts and dedups
instead of duplicating:

- Amount: Cleave stores `amount` positive = outflow; OFX `<TRNAMT>` is negative for a debit, so the sign is
  flipped out. We also emit an unambiguous `<TRNTYPE>` (DEBIT/CREDIT) which the reader trusts over the sign.
- FITID: the row's `external_transaction_id`, falling back to its UUID (stable across exports; the reader
  drops rows with no FITID, and the importer dedups on (account, FITID)).
- ACCTID: the account's `external_account_id` when it has one (the SAME key the importer find-or-creates on),
  so a re-import matches the existing account rather than spawning a new "Imported Card". Accounts that never
  came from OFX fall back to their internal id.
- ORG: the account's institution/name, so a re-import preserves the name (the importer names the account from
  `<ORG>`). OFX carries one file-level ORG, so a multi-account archive uses the primary account's - a known
  limitation of the single-file format; the per-account `transactions.ofx` endpoint is the clean round-trip.
- Account type: credit cards emit `<CREDITCARDMSGSRSV1>`/`<CCSTMTRS>`/`<CCACCTFROM>`, everything else emits the
  bank aggregate. Both are read by the reader; the right shape keeps the file valid for third-party tools too.
- No `<LEDGERBAL>`: we deliberately omit it. The importer would treat a stated balance as-of the statement date
  and could overwrite the live account balance; an export is not a balance source of truth, so we never emit
  one (the previous `<LEDGERBAL>0.00` zeroed the balance on re-import).
"""
import html
from datetime import date, datetime
from decimal import Decimal


def _amount(internal: Decimal) -> str:
    return format(-internal, "f")  # flip to OFX convention (negative = debit)


def _trntype(internal: Decimal) -> str:
    return "DEBIT" if internal > 0 else "CREDIT"


def _d(value: date) -> str:
    return value.strftime("%Y%m%d")


def _dt(value: datetime) -> str:
    return value.strftime("%Y%m%d%H%M%S")


def _leaf_text(value: str | None) -> str:
    # Collapse newlines (the reader's leaf scan stops at a newline) and escape SGML metacharacters; the
    # reader html-unescapes on the way back in, so this round-trips.
    return html.escape((value or "").replace("\r", " ").replace("\n", " ").strip())


def _is_credit(meta) -> bool:
    return meta is not None and "credit" in (getattr(meta, "type", None) or "").lower()


def _acctid(txn, meta) -> str:
    """The stable key the importer matches on: the account's external OFX id when present (so re-import finds
    the same account), else its internal id, else "manual" for account-less rows."""
    if meta is not None and getattr(meta, "external_account_id", None):
        return str(meta.external_account_id)
    return str(txn.account_id) if txn.account_id is not None else "manual"


def _currency(txns, meta) -> str:
    if meta is not None and getattr(meta, "currency", None):
        return meta.currency
    return next((t.currency for t in txns if t.currency), "USD")


def _stmttrn(t) -> list[str]:
    fitid = t.external_transaction_id or str(t.id)
    return [
        "<STMTTRN>",
        f"<TRNTYPE>{_trntype(t.amount)}",
        f"<DTPOSTED>{_d(t.date)}",
        f"<TRNAMT>{_amount(t.amount)}",
        f"<FITID>{html.escape(fitid)}",
        f"<NAME>{_leaf_text(t.description)}",
        "</STMTTRN>",
    ]


def _bank_stmt(acctid: str, currency: str, txns) -> list[str]:
    dates = [t.date for t in txns]
    lines = [
        "<STMTTRNRS><TRNUID>0<STATUS><CODE>0<SEVERITY>INFO</STATUS>",
        f"<STMTRS><CURDEF>{currency}",
        f"<BANKACCTFROM><BANKID>0<ACCTID>{html.escape(acctid)}<ACCTTYPE>CHECKING</BANKACCTFROM>",
        f"<BANKTRANLIST><DTSTART>{_d(min(dates))}<DTEND>{_d(max(dates))}",
    ]
    for t in txns:
        lines += _stmttrn(t)
    lines += ["</BANKTRANLIST>", "</STMTRS></STMTTRNRS>"]
    return lines


def _cc_stmt(acctid: str, currency: str, txns) -> list[str]:
    dates = [t.date for t in txns]
    lines = [
        "<CCSTMTTRNRS><TRNUID>0<STATUS><CODE>0<SEVERITY>INFO</STATUS>",
        f"<CCSTMTRS><CURDEF>{currency}",
        f"<CCACCTFROM><ACCTID>{html.escape(acctid)}</CCACCTFROM>",
        f"<BANKTRANLIST><DTSTART>{_d(min(dates))}<DTEND>{_d(max(dates))}",
    ]
    for t in txns:
        lines += _stmttrn(t)
    lines += ["</BANKTRANLIST>", "</CCSTMTRS></CCSTMTTRNRS>"]
    return lines


def transactions_ofx(transactions, *, accounts=None, generated_at: datetime | None = None) -> str:
    """OFX for `transactions`, grouped into one statement per account. `accounts` (any iterable of Account-like
    rows) supplies the stable ACCTID / institution ORG / account type used for a clean re-import; without it the
    writer falls back to the internal account id and a generic institution."""
    server_time = _dt(generated_at) if generated_at is not None else "19700101000000"
    meta_by_id = {a.id: a for a in (accounts or [])}

    # Group transactions by account, preserving first-seen order so output is deterministic.
    groups: dict = {}
    for t in transactions:
        groups.setdefault(t.account_id, []).append(t)

    # One file-level ORG (OFX limitation); use the first account that carries an institution/name.
    org = None
    for account_id in groups:
        meta = meta_by_id.get(account_id)
        if meta is not None:
            org = getattr(meta, "institution_name", None) or getattr(meta, "name", None)
            if org:
                break

    bank_blocks: list[str] = []
    cc_blocks: list[str] = []
    for account_id, txns in groups.items():
        meta = meta_by_id.get(account_id)
        acctid = _acctid(txns[0], meta)
        currency = _currency(txns, meta)
        if _is_credit(meta):
            cc_blocks += _cc_stmt(acctid, currency, txns)
        else:
            bank_blocks += _bank_stmt(acctid, currency, txns)

    sonrs = ["<SIGNONMSGSRSV1><SONRS>", "<STATUS><CODE>0<SEVERITY>INFO</STATUS>",
             f"<DTSERVER>{server_time}<LANGUAGE>ENG"]
    if org:
        sonrs.append(f"<FI><ORG>{_leaf_text(org)}</FI>")
    sonrs.append("</SONRS></SIGNONMSGSRSV1>")

    lines = [
        "OFXHEADER:100", "DATA:OFXSGML", "VERSION:102", "SECURITY:NONE",
        "ENCODING:UTF-8", "CHARSET:NONE", "COMPRESSION:NONE",
        "OLDFILEUID:NONE", "NEWFILEUID:NONE", "",
        "<OFX>", *sonrs,
    ]
    if bank_blocks:
        lines += ["<BANKMSGSRSV1>", *bank_blocks, "</BANKMSGSRSV1>"]
    if cc_blocks:
        lines += ["<CREDITCARDMSGSRSV1>", *cc_blocks, "</CREDITCARDMSGSRSV1>"]
    lines.append("</OFX>")
    return "\r\n".join(lines) + "\r\n"
