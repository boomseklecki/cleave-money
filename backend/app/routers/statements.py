"""Manual bank-statement (OFX) import - for accounts no aggregator can reach (e.g. Apple Card, which only
offers a monthly Wallet export). The caller uploads the raw OFX bytes; we find-or-create a manual account and
upsert its transactions, de-duped by FITID so re-importing an overlapping statement adds nothing new."""
import logging
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.db import get_session
from app.integrations.statements import ofx
from app.integrations.statements.institutions import resolve_institution
from app.models import Account, Transaction
from app.models.enums import TransactionSource
from app.schemas.statement import StatementImportResult

log = logging.getLogger(__name__)

router = APIRouter(tags=["statements"])

_OFX_BODY = {
    "content": {"application/x-ofx": {"schema": {"type": "string", "format": "binary"}}},
    "required": True,
}


@router.post("/statements/import", response_model=StatementImportResult, status_code=201,
             openapi_extra={"requestBody": _OFX_BODY})
async def import_statement(
    request: Request,
    force: bool = False,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> StatementImportResult:
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="Empty request body")
    return await import_ofx(session, caller, data, force=force)


async def import_ofx(session: AsyncSession, caller: str | None, data: bytes,
                     force: bool = False) -> StatementImportResult:
    """Parse an OFX file and upsert EACH account statement it contains into its own find-or-created manual
    account (a multi-account export carries several). Split from the route so it's unit-testable without a
    `Request`. Returns aggregate counts across accounts; the primary (first) account's id/name lead so the
    single-account common case is unchanged."""
    statements = ofx.parse(data)
    if not any(s.transactions or s.acctid for s in statements):
        raise HTTPException(status_code=422, detail="Not a recognizable OFX statement")

    results = [await _import_one_statement(session, caller, s, force)
               for s in statements if (s.transactions or s.acctid)]
    await session.commit()  # one commit for the whole file (each statement flushed above)
    primary = results[0]
    return StatementImportResult(
        account_id=primary.account_id, account_name=primary.account_name,
        imported=sum(r.imported for r in results), skipped=sum(r.skipped for r in results),
        total=sum(r.total for r in results), plaid_conflict=any(r.plaid_conflict for r in results))


