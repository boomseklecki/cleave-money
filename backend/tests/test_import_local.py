"""POST /splitwise/groups/{id}/import-local: clone a Splitwise group into a new
self-hosted group (native copies) and mark the source superseded (no double-count)."""
import json
import urllib.error
import urllib.request
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.models import BackendType, Expense, ExpenseItem, Group, GroupMember, Split

API = "http://localhost:8000"


def _req(method, path, data=None):
    headers = {}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=body, method=method, headers=headers)
    try:
        resp = urllib.request.urlopen(req)
        return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


async def _seed_source():
    async with async_session() as session:
        group = Group(name="SW Trip", backend_type=BackendType.splitwise, splitwise_group_id="7700")
        session.add(group)
        await session.flush()

        e1 = Expense(group_id=group.id, description="Dinner", amount=Decimal("40.00"), currency="USD",
                     date=date(2023, 1, 1), splitwise_expense_id="sw-il-1")
        e1.splits = [
            Split(user_identifier="il-alice", paid_share=Decimal("40"), owed_share=Decimal("20")),
            Split(user_identifier="il-bob", paid_share=Decimal("0"), owed_share=Decimal("20")),
        ]
        e1.items = [ExpenseItem(name="Pizza", quantity=Decimal("1"), price=Decimal("40.00"))]
        session.add(e1)

        e2 = Expense(group_id=group.id, description="Cab", amount=Decimal("10.00"), currency="USD",
                     date=date(2023, 1, 2), splitwise_expense_id="sw-il-2")
        e2.splits = [
            Split(user_identifier="il-alice", paid_share=Decimal("0"), owed_share=Decimal("5")),
            Split(user_identifier="il-bob", paid_share=Decimal("10"), owed_share=Decimal("5")),
        ]
        session.add(e2)

        session.add(GroupMember(group_id=group.id, user_identifier="il-alice"))
        session.add(GroupMember(group_id=group.id, user_identifier="il-bob"))
        await session.commit()
        return str(group.id)


async def test_import_splitwise_group_to_local():
    source_id = await _seed_source()
    new_id = None
    try:
        status, body = _req("POST", f"/splitwise/groups/{source_id}/import-local", {"name": "Trip (local)"})
        assert status == 200, (status, body)
        result = json.loads(body)
        new_id = result["group"]["id"]
        assert result["group"]["backend_type"] == "self_hosted"
        assert result["group"]["name"] == "Trip (local)"
        assert result["expenses_copied"] == 2

        exps = json.loads(_req("GET", f"/expenses?group_id={new_id}")[1])
        assert len(exps) == 2
        assert all(e["splitwise_expense_id"] is None for e in exps)  # native, decoupled
        dinner = next(e for e in exps if e["description"] == "Dinner")
        assert len(dinner["items"]) == 1 and dinner["items"][0]["name"] == "Pizza"

        members = json.loads(_req("GET", f"/groups/{new_id}/members")[1])
        assert {m["user_identifier"] for m in members} == {"il-alice", "il-bob"}

        # source superseded: hidden from the list, and its column is stamped
        assert not any(g["id"] == source_id for g in json.loads(_req("GET", "/groups")[1]))
        async with async_session() as session:
            superseded = await session.scalar(
                select(Group.superseded_at).where(Group.id == source_id)
            )
            assert superseded is not None

        # balances NOT double-counted: source superseded -> overall reflects only the new group
        overall = {e["identifier"]: Decimal(str(e["net"])) for e in json.loads(_req("GET", "/balances")[1])}
        assert overall.get("il-alice") == Decimal("15.00")
        assert overall.get("il-bob") == Decimal("-15.00")
    finally:
        async with async_session() as session:
            for gid in (source_id, new_id):
                if gid:
                    await session.execute(delete(Group).where(Group.id == gid))
            await session.commit()


async def test_import_local_rejects_self_hosted_source():
    gid = json.loads(_req("POST", "/groups", {"name": "local-src"})[1])["id"]
    try:
        assert _req("POST", f"/splitwise/groups/{gid}/import-local", {})[0] == 400
    finally:
        async with async_session() as session:
            await session.execute(delete(Group).where(Group.id == gid))
            await session.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
