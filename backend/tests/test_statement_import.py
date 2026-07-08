"""OFX statement import: find-or-creates a manual account (keyed on ACCTID), maps institution + balances, and
de-dups transactions by FITID on re-import. Balances follow the newest DTASOF. DB-backed."""
import asyncio
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.db import async_session
from app.models import Account, Transaction
from app.routers.statements import import_ofx
from tests.test_ofx_parser import SAMPLE

OWNER = "stmt-owner"


def _variant(dtasof: str, ledger: str) -> bytes:
    """SAMPLE with a different statement DTASOF + LEDGERBAL (same ACCTID → same account)."""
    return SAMPLE.replace("20260626120000", dtasof + "120000").replace("-621.28", ledger).encode()


async def _purge():
    async with async_session() as s:
        acct_ids = (await s.scalars(select(Account.id).where(Account.owner_identifier == OWNER))).all()
        if acct_ids:
            await s.execute(delete(Transaction).where(Transaction.account_id.in_(acct_ids)))
        await s.execute(delete(Account).where(Account.owner_identifier == OWNER))
        await s.commit()


async def test_import_creates_account_and_transactions():
    await _purge()
    try:
        async with async_session() as s:
            result = await import_ofx(s, OWNER, SAMPLE.encode())
        assert result.imported == 3 and result.total == 3 and result.skipped == 0
        assert result.account_name == "Apple Card"
        async with async_session() as s:
            acct = await s.get(Account, result.account_id)
            assert acct.owner_identifier == OWNER and acct.plaid_account_id is None
            assert acct.external_account_id == "xxxxxxxxxxxx4321"   # find-or-create key (ACCTID)
            assert acct.mask == "4321"                             # ACCTID[-4:]
            assert acct.institution_name == "Apple Card" and acct.institution_domain == "apple.com"
            assert acct.balance == Decimal("621.28")               # LEDGERBAL -621.28 flipped → positive owed
            assert acct.available_balance == Decimal("7878.72")    # AVAILBAL as-is
            assert acct.balance_as_of == date(2026, 6, 26)
            txns = (await s.scalars(select(Transaction).where(Transaction.account_id == acct.id))).all()
            assert len(txns) == 3
            byid = {t.external_transaction_id: t for t in txns}
            assert byid["AC-1"].amount == Decimal("42.50")     # purchase → outflow positive
            assert byid["AC-3"].amount == Decimal("-200.00")   # payment → inflow negative
            assert byid["AC-1"].source.value == "manual"
    finally:
        await _purge()


async def test_reimport_dedups_by_fitid():
    await _purge()
    try:
        async with async_session() as s:
            first = await import_ofx(s, OWNER, SAMPLE.encode())
        async with async_session() as s:
            second = await import_ofx(s, OWNER, SAMPLE.encode())  # same statement again
        assert first.imported == 3
        assert second.imported == 0 and second.skipped == 3      # nothing new, all de-duped
        assert second.account_id == first.account_id             # reused the same account
        async with async_session() as s:
            count = len((await s.scalars(
                select(Transaction).where(Transaction.account_id == first.account_id))).all())
        assert count == 3                                        # no duplicates
    finally:
        await _purge()


# A statement that repeats a FITID within the same file - the second occurrence violates the per-account
# unique index. Before per-row savepoints this rolled back the WHOLE import (500); now the dup is skipped.
_DUP_FITID_OFX = b"""OFXHEADER:100
<OFX>
<SIGNONMSGSRSV1><SONRS><FI><ORG>Dup Bank</ORG></FI></SONRS></SIGNONMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS>
<CURDEF>USD
<CCACCTFROM><ACCTID>dup-acct-zzz</ACCTID></CCACCTFROM>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601<TRNAMT>-5.00<FITID>DUP-1<NAME>FIRST</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260602<TRNAMT>-9.00<FITID>DUP-1<NAME>SECOND</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260603<TRNAMT>-3.00<FITID>UNIQ-2<NAME>THIRD</STMTTRN>
</BANKTRANLIST>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1>
</OFX>
"""


async def test_duplicate_fitid_in_one_file_skips_not_aborts():
    await _purge()
    try:
        async with async_session() as s:
            result = await import_ofx(s, OWNER, _DUP_FITID_OFX)  # must NOT raise
        # 3 parsed, but the repeated DUP-1 can only land once → 2 rows imported, the rest still committed.
        assert result.imported == 2, result
        async with async_session() as s:
            txns = (await s.scalars(select(Transaction).where(
                Transaction.account_id == result.account_id))).all()
            fitids = sorted(t.external_transaction_id for t in txns)
        assert fitids == ["DUP-1", "UNIQ-2"]
    finally:
        await _purge()


