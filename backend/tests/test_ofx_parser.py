"""OFX statement parsing: STMTTRN extraction, the amount sign flip (OFX debit → Cleave outflow), date +
FITID + account meta. Pure (no DB)."""
from datetime import date
from decimal import Decimal

from app.integrations.statements import ofx


def _one(text):
    """parse() returns one ParsedStatement per account block; these single-statement cases take the first."""
    statements = ofx.parse(text)
    assert len(statements) == 1
    return statements[0]


# A minimal Apple-Card-style OFX 1.x (SGML) statement: two purchases + one payment credit.
SAMPLE = """OFXHEADER:100
DATA:OFXSGML
VERSION:102

<OFX>
<SIGNONMSGSRSV1><SONRS><FI><ORG>Apple Card</ORG><FID>1</FID></FI></SONRS></SIGNONMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS>
<CURDEF>USD
<CCACCTFROM><ACCTID>xxxxxxxxxxxx4321</ACCTID></CCACCTFROM>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601120000<TRNAMT>-42.50<FITID>AC-1<NAME>BURRITO PALACE</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260603<TRNAMT>-9.99<FITID>AC-2<NAME>STREAMING CO<MEMO>monthly</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260610<TRNAMT>200.00<FITID>AC-3<NAME>PAYMENT THANK YOU</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>-621.28<DTASOF>20260626120000</LEDGERBAL>
<AVAILBAL><BALAMT>7878.72<DTASOF>20260626120000</AVAILBAL>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1>
</OFX>
"""


def test_parses_meta_and_transactions():
    s = _one(SAMPLE)
    assert s.org == "Apple Card"
    assert s.acctid == "xxxxxxxxxxxx4321"
    assert s.currency == "USD"
    assert len(s.transactions) == 3


def test_parses_balances_and_as_of():
    s = _one(SAMPLE)
    assert s.ledger_balance == Decimal("-621.28")      # raw OFX (negative-when-owed); router flips
    assert s.available_balance == Decimal("7878.72")   # available credit (positive), stored as-is
    assert s.ledger_as_of == date(2026, 6, 26)


def test_resolve_domain():
    from app.integrations.statements.institutions import resolve_domain
    assert resolve_domain("Apple Card") == "apple.com"
    assert resolve_domain("apple card") == "apple.com"
    assert resolve_domain("Unknown Bank") is None
    assert resolve_domain(None) is None


def test_amount_sign_flips_to_outflow_positive():
    by_id = {t.fitid: t for t in _one(SAMPLE).transactions}
    assert by_id["AC-1"].amount == Decimal("42.50")   # OFX -42.50 purchase → +42.50 outflow
    assert by_id["AC-3"].amount == Decimal("-200.00")  # OFX +200 payment → -200 inflow


def test_fields_date_and_description():
    t = next(t for t in _one(SAMPLE).transactions if t.fitid == "AC-1")
    assert t.date == date(2026, 6, 1)
    assert t.description == "BURRITO PALACE"


def test_prefers_dtuser_over_dtposted():
    # When an institution emits DTUSER (purchase date), prefer it over the later DTPOSTED (settled date).
    # Apple Card omits DTUSER, so the SAMPLE rows above exercise the DTPOSTED fallback.
    block = ("<OFX><STMTTRN><DTUSER>20260612<DTPOSTED>20260614120000"
             "<TRNAMT>-9.99<FITID>X<NAME>WITH DTUSER</STMTTRN></OFX>")
    t = _one(block).transactions[0]
    assert t.date == date(2026, 6, 12)


def test_falls_back_to_memo_when_no_name():
    # Drop NAME, keep MEMO → description from MEMO.
    block = "<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-1.00<FITID>X<MEMO>FROM MEMO</STMTTRN></OFX>"
    t = _one(block).transactions[0]
    assert t.description == "FROM MEMO"


def test_name_memo_flipped_bank_prefers_merchant_in_memo():
    # Some banks put the payment *method* in NAME and the merchant in MEMO. Lead with the merchant.
    block = ("<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-4.50<FITID>X"
             "<NAME>DEBIT CARD PURCHASE 1234<MEMO>STARBUCKS #123 SEATTLE</STMTTRN></OFX>")
    t = _one(block).transactions[0]
    assert t.description.startswith("STARBUCKS #123 SEATTLE")        # merchant first, not the method
    assert "STARBUCKS" in t.description


def test_boilerplate_name_containing_merchant_collapses_to_merchant():
    # NAME is boilerplate that *includes* the MEMO merchant → just the clean merchant, no duplication.
    block = ("<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-4.50<FITID>X"
             "<NAME>POS DEBIT STARBUCKS<MEMO>STARBUCKS</STMTTRN></OFX>")
    t = _one(block).transactions[0]
    assert t.description == "STARBUCKS"


def test_normal_bank_keeps_name_and_appends_complementary_memo():
    # Common case: NAME holds the merchant (not boilerplate). Keep it; append MEMO detail when distinct.
    block = ("<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-9.99<FITID>X"
             "<NAME>STREAMING CO<MEMO>monthly</STMTTRN></OFX>")
    t = _one(block).transactions[0]
    assert t.description == "STREAMING CO — monthly"


def test_name_only_unchanged():
    block = "<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-1.00<FITID>X<NAME>WHOLE FOODS</STMTTRN></OFX>"
    assert _one(block).transactions[0].description == "WHOLE FOODS"


def test_skips_incomplete_rows():
    block = "<OFX><STMTTRN><TRNAMT>-1.00<NAME>NO FITID</STMTTRN></OFX>"  # missing FITID + date
    assert _one(block).transactions == []


