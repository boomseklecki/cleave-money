"""JSON serializers. Expenses/transactions/accounts reuse the existing API response
schemas verbatim (so an export byte-for-byte matches what the app already receives,
nested splits/items/receipts and all); groups and balances are shaped locally.
"""
import json

from app.schemas.account import AccountResponse
from app.schemas.expense import ExpenseResponse
from app.schemas.transaction import TransactionResponse


def _dump(models) -> bytes:
    return json.dumps([m.model_dump(mode="json") for m in models], indent=2).encode("utf-8")


def expenses_json(expenses) -> bytes:
    return _dump([ExpenseResponse.model_validate(e) for e in expenses])


def transactions_json(transactions) -> bytes:
    return _dump([TransactionResponse.model_validate(t) for t in transactions])


def accounts_json(accounts) -> bytes:
    return _dump([AccountResponse.model_validate(a) for a in accounts])


def balances_json(balances) -> bytes:
    # `net` is a Decimal; default=str renders it losslessly as a string.
    return json.dumps(balances, indent=2, default=str).encode("utf-8")


def groups_json(groups, members) -> bytes:
    by_group: dict = {}
    for m in members:
        by_group.setdefault(m.group_id, []).append(m.user_identifier)
    data = [
        {
            "id": str(g.id),
            "name": g.name,
            "backend_type": g.backend_type.value if hasattr(g.backend_type, "value") else str(g.backend_type),
            "group_type": g.group_type,
            "splitwise_group_id": g.splitwise_group_id,
            "members": by_group.get(g.id, []),
        }
        for g in groups
    ]
    return json.dumps(data, indent=2).encode("utf-8")
