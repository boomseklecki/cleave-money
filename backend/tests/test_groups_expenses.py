"""CRUD + behavior tests for groups and expenses against the running api.

HTTP via urllib; Splitwise groups and hard-delete are exercised directly against
the DB/storage since the api process runs with hard-delete disabled.
"""
import asyncio
import json
import urllib.error
import urllib.request
from datetime import date
from decimal import Decimal
from io import BytesIO

from sqlalchemy import delete

from app.config import settings
from app.db import async_session
from app.models import BackendType, Expense, Group, Receipt

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


def _create_group(name):
    status, body = _req("POST", "/groups", {"name": name})
    assert status == 201, (status, body)
    return json.loads(body)["id"]


async def _purge(*group_ids):
    async with async_session() as session:
        for gid in group_ids:
            await session.execute(delete(Group).where(Group.id == gid))
        await session.commit()


async def _make_splitwise_group(splitwise_id):
    async with async_session() as session:
        group = Group(
            name="sw-test",
            backend_type=BackendType.splitwise,
            splitwise_group_id=splitwise_id,
        )
        session.add(group)
        await session.commit()
        return str(group.id)


def _balanced_splits():
    return [
        {"user_identifier": "alice", "paid_share": "40.00", "owed_share": "20.00"},
        {"user_identifier": "bob", "paid_share": "0.00", "owed_share": "20.00"},
    ]


async def test_group_lifecycle_and_delete():
    gid = _create_group("lifecycle")
    try:
        status, body = _req("GET", "/groups")
        assert status == 200
        assert any(g["id"] == gid for g in json.loads(body))

        # hard-delete (self-hosted) - gone for good
        status, _ = _req("DELETE", f"/groups/{gid}")
        assert status == 204
        assert not any(g["id"] == gid for g in json.loads(_req("GET", "/groups")[1]))
        assert _req("GET", f"/groups/{gid}")[0] == 404
    finally:
        await _purge(gid)


async def test_backend_type_filter_and_splitwise_delete_409():
    self_id = _create_group("filter-self")
    sw_id = await _make_splitwise_group("test-sw-filter")
    try:
        self_only = json.loads(_req("GET", "/groups?backend_type=self_hosted")[1])
        assert any(g["id"] == self_id for g in self_only)
        assert not any(g["id"] == sw_id for g in self_only)

        sw_only = json.loads(_req("GET", "/groups?backend_type=splitwise")[1])
        assert any(g["id"] == sw_id for g in sw_only)
        assert not any(g["id"] == self_id for g in sw_only)

        # Splitwise groups may not be archived/deleted via the API
        status, _ = _req("DELETE", f"/groups/{sw_id}")
        assert status == 409
    finally:
        await _purge(self_id, sw_id)


# Note: the per-user `hidden` group toggle moved to `group_overrides` (keyed by caller), so it no longer
# reflects in open mode (caller=None) - it's covered caller-scoped in tests/test_group_overrides.py.


async def test_expense_validation():
    gid = _create_group("validation")
    sw_id = await _make_splitwise_group("test-sw-validation")
    try:
        # balanced -> 201, nested splits + item returned
        payload = {
            "group_id": gid,
            "description": "Dinner",
            "amount": "40.00",
            "date": "2023-05-01",
            "splits": _balanced_splits(),
            "items": [{"name": "Pizza", "price": "40.00", "quantity": "1"}],
        }
        status, body = _req("POST", "/expenses", payload)
        assert status == 201, (status, body)
        created = json.loads(body)
        assert len(created["splits"]) == 2 and len(created["items"]) == 1
        assert sum(Decimal(str(s["owed_share"])) for s in created["splits"]) == Decimal("40.00")

        # Non-existent transaction_id (e.g. a since-posted pending row) → clean 404, not an FK 500.
        missing_txn = dict(payload)
        missing_txn["transaction_id"] = "00000000-0000-0000-0000-0000000000bb"
        status, _ = _req("POST", "/expenses", missing_txn)
        assert status == 404, (status, _)

        # unbalanced -> 422
        bad = dict(payload)
        bad["splits"] = [
            {"user_identifier": "alice", "paid_share": "40.00", "owed_share": "10.00"},
            {"user_identifier": "bob", "paid_share": "0.00", "owed_share": "20.00"},
        ]
        status, _ = _req("POST", "/expenses", bad)
        assert status == 422

        # Splitwise group skips local validation (else this unbalanced payload would
        # 422); instead it proceeds to the Splitwise push, which 409s with no token.
        sw_payload = dict(bad)
        sw_payload["group_id"] = sw_id
        status, body = _req("POST", "/expenses", sw_payload)
        assert status == 409, (status, body)
    finally:
        await _purge(gid, sw_id)