# An "export all accounts" file: one bank STMTRS (checking) + one credit CCSTMTRS in the same document.
_MULTI = """<OFX>
<SIGNONMSGSRSV1><SONRS><FI><ORG>Big Bank</ORG></FI></SONRS></SIGNONMSGSRSV1>
<BANKMSGSRSV1><STMTTRNRS><STMTRS>
<CURDEF>USD
<BANKACCTFROM><ACCTID>CHK-0001</ACCTID></BANKACCTFROM>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601<TRNAMT>-20.00<FITID>C1<NAME>GROCERY</STMTTRN>
<STMTTRN><TRNTYPE>DIRECTDEP<DTPOSTED>20260602<TRNAMT>1000.00<FITID>C2<NAME>PAYROLL</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>1500.00<DTASOF>20260603</LEDGERBAL>
</STMTRS></STMTTRNRS></BANKMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS>
<CURDEF>USD
<CCACCTFROM><ACCTID>CC-9999</ACCTID></CCACCTFROM>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260604<TRNAMT>-55.00<FITID>D1<NAME>ELECTRONICS</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>-55.00<DTASOF>20260605</LEDGERBAL>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1>
</OFX>"""


def test_multi_account_splits_into_separate_statements():
    statements = ofx.parse(_MULTI)
    assert len(statements) == 2                                   # one per account block - no merging
    by_acct = {s.acctid: s for s in statements}
    chk, cc = by_acct["CHK-0001"], by_acct["CC-9999"]
    assert {t.fitid for t in chk.transactions} == {"C1", "C2"}    # each account keeps ONLY its own txns
    assert {t.fitid for t in cc.transactions} == {"D1"}
    assert chk.ledger_balance == Decimal("1500.00")              # and its own balance
    assert cc.ledger_balance == Decimal("-55.00")
    assert chk.org == "Big Bank" and cc.org == "Big Bank"        # FI-level ORG shared


def test_trntype_overrides_disagreeing_trnamt_sign():
    # A debit sent with a POSITIVE TRNAMT (some banks rely on TRNTYPE) - DEBIT wins → outflow +.
    b1 = "<OFX><STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601<TRNAMT>42.50<FITID>X<NAME>SHOP</STMTTRN></OFX>"
    assert _one(b1).transactions[0].amount == Decimal("42.50")
    # A credit sent with a NEGATIVE TRNAMT - CREDIT wins → inflow -.
    b2 = "<OFX><STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260601<TRNAMT>-200.00<FITID>Y<NAME>REFUND</STMTTRN></OFX>"
    assert _one(b2).transactions[0].amount == Decimal("-200.00")
    # No/ambiguous TRNTYPE → fall back to the TRNAMT sign (OFX negative = debit → +).
    b3 = "<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-9.99<FITID>Z<NAME>X</STMTTRN></OFX>"
    assert _one(b3).transactions[0].amount == Decimal("9.99")


def test_cp1252_decode_preserves_high_bytes():
    # cp1252 0x92 = right single quote (e.g. "Cabela's"). A blind utf-8 "ignore" decode deletes it; honoring
    # the declared CHARSET:1252 keeps it. Audit Medium #12(a).
    raw = ("OFXHEADER:100\nDATA:OFXSGML\nENCODING:USASCII\nCHARSET:1252\n\n"
           "<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-5.00<FITID>C1<NAME>CABELA’S</STMTTRN></OFX>")
    t = _one(raw.encode("cp1252")).transactions[0]
    assert t.description == "CABELA’S"          # the ' survived (not stripped)


def test_comma_decimal_amounts_parse():
    # European exports use a decimal comma; plain Decimal() would drop the row. Audit Medium #12(b).
    b1 = "<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-42,50<FITID>X<NAME>EU</STMTTRN></OFX>"
    assert _one(b1).transactions[0].amount == Decimal("42.50")
    b2 = "<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-1.234,56<FITID>Y<NAME>EU</STMTTRN></OFX>"   # thousands + comma
    assert _one(b2).transactions[0].amount == Decimal("1234.56")


def test_unparseable_rows_counted_as_dropped():
    # Bad amount / missing FITID rows are counted (not silently vanished). Audit Medium #12(c).
    b = ("<OFX>"
         "<STMTTRN><DTPOSTED>20260601<TRNAMT>-5.00<FITID>OK<NAME>GOOD</STMTTRN>"
         "<STMTTRN><DTPOSTED>20260601<TRNAMT>notanumber<FITID>BAD<NAME>BADAMT</STMTTRN>"
         "<STMTTRN><DTPOSTED>20260601<TRNAMT>-1.00<NAME>NOFITID</STMTTRN>"
         "</OFX>")
    s = _one(b)
    assert len(s.transactions) == 1 and s.dropped == 2


def test_xml_entities_unescaped_in_description():
    # OFX 2.x XML escapes "&" → "&amp;"; unescape it so it doesn't render literally. Audit Medium #12(d).
    b = "<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-5.00<FITID>X<NAME>Barnes &amp; Noble</STMTTRN></OFX>"
    assert _one(b).transactions[0].description == "Barnes & Noble"


def test_curdef_presence_exposed():
    # currency_explicit distinguishes a declared CURDEF from the USD default (drives the account-currency
    # refresh in the router). Audit Medium #12(e).
    with_curdef = "<OFX><STMTRS><CURDEF>EUR<BANKTRANLIST></BANKTRANLIST></STMTRS></OFX>"
    without = "<OFX><STMTRS><BANKTRANLIST></BANKTRANLIST></STMTRS></OFX>"
    assert ofx.parse(with_curdef)[0].currency == "EUR" and ofx.parse(with_curdef)[0].currency_explicit is True
    assert ofx.parse(without)[0].currency == "USD" and ofx.parse(without)[0].currency_explicit is False


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
