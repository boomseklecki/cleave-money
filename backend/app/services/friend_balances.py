"""Pairwise ("friends") balance computation - your net with each person, Splitwise-style.

For Splitwise-imported expenses we use Splitwise's own authoritative per-expense debts in
`Expense.repayments` (a list of `{from, to, amount}` keyed by Splitwise user IDs - `from` owes `to`). These
are exactly what the Splitwise app reports and already encode settle-ups as reverse-direction repayments, so
they net the pair toward zero automatically. We do NOT re-derive pairwise debts from the splits proportionally
 - Splitwise doesn't assign multi-payer debts proportionally, so that disagrees with (and can sign-flip) the
real balances.

For expenses with no repayments (self-hosted groups, or solo single-split items), we fall back to a
proportional split: "X owes Y" = `X.owed_share * (Y.paid_share / total_paid)`, so the caller's net with P is
`(P.owed_share * my.paid_share - my.owed_share * P.paid_share) / total_paid`.

Positive net = P owes the caller. Pure (no DB) so it's unit-testable; the router supplies the expenses (with
`.splits` and `.repayments`) and the Splitwise-ID → identifier map.
"""
from collections import defaultdict
from decimal import Decimal


def compute(
    caller: str, expenses, sw_id_to_identifier: dict[str, str] | None = None
) -> dict[str, Decimal]:
    """Net balance between `caller` and each other person, across `expenses`. Splitwise-imported expenses use
    `expense.repayments` (mapped to identifiers via `sw_id_to_identifier`); the rest fall back to the
    proportional splits formula. Positive net = that person owes the caller; only people who share an expense
    with the caller appear."""
    sw_id_to_identifier = sw_id_to_identifier or {}
    nets: dict[str, Decimal] = defaultdict(lambda: Decimal(0))
    for expense in expenses:
        repayments = getattr(expense, "repayments", None)
        if repayments:
            _apply_repayments(caller, repayments, sw_id_to_identifier, nets)
        else:
            _apply_splits(caller, list(expense.splits), nets)
    return dict(nets)


def _apply_repayments(caller, repayments, sw_id_to_identifier, nets) -> None:
    """Splitwise authoritative path: `from` owes `to`. Accrue only the legs that involve the caller and whose
    counterparty maps to a known identifier (a handful of un-imported users are skipped - pennies)."""
    for r in repayments:
        frm = sw_id_to_identifier.get(str(r["from"]))
        to = sw_id_to_identifier.get(str(r["to"]))
        amount = Decimal(str(r["amount"]))
        if to == caller and frm is not None:
            nets[frm] += amount  # they owe the caller
        elif frm == caller and to is not None:
            nets[to] -= amount  # the caller owes them


def _apply_splits(caller, splits, nets) -> None:
    """Fallback for expenses without repayments: proportional attribution of owed_share across payers."""
    total_paid = sum((s.paid_share for s in splits), Decimal(0))
    if total_paid == 0:
        return
    mine = next((s for s in splits if s.user_identifier == caller), None)
    if mine is None:
        return  # caller isn't in this expense → no effect on their pairwise balances
    for s in splits:
        if s.user_identifier == caller:
            continue
        nets[s.user_identifier] += (
            s.owed_share * mine.paid_share - mine.owed_share * s.paid_share
        ) / total_paid
