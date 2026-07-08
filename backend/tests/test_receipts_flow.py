"""End-to-end receipt flow against the running api + MinIO.

Creates a throwaway expense directly in the DB, then drives the HTTP endpoints:
POST raw bytes -> list -> GET bytes -> delete. Bytes flow through the API; the client
never touches MinIO directly.
"""
import json
import urllib.error
import urllib.request
from datetime import date
from decimal import Decimal

from sqlalchemy import delete

from app.db import async_session
from app.models import BackendType, Expense, Group, Transaction
from app.models.enums import TransactionSource

API = "http://localhost:8000"
PNG = b"\x89PNG\r\n\x1a\n" + b"cleave-fake-receipt-bytes"


def _req(method, path, data=None, content_type=None, base=API):
    headers = {}
    body = None
    if content_type is not None:
        body = data
        headers["Content-Type"] = content_type
    elif data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=body, method=method, headers=headers)
    try:
        resp = urllib.request.urlopen(req)
        return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


async def _setup_expense():
    async with async_session() as session:
        group = Group(name="receipt-test", backend_type=BackendType.self_hosted)
        session.add(group)
        await session.flush()
        expense = Expense(
            group_id=group.id,
            description="receipt test",
            amount=Decimal("1.00"),
            currency="USD",
            date=date(2023, 1, 1),
        )
        session.add(expense)
        await session.commit()
        return expense.id, group.id


async def _teardown(expense_id, group_id):
    async with async_session() as session:
        await session.execute(delete(Expense).where(Expense.id == expense_id))
        await session.execute(delete(Group).where(Group.id == group_id))
        await session.commit()


async def test_receipt_round_trip():
    expense_id, group_id = await _setup_expense()
    try:
        # 1. upload the bytes in one call (API streams them into MinIO)
        status, body = _req(
            "POST", f"/expenses/{expense_id}/receipts", data=PNG, content_type="image/png"
        )
        assert status == 201, (status, body)
        receipt = json.loads(body)
        receipt_id = receipt["id"]
        object_key = receipt["object_key"]
        assert object_key.startswith(f"{expense_id}/")
        assert receipt["content_type"] == "image/png"

        # 2. uploading to a missing expense is rejected
        status, _ = _req(
            "POST",
            "/expenses/00000000-0000-0000-0000-000000000000/receipts",
            data=PNG,
            content_type="image/png",
        )
        assert status == 404

        # 3. list
        status, body = _req("GET", f"/expenses/{expense_id}/receipts")
        assert status == 200
        assert any(r["id"] == receipt_id for r in json.loads(body))

        # 4. fetch the bytes back through the API -> they match what we uploaded
        status, got = _req("GET", f"/receipts/{receipt_id}/content")
        assert status == 200
        assert got == PNG, "downloaded bytes differ from upload"

        # 5. delete -> object gone, listing empty
        status, _ = _req("DELETE", f"/receipts/{receipt_id}")
        assert status == 204
        from app.integrations.storage import minio_client

        assert minio_client.object_exists(object_key) is False
        status, body = _req("GET", f"/expenses/{expense_id}/receipts")
        assert json.loads(body) == []
    finally:
        await _teardown(expense_id, group_id)


async def _setup_transaction():
    async with async_session() as session:
        txn = Transaction(
            source=TransactionSource.manual, description="receipt txn test", amount=Decimal("1.00"),
            currency="USD", date=date(2023, 1, 1), owner_identifier="receipt-txn-owner",
        )
        session.add(txn)
        await session.commit()
        return txn.id


async def test_transaction_receipt_round_trip():
    txn_id = await _setup_transaction()
    try:
        # upload → the API streams the bytes into MinIO and keys the receipt by transaction
        status, body = _req(
            "POST", f"/transactions/{txn_id}/receipts", data=PNG, content_type="image/png"
        )
        assert status == 201, (status, body)
        receipt = json.loads(body)
        assert receipt["transaction_id"] == str(txn_id) and receipt["expense_id"] is None
        assert receipt["object_key"].startswith(f"{txn_id}/")

        # list → fetch bytes → delete
        status, body = _req("GET", f"/transactions/{txn_id}/receipts")
        assert status == 200 and any(r["id"] == receipt["id"] for r in json.loads(body))
        status, got = _req("GET", f"/receipts/{receipt['id']}/content")
        assert status == 200 and got == PNG
        status, _ = _req("DELETE", f"/receipts/{receipt['id']}")
        assert status == 204
        status, body = _req("GET", f"/transactions/{txn_id}/receipts")
        assert json.loads(body) == []
    finally:
        async with async_session() as session:
            await session.execute(delete(Transaction).where(Transaction.id == txn_id))
            await session.commit()


async def test_receipt_rejects_disallowed_content_type():
    """Only image/pdf receipts are accepted (the stored content_type is echoed on download). Audit #13(d)."""
    expense_id, group_id = await _setup_expense()
    try:
        status, _ = _req("POST", f"/expenses/{expense_id}/receipts", data=b"<html>nope</html>",
                         content_type="text/html")
        assert status == 422
        status, body = _req("GET", f"/expenses/{expense_id}/receipts")
        assert json.loads(body) == []                              # nothing stored
    finally:
        await _teardown(expense_id, group_id)


async def test_download_missing_object_is_404_not_500():
    """When the DB row exists but the MinIO object is gone, GET content is 404 (S3Error handled), not 500.
    Audit #13(b)."""
    expense_id, group_id = await _setup_expense()
    try:
        status, body = _req("POST", f"/expenses/{expense_id}/receipts", data=PNG, content_type="image/png")
        assert status == 201
        receipt = json.loads(body)
        from app.integrations.storage import minio_client
        minio_client.remove(receipt["object_key"])                 # drop the object out from under the row
        status, _ = _req("GET", f"/receipts/{receipt['id']}/content")
        assert status == 404                                       # not a 500
    finally:
        await _teardown(expense_id, group_id)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