async def _import_one_statement(session: AsyncSession, caller: str | None, parsed: "ofx.ParsedStatement",
                                force: bool) -> StatementImportResult:
    """Upsert one parsed account statement into its own manual account. Flushes but does NOT commit - the
    caller commits once for the whole file."""
    # Guard: if this card is already linked via Plaid, don't silently create a duplicate manual account - 
    # surface the conflict so the caller can confirm (force=True to import anyway). Match on the one safe
    # cross-source signal: owner + last-4 mask + institution domain.
    mask = (parsed.acctid or "")[-4:] or None
    inst = resolve_institution(parsed.org)
    domain = inst.domain if inst else None
    if not force and mask and domain:
        plaid_match = await session.scalar(select(Account).where(
            Account.owner_identifier == caller, Account.plaid_account_id.is_not(None),
            Account.mask == mask, Account.institution_domain == domain))
        if plaid_match is not None:
            return StatementImportResult(
                account_id=plaid_match.id, account_name=plaid_match.name,
                imported=0, skipped=0, total=len(parsed.transactions), plaid_conflict=True)

    # Find-or-create the manual account this statement belongs to. Prefer the stable OFX account id (ACCTID);
    # if there's no match, adopt a prior name-keyed import of this card that has no external id yet (backfill
    # it) rather than creating a duplicate - older imports were keyed on name only.
    name = (parsed.org or "Imported Card").strip()[:255] or "Imported Card"
    account = None
    if parsed.acctid:
        account = await session.scalar(select(Account).where(
            Account.owner_identifier == caller, Account.external_account_id == parsed.acctid))
    if account is None:
        account = await session.scalar(select(Account).where(
            Account.owner_identifier == caller, Account.name == name,
            Account.plaid_account_id.is_(None), Account.external_account_id.is_(None)))
    if account is None:
        # An institution that changed its ACCTID format lands here (the ACCTID lookup missed and the
        # name-keyed fallback requires external_account_id IS NULL). We deliberately do NOT auto-merge by name
        # - two distinct cards at one bank share a name - but surface a likely duplicate for diagnosis.
        if parsed.acctid:
            dupe = await session.scalar(select(Account.id).where(
                Account.owner_identifier == caller, Account.name == name,
                Account.external_account_id.is_not(None), Account.external_account_id != parsed.acctid))
            if dupe is not None:
                log.warning("statement import: new account for %r (ACCTID %s) though a same-named account with "
                            "a different external id exists - possible ACCTID-format change / duplicate",
                            name, parsed.acctid)
        # Create the account WITH its stable key under a savepoint. Two simultaneous uploads of the same new
        # card (double-tap / retry / Share-Extension race) both miss the SELECTs above and both INSERT; the
        # loser trips the uq_account_owner_external partial index (migration 0039) at flush. Without a guard
        # that surfaces as an unhandled IntegrityError -> 500 (no global handler). Catch it, discard the
        # losing row, and adopt the winner's - a find-or-create, mirroring the per-transaction savepoint below.
        account = Account(name=name, type="credit", owner_identifier=caller, currency=parsed.currency,
                          balance=Decimal(0), external_account_id=parsed.acctid)
        try:
            async with session.begin_nested():
                session.add(account)  # inside the savepoint so its rollback cleanly discards the losing row
        except IntegrityError:
            account = await session.scalar(select(Account).where(
                Account.owner_identifier == caller, Account.external_account_id == parsed.acctid))
            if account is None:  # winner vanished between the conflict and the re-select - let the caller retry
                raise HTTPException(status_code=409, detail="Concurrent statement import; please retry")
    # Refresh identity + branding from the statement each import.
    if parsed.acctid:
        account.external_account_id = parsed.acctid     # set / backfill the stable key
    account.name = name
    account.mask = (parsed.acctid or "")[-4:] or None   # short display tag - the end of the ACCTID
    account.institution_name = inst.name if inst else parsed.org   # canonical FIDIR name when matched
    account.institution_domain = domain
    if parsed.currency_explicit:
        account.currency = parsed.currency   # refresh only when CURDEF was declared - never regress a correct
        #                                      currency to the USD default a currency-less statement would carry

    # Balances reflect the statement's as-of date - only adopt them when this statement is newer, so importing
    # an older statement later can't regress the balance. A statement with NO DTASOF seeds the balance only
    # when none is set yet (and never stamps balance_as_of, so a later dated statement still wins) instead of
    # silently never updating. LEDGERBAL is negative-when-owed → flip to Cleave's positive-owed convention;
    # AVAILBAL (available credit) is positive → stored as-is.
    newer = parsed.ledger_as_of is not None and (
        account.balance_as_of is None or parsed.ledger_as_of > account.balance_as_of)
    undated_seed = parsed.ledger_as_of is None and account.balance_as_of is None
    if newer or undated_seed:
        if parsed.ledger_balance is not None:
            account.balance = -parsed.ledger_balance
        if parsed.available_balance is not None:
            account.available_balance = parsed.available_balance
        if parsed.ledger_as_of is not None:
            account.balance_as_of = parsed.ledger_as_of

    # Upsert by FITID: only insert transactions not already present for this account.
    fitids = [t.fitid for t in parsed.transactions]
    existing = set(await session.scalars(select(Transaction.external_transaction_id).where(
        Transaction.account_id == account.id, Transaction.external_transaction_id.in_(fitids))))
    new_txns = [t for t in parsed.transactions if t.fitid not in existing]
    imported = 0
    for t in new_txns:
        # Per-row savepoint: a single bad row (e.g. a duplicate FITID within the same file) is skipped
        # rather than rolling back the whole statement import.
        try:
            async with session.begin_nested():
                session.add(Transaction(
                    account_id=account.id, external_transaction_id=t.fitid, source=TransactionSource.manual,
                    description=t.description, amount=t.amount, currency=parsed.currency, date=t.date,
                    owner_identifier=caller))
            imported += 1
        except Exception:
            log.warning("statement row import failed (fitid=%s); skipping", t.fitid, exc_info=True)
    await session.flush()  # the caller commits once for the whole file

    # Count parse-time drops (bad amount / blank FITID / no date) so they surface in the totals rather than
    # vanishing: total covers every STMTTRN seen; skipped = already-present (deduped) + dropped.
    return StatementImportResult(account_id=account.id, account_name=account.name,
                                 imported=imported,
                                 skipped=(len(parsed.transactions) - len(new_txns)) + parsed.dropped,
                                 total=len(parsed.transactions) + parsed.dropped)