async def test_plaid_linked_card_guards_then_forces():
    # SAMPLE's ACCTID ends 4321 and ORG "Apple Card" → apple.com. A Plaid account matching (mask, domain) for
    # this owner means the card is already linked → guard the import, then force creates the separate account.
    await _purge()
    try:
        async with async_session() as s:
            s.add(Account(name="Apple Card", owner_identifier=OWNER, plaid_account_id="p-zzz",
                          mask="4321", institution_domain="apple.com", currency="USD", balance=Decimal(0)))
            await s.commit()
        async with async_session() as s:
            guarded = await import_ofx(s, OWNER, SAMPLE.encode())                 # force=False (default)
        assert guarded.plaid_conflict is True and guarded.imported == 0
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(Account)
                               .where(Account.owner_identifier == OWNER))
        assert n == 1                                                             # no duplicate created

        async with async_session() as s:
            forced = await import_ofx(s, OWNER, SAMPLE.encode(), force=True)      # import anyway
        assert forced.plaid_conflict is False and forced.imported == 3
        async with async_session() as s:
            n = await s.scalar(select(func.count()).select_from(Account)
                               .where(Account.owner_identifier == OWNER))
        assert n == 2                                                             # plaid + the new imported one
    finally:
        await _purge()


# An OFX whose <ORG> exactly matches a FIDIR dataset entry (not the curated Apple override) - branding
# should resolve from institutions_data.json: canonical name + domain, no longer null.
_AMEX_OFX = b"""OFXHEADER:100
<OFX>
<SIGNONMSGSRSV1><SONRS><FI><ORG>American Express</ORG><FID>3101</FID></FI></SONRS></SIGNONMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS>
<CURDEF>USD
<CCACCTFROM><ACCTID>xxxxxxxxxxxx9001</ACCTID></CCACCTFROM>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601<TRNAMT>-12.00<FITID>AX-1<NAME>COFFEE</STMTTRN>
</BANKTRANLIST>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1>
</OFX>
"""


async def test_branding_resolves_from_fidir_dataset():
    await _purge()
    try:
        async with async_session() as s:
            result = await import_ofx(s, OWNER, _AMEX_OFX)
        async with async_session() as s:
            acct = await s.get(Account, result.account_id)
            assert acct.institution_domain == "americanexpress.com"   # from FIDIR dataset, not null
            assert acct.institution_name == "American Express"        # canonical FIDIR name
    finally:
        await _purge()


async def test_balance_follows_newest_statement():
    await _purge()
    try:
        async with async_session() as s:
            r = await import_ofx(s, OWNER, SAMPLE.encode())                 # DTASOF 06-26 → balance 621.28
        async with async_session() as s:
            await import_ofx(s, OWNER, _variant("20260526", "-999.99"))     # OLDER → must not regress
        async with async_session() as s:
            acct = await s.get(Account, r.account_id)
            assert acct.balance == Decimal("621.28") and acct.balance_as_of == date(2026, 6, 26)
        async with async_session() as s:
            await import_ofx(s, OWNER, _variant("20260726", "-100.00"))     # NEWER → adopted
        async with async_session() as s:
            acct = await s.get(Account, r.account_id)
            assert acct.balance == Decimal("100.00") and acct.balance_as_of == date(2026, 7, 26)
    finally:
        await _purge()


async def test_adopts_name_keyed_account_no_duplicate():
    """A prior import keyed on name only (no external_account_id) is adopted + backfilled, not duplicated."""
    await _purge()
    try:
        async with async_session() as s:
            s.add(Account(name="Apple Card", type="credit", owner_identifier=OWNER,
                          currency="USD", balance=Decimal(0)))  # external_account_id stays null
            await s.commit()
        async with async_session() as s:
            result = await import_ofx(s, OWNER, SAMPLE.encode())
        async with async_session() as s:
            accts = (await s.scalars(select(Account).where(Account.owner_identifier == OWNER))).all()
            assert len(accts) == 1                                  # adopted, not duplicated
            assert accts[0].id == result.account_id
            assert accts[0].external_account_id == "xxxxxxxxxxxx4321"  # backfilled
            assert accts[0].mask == "4321" and accts[0].institution_domain == "apple.com"
    finally:
        await _purge()


