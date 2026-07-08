"""Locale-safe CSV serializers (stdlib `csv`, no third-party dep).

Every file is UTF-8 with a BOM (so Excel/Sheets open non-ASCII correctly), uses
`.` decimal points regardless of the server locale, and quotes fields as needed.
Money is rendered from the stored `Decimal` (`format(v, "f")`) so 2-decimal
precision is preserved and never widened to a float. Expenses are normalized:
`expenses_csv` is one row per expense, `splits_csv` is one row per (expense, person)
carrying the paid/owed shares that Splitwise's own export drops.
"""
import csv
import io
from datetime import date, datetime
from decimal import Decimal
from enum import Enum

_BOM = "﻿"


def _cell(value) -> str:
    if value is None:
        return ""
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, Enum):
        return str(value.value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    return str(value)


def _render(headers: list[str], rows) -> str:
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\r\n")
    writer.writerow(headers)
    for row in rows:
        writer.writerow([_cell(c) for c in row])
    return _BOM + buf.getvalue()


def expenses_csv(expenses) -> str:
    headers = [
        "id", "group_id", "date", "description", "amount", "currency", "category",
        "notes", "note", "created_by", "updated_by", "splitwise_expense_id",
        "transaction_id", "created_at", "updated_at",
    ]
    rows = (
        [
            e.id, e.group_id, e.date, e.description, e.amount, e.currency, e.category,
            e.notes, getattr(e, "note", None), e.created_by, e.updated_by,
            e.splitwise_expense_id, e.transaction_id, e.created_at, e.updated_at,
        ]
        for e in expenses
    )
    return _render(headers, rows)


def splits_csv(expenses) -> str:
    headers = [
        "expense_id", "date", "description", "user_identifier",
        "paid_share", "owed_share", "currency",
    ]
    rows = (
        [e.id, e.date, e.description, s.user_identifier, s.paid_share, s.owed_share, e.currency]
        for e in expenses
        for s in e.splits
    )
    return _render(headers, rows)


def transactions_csv(transactions) -> str:
    headers = [
        "id", "account_id", "date", "description", "amount", "currency", "category",
        "category_override", "note", "source", "pending", "external_transaction_id",
        "plaid_transaction_id", "created_at", "updated_at",
    ]
    rows = (
        [
            t.id, t.account_id, t.date, t.description, t.amount, t.currency, t.category,
            getattr(t, "category_override", None), getattr(t, "note", None), t.source,
            t.pending, t.external_transaction_id, t.plaid_transaction_id,
            t.created_at, t.updated_at,
        ]
        for t in transactions
    )
    return _render(headers, rows)


def accounts_csv(accounts) -> str:
    headers = [
        "id", "name", "display_name", "type", "kind", "mask", "balance",
        "available_balance", "currency", "institution_name", "share_level",
        "created_at", "updated_at",
    ]
    rows = (
        [
            a.id, a.name, getattr(a, "display_name", None), a.type, getattr(a, "kind", None),
            a.mask, a.balance, a.available_balance, a.currency, a.institution_name,
            a.share_level, a.created_at, a.updated_at,
        ]
        for a in accounts
    )
    return _render(headers, rows)


def balances_csv(balances) -> str:
    headers = ["identifier", "display_name", "net"]
    rows = ([b["identifier"], b["display_name"], b["net"]] for b in balances)
    return _render(headers, rows)


def groups_csv(groups, members) -> str:
    """One row per membership (a group with no members contributes no rows)."""
    names = {g.id: g.name for g in groups}
    types = {g.id: g.backend_type for g in groups}
    headers = ["group_id", "group_name", "backend_type", "user_identifier", "member_since"]
    rows = (
        [m.group_id, names.get(m.group_id), types.get(m.group_id), m.user_identifier, m.created_at]
        for m in members
    )
    return _render(headers, rows)