async def test_expense_detail_patch_override_and_delete():
    gid = _create_group("detail")
    try:
        status, body = _req(
            "POST", "/expenses",
            {
                "group_id": gid,
                "description": "Groceries",
                "amount": "40.00",
                "date": "2023-05-02",
                "splits": _balanced_splits(),
            },
        )
        assert status == 201
        eid = json.loads(body)["id"]

        # detail
        status, body = _req("GET", f"/expenses/{eid}")
        assert status == 200 and len(json.loads(body)["splits"]) == 2

        # patch replaces splits wholesale
        status, body = _req(
            "PATCH", f"/expenses/{eid}",
            {"splits": [{"user_identifier": "alice", "paid_share": "40.00", "owed_share": "40.00"}]},
        )
        assert status == 200
        patched = json.loads(body)
        assert len(patched["splits"]) == 1
        assert patched["splits"][0]["user_identifier"] == "alice"

        # PATCH with a non-existent transaction_id (e.g. a since-posted pending row) → clean 404, not FK 500.
        assert _req("PATCH", f"/expenses/{eid}",
                    {"transaction_id": "00000000-0000-0000-0000-0000000000cc"})[0] == 404

        # per-user budget override (open mode: no caller, so it round-trips as null but the route works)
        status, body = _req("PATCH", f"/expenses/{eid}/override", {"include_in_spending": False})
        assert status == 200

        # hard delete removes it
        assert _req("DELETE", f"/expenses/{eid}")[0] == 204
        assert _req("GET", f"/expenses/{eid}")[0] == 404
        assert json.loads(_req("GET", f"/expenses?group_id={gid}")[1]) == []
    finally:
        await _purge(gid)


async def test_expense_transaction_link_set_and_clear():
    gid = _create_group("txn-link")
    tid = None
    try:
        eid = json.loads(_req("POST", "/expenses", {
            "group_id": gid, "description": "Mortgage", "amount": "2000.00",
            "date": "2023-05-02", "splits": [
                {"user_identifier": "alice", "paid_share": "2000.00", "owed_share": "1000.00"},
                {"user_identifier": "bob", "paid_share": "0.00", "owed_share": "1000.00"},
            ],
        })[1])["id"]
        tid = json.loads(_req("POST", "/transactions", {
            "description": "MORTGAGE PMT", "amount": "2000.00", "date": "2023-05-02",
        })[1])["id"]

        # Link → response carries the transaction_id, splits untouched.
        status, body = _req("PUT", f"/expenses/{eid}/transaction-link", {"transaction_id": tid})
        assert status == 200, (status, body)
        linked = json.loads(body)
        assert linked["transaction_id"] == tid
        assert len(linked["splits"]) == 2

        # Unlink with null → cleared.
        status, body = _req("PUT", f"/expenses/{eid}/transaction-link", {"transaction_id": None})
        assert status == 200, (status, body)
        assert json.loads(body)["transaction_id"] is None

        # Missing expense → 404.
        assert _req("PUT", f"/expenses/{gid}/transaction-link", {"transaction_id": tid})[0] == 404

        # Missing transaction (e.g. a since-posted pending row) → clean 404, not an FK 500.
        missing_tid = "00000000-0000-0000-0000-0000000000aa"
        assert _req("PUT", f"/expenses/{eid}/transaction-link", {"transaction_id": missing_tid})[0] == 404
    finally:
        if tid:
            async with async_session() as session:
                from app.models import Transaction
                await session.execute(delete(Transaction).where(Transaction.id == tid))
                await session.commit()
        await _purge(gid)


async def test_hard_delete_group_removes_objects_and_rows():
    from app.integrations.storage import minio_client
    from app.routers import groups as groups_router

    async with async_session() as session:
        group = Group(name="hard-delete", backend_type=BackendType.self_hosted)
        session.add(group)
        await session.flush()
        expense = Expense(
            group_id=group.id,
            description="x",
            amount=Decimal("1.00"),
            currency="USD",
            date=date(2023, 1, 1),
        )
        session.add(expense)
        await session.flush()
        key = f"{expense.id}/hard-delete.bin"
        minio_client.ensure_bucket()
        client = minio_client._internal_client()
        data = b"object-bytes"
        await asyncio.to_thread(
            client.put_object, settings.minio_bucket, key, BytesIO(data), len(data)
        )
        session.add(Receipt(expense_id=expense.id, bucket=settings.minio_bucket, object_key=key))
        await session.commit()
        gid, eid = group.id, expense.id

    async with async_session() as session:
        group = await session.get(Group, gid)
        await groups_router._hard_delete_group(session, group)

    assert minio_client.object_exists(key) is False
    async with async_session() as session:
        assert await session.get(Group, gid) is None
        assert await session.get(Expense, eid) is None


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