# A minimal single-account statement with a fresh ACCTID for the concurrency test below.
_RACE_OFX = b"""OFXHEADER:100
<OFX>
<SIGNONMSGSRSV1><SONRS><FI><ORG>Race Bank</ORG></FI></SONRS></SIGNONMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS>
<CURDEF>USD
<CCACCTFROM><ACCTID>race-acct-zzz</ACCTID></CCACCTFROM>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601<TRNAMT>-7.00<FITID>R-1<NAME>THING</STMTTRN>
</BANKTRANLIST>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1>
</OFX>
"""


_EUR_OFX = b"""OFXHEADER:100
<OFX>
<SIGNONMSGSRSV1><SONRS><FI><ORG>Euro Bank</ORG></FI></SONRS></SIGNONMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS>
<CURDEF>EUR
<CCACCTFROM><ACCTID>eur-acct-zzz</ACCTID></CCACCTFROM>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601<TRNAMT>-9,99<FITID>E1<NAME>CAFE</STMTTRN>
</BANKTRANLIST>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1>
</OFX>"""


async def test_currency_refreshes_from_curdef_and_holds():
    """A declared CURDEF sets the account currency on every import (not frozen at creation), but a later
    CURDEF-less statement must NOT regress it to the USD default. Audit Medium #12(e) (+ comma amount #12b)."""
    await _purge()
    try:
        async with async_session() as s:
            r = await import_ofx(s, OWNER, _EUR_OFX)
        async with async_session() as s:
            acct = await s.get(Account, r.account_id)
            assert acct.currency == "EUR"                          # declared CURDEF adopted
            txns = (await s.scalars(select(Transaction).where(Transaction.account_id == acct.id))).all()
            assert txns[0].amount == Decimal("9.99")               # comma decimal parsed (‑9,99 → +9.99 outflow)
        async with async_session() as s:
            await import_ofx(s, OWNER, _EUR_OFX.replace(b"<CURDEF>EUR\n", b""))   # same card, no CURDEF
        async with async_session() as s:
            assert (await s.get(Account, r.account_id)).currency == "EUR"          # held, not regressed to USD
    finally:
        await _purge()


_NODTASOF_OFX = b"""OFXHEADER:100
<OFX>
<SIGNONMSGSRSV1><SONRS><FI><ORG>NoDate Bank</ORG></FI></SONRS></SIGNONMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS>
<CURDEF>USD
<CCACCTFROM><ACCTID>nodate-acct-zzz</ACCTID></CCACCTFROM>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601<TRNAMT>-3.00<FITID>N1<NAME>THING</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>-150.00</LEDGERBAL>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1>
</OFX>"""


async def test_balance_seeds_without_dtasof():
    """A statement with LEDGERBAL but no DTASOF still seeds the balance (instead of silently never updating),
    without stamping balance_as_of so a later dated statement still wins. Audit Medium #12(g)."""
    await _purge()
    try:
        async with async_session() as s:
            r = await import_ofx(s, OWNER, _NODTASOF_OFX)
        async with async_session() as s:
            acct = await s.get(Account, r.account_id)
            assert acct.balance == Decimal("150.00")               # LEDGERBAL -150 flipped, seeded despite no DTASOF
            assert acct.balance_as_of is None                      # unstamped → a dated statement still wins later
    finally:
        await _purge()


async def test_concurrent_new_account_upload_does_not_500():
    """Two simultaneous uploads of the same NEW card both miss the find SELECTs and race to INSERT; the loser
    trips the uq_account_owner_external partial index. The savepoint + re-select must turn that into a
    find-or-create (one account, txn imported once, no unhandled IntegrityError/500) - audit High #10."""
    await _purge()
    try:
        async def _one():
            async with async_session() as s:
                return await import_ofx(s, OWNER, _RACE_OFX)  # must NOT raise on the losing upload
        r1, r2 = await asyncio.gather(_one(), _one())
        assert r1.account_id == r2.account_id                 # both resolved to the same account
        async with async_session() as s:
            accts = (await s.scalars(select(Account).where(Account.owner_identifier == OWNER))).all()
            assert len(accts) == 1                             # exactly one account - no duplicate, no crash
            assert accts[0].external_account_id == "race-acct-zzz"
            txns = (await s.scalars(select(Transaction).where(
                Transaction.account_id == accts[0].id))).all()
            assert len(txns) == 1                              # the single txn imported exactly once
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
