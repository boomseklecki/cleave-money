"""Pure unit tests for pairwise ('friends') balance computation (no DB)."""
from decimal import Decimal
from types import SimpleNamespace

from app.services.friend_balances import compute


def _split(user, paid, owed):
    return SimpleNamespace(user_identifier=user, paid_share=Decimal(paid), owed_share=Decimal(owed))


def _expense(*splits):
    return SimpleNamespace(splits=list(splits), repayments=None)


def _sw_expense(repayments, *splits):
    """A Splitwise-imported expense carrying authoritative `repayments` (and possibly splits to be ignored)."""
    return SimpleNamespace(splits=list(splits), repayments=list(repayments))


def _rep(frm, to, amount):
    return {"from": frm, "to": to, "amount": amount}


def test_two_person_bill():
    # me paid $20, split evenly: me owes 10, P owes 10 -> P owes me 10.
    exp = _expense(_split("me", "20", "10"), _split("p", "0", "10"))
    assert compute("me", [exp]) == {"p": Decimal(10)}


def test_i_owe_when_they_paid():
    # P paid $20, even split -> I owe P 10 (negative).
    exp = _expense(_split("p", "20", "10"), _split("me", "0", "10"))
    assert compute("me", [exp]) == {"p": Decimal(-10)}


def test_three_person_bill_proportional():
    # me paid the whole $30, split three ways ($10 each). A and B each owe me their $10.
    exp = _expense(_split("me", "30", "10"), _split("a", "0", "10"), _split("b", "0", "10"))
    assert compute("me", [exp]) == {"a": Decimal(10), "b": Decimal(10)}


def test_settle_up_nets_pair_toward_zero():
    # I owed P 10 (P paid a $20 even bill), then I settle up by paying P 10.
    bill = _expense(_split("p", "20", "10"), _split("me", "0", "10"))           # me: -10
    settle = _expense(_split("me", "10", "0"), _split("p", "0", "10"))          # me: +10
    assert compute("me", [bill, settle]) == {"p": Decimal(0)}


def test_expense_without_caller_has_no_effect():
    exp = _expense(_split("a", "20", "10"), _split("b", "0", "10"))
    assert compute("me", [exp]) == {}


def test_skips_zero_total_paid():
    exp = _expense(_split("me", "0", "0"), _split("p", "0", "0"))
    assert compute("me", [exp]) == {}


# --- Splitwise authoritative `repayments` path (sw user ids mapped to identifiers) ---

SW_MAP = {"100": "me", "200": "p", "300": "a"}


def test_repayments_they_owe_me():
    # P (sw 200) owes me (sw 100) $15 on this expense.
    exp = _sw_expense([_rep("200", "100", "15")])
    assert compute("me", [exp], SW_MAP) == {"p": Decimal(15)}


def test_repayments_i_owe_them():
    # I (sw 100) owe A (sw 300) $20.
    exp = _sw_expense([_rep("100", "300", "20")])
    assert compute("me", [exp], SW_MAP) == {"a": Decimal(-20)}


def test_repayments_settleup_nets_pair():
    # P owes me $15, then a reverse-direction settle-up repayment (I "owe" P, i.e. P paid me back) of $15.
    bill = _sw_expense([_rep("200", "100", "15")])
    settle = _sw_expense([_rep("100", "200", "15")])
    assert compute("me", [bill, settle], SW_MAP) == {"p": Decimal(0)}


def test_repayments_take_precedence_over_splits():
    # Splits would (proportionally) say P owes me 10, but repayments are authoritative and say 7.
    exp = _sw_expense(
        [_rep("200", "100", "7")],
        _split("me", "20", "10"), _split("p", "0", "10"),
    )
    assert compute("me", [exp], SW_MAP) == {"p": Decimal(7)}


def test_repayments_skip_unmapped_counterparty():
    # A repayment to me from an un-imported sw user (999) is skipped; the mapped one still counts.
    exp = _sw_expense([_rep("999", "100", "50"), _rep("200", "100", "10")])
    assert compute("me", [exp], SW_MAP) == {"p": Decimal(10)}


def test_repayments_ignore_legs_without_caller():
    # P owes A - nothing to do with me.
    exp = _sw_expense([_rep("200", "300", "30")])
    assert compute("me", [exp], SW_MAP) == {}


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
