"""updated_since delta filter on the cacheable list endpoints."""
import json
import urllib.parse
import urllib.request

from sqlalchemy import delete

from app.db import async_session
from app.models import Account, Group, Transaction, User

API = "http://localhost:8000"
PAST = "2000-01-01T00:00:00Z"
FUTURE = "2999-01-01T00:00:00Z"


def _req(method, path, data=None):
    headers = {}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=body, method=method, headers=headers)
    resp = urllib.request.urlopen(req)
    return resp.status, resp.read()


def _get(path, updated_since):
    qs = urllib.parse.urlencode({"updated_since": updated_since})
    sep = "&" if "?" in path else "?"
    return json.loads(_req("GET", f"{path}{sep}{qs}")[1])


async def test_updated_since_filters():
    gid = json.loads(_req("POST", "/groups", {"name": "sync-test"})[1])["id"]
    user_id = json.loads(_req("POST", "/users", {"display_name": "Sync User"})[1])["id"]
    account_id = json.loads(_req("POST", "/accounts", {"name": "Sync Acct"})[1])["id"]
    tx_id = json.loads(_req("POST", "/transactions", {
        "account_id": account_id, "description": "t", "amount": "1.00", "date": "2023-01-01",
    })[1])["id"]
    expense_id = json.loads(_req("POST", "/expenses", {
        "group_id": gid, "description": "e", "amount": "10.00", "date": "2023-01-01",
        "splits": [{"user_identifier": "syncuser", "paid_share": "10.00", "owed_share": "10.00"}],
    })[1])["id"]

    targets = [
        ("/groups", gid),
        ("/users", user_id),
        ("/accounts", account_id),
        ("/transactions", tx_id),
        ("/expenses", expense_id),
    ]
    try:
        for path, item_id in targets:
            in_past = _get(path, PAST)
            assert any(x["id"] == item_id for x in in_past), f"{path} should include recent row for PAST"
            in_future = _get(path, FUTURE)
            assert not any(x["id"] == item_id for x in in_future), f"{path} should exclude for FUTURE"
    finally:
        async with async_session() as session:
            await session.execute(delete(Transaction).where(Transaction.id == tx_id))
            await session.execute(delete(Account).where(Account.id == account_id))
            await session.execute(delete(Group).where(Group.id == gid))
            await session.execute(delete(User).where(User.id == user_id))
            await session.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
