"""Two-way Splitwise write path: pure payload, token selection, SDK-mocked
orchestration, and HTTP guard rails. The live SDK call is monkeypatched - no
network. Full router->SDK success path is the documented manual end-to-end check.
"""
import json
import urllib.error
import urllib.request
from datetime import date
from decimal import Decimal

from sqlalchemy import delete

from app.db import async_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import writer
from app.models import BackendType, Expense, Group, Split, SplitwiseToken, User
from app.models.enums import UserSource

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


def _expense_dict(splits):
    return {"amount": Decimal("40.00"), "description": "Dinner", "currency": "USD", "date": "2023-05-01", "splits": splits}


# ---- pure payload ----

def test_build_payload():
    payload = writer.build_payload(
        _expense_dict([
            {"user_identifier": "alice", "paid_share": Decimal("40.00"), "owed_share": Decimal("20.00")},
            {"user_identifier": "bob", "paid_share": Decimal("0"), "owed_share": Decimal("20.00")},
        ]),
        "123",
        {"alice": "11", "bob": "22"},
    )
    assert payload["group_id"] == 123
    assert payload["cost"] == "40.00"
    assert {u["user_id"] for u in payload["users"]} == {"11", "22"}


def test_resolve_category_id():
    from app.integrations.splitwise import mapper
    name_to_id = {"groceries": 12, "dining out": 13, "gas/fuel": 30, "entertainment": 1,
                  "taxes": 40, "hotel": 41, "tv/phone/internet": 50}
    assert mapper.resolve_category_id("Groceries", name_to_id) == 12     # direct match
    assert mapper.resolve_category_id("Dining", name_to_id) == 13        # alias → "dining out"
    assert mapper.resolve_category_id("Fuel", name_to_id) == 30          # alias → "gas/fuel"
    assert mapper.resolve_category_id("Entertainment", name_to_id) == 1  # direct (parent name)
    assert mapper.resolve_category_id("Fees", name_to_id) == 40          # alias → "taxes"
    assert mapper.resolve_category_id("Travel", name_to_id) == 41        # alias → "hotel"
    # Subscriptions is a cross-cutting app concept with no Splitwise home → pushes as "General".
    assert mapper.resolve_category_id("Subscriptions", name_to_id) is None
    assert mapper.resolve_category_id("Settle-up", name_to_id) is None   # settle-ups push as payment
    assert mapper.resolve_category_id("Nonexistent", name_to_id) is None
    assert mapper.resolve_category_id(None, name_to_id) is None


def test_build_payload_carries_category_id():
    swids = {"alice": "11"}
    splits = [{"user_identifier": "alice", "paid_share": Decimal("40.00"), "owed_share": Decimal("40.00")}]
    assert writer.build_payload(_expense_dict(splits), "1", swids, category_id=13)["category_id"] == 13
    assert writer.build_payload(_expense_dict(splits), "1", swids)["category_id"] is None  # default


def test_build_sw_expense_sets_category():
    payload = {"cost": "40.00", "description": "Dinner", "currency_code": "USD", "date": "2023-05-01",
               "group_id": 1, "users": [], "category_id": 13}
    expense = sw_client._build_sw_expense(payload)
    assert expense.getCategory() is not None and expense.getCategory().getId() == 13
    # No category_id → no category set.
    assert sw_client._build_sw_expense({**payload, "category_id": None}).getCategory() is None


def test_build_payload_carries_details():
    swids = {"alice": "11"}
    splits = [{"user_identifier": "alice", "paid_share": Decimal("40.00"), "owed_share": Decimal("40.00")}]
    with_note = {**_expense_dict(splits), "notes": "Table 12"}
    assert writer.build_payload(with_note, "1", swids)["details"] == "Table 12"
    # No notes key → details is None (SDK layer coerces to "" so it clears rather than sends "None").
    assert writer.build_payload(_expense_dict(splits), "1", swids)["details"] is None


def test_build_sw_expense_sets_details():
    base = {"cost": "40.00", "description": "Dinner", "currency_code": "USD", "date": "2023-05-01",
            "group_id": 1, "users": []}
    assert sw_client._build_sw_expense({**base, "details": "Table 12"}).getDetails() == "Table 12"
    # A cleared/absent note pushes an empty string (clears on Splitwise), never the literal "None".
    assert sw_client._build_sw_expense({**base, "details": None}).getDetails() == ""
    assert sw_client._build_sw_expense(base).getDetails() == ""


def test_build_payload_marks_settleup_as_payment():
    swids = {"alice": "11", "bob": "22"}
    splits = [
        {"user_identifier": "alice", "paid_share": Decimal("50.00"), "owed_share": Decimal("0")},
        {"user_identifier": "bob", "paid_share": Decimal("0"), "owed_share": Decimal("50.00")},
    ]
    assert writer.build_payload(_expense_dict(splits), "1", swids)["payment"] is False
    settle = {**_expense_dict(splits), "category": "Settle-up"}
    assert writer.build_payload(settle, "1", swids)["payment"] is True


def test_build_payload_missing_swid():
    try:
        writer.build_payload(_expense_dict([{"user_identifier": "alice", "paid_share": Decimal("40"), "owed_share": Decimal("40")}]), "1", {})
    except KeyError as exc:
        assert exc.args[0] == "alice"
        return
    raise AssertionError("expected KeyError")


# ---- DB-backed helpers ----

async def _seed_expense(session, *, swid_users=True, splitwise_expense_id=None, notes=None):
    if swid_users:
        session.add(User(identifier="pw-alice", display_name="M", source=UserSource.app, splitwise_user_id="11"))
        session.add(User(identifier="pw-bob", display_name="N", source=UserSource.splitwise, splitwise_user_id="22"))
    group = Group(name="pw-g", backend_type=BackendType.splitwise, splitwise_group_id="500")
    session.add(group)
    await session.flush()
    expense = Expense(group_id=group.id, description="d", amount=Decimal("40.00"), currency="USD",
                      date=date(2023, 1, 1), splitwise_expense_id=splitwise_expense_id, notes=notes)
    expense.splits = [
        Split(user_identifier="pw-alice", paid_share=Decimal("40"), owed_share=Decimal("20")),
        Split(user_identifier="pw-bob", paid_share=Decimal("0"), owed_share=Decimal("20")),
    ]
    session.add(expense)
    await session.commit()
    return group, expense


async def _purge():
    async with async_session() as session:
        await session.execute(delete(Group).where(Group.splitwise_group_id == "500"))
        await session.execute(delete(User).where(User.identifier.in_(["pw-alice", "pw-bob"])))
        await session.execute(delete(SplitwiseToken).where(
            SplitwiseToken.user_identifier.in_(["pw-alice", "pw-caller", "anyone"])))
        await session.commit()


async def test_push_create_sets_id():
    await _purge()
    try:
        async with async_session() as session:
            group, expense = await _seed_expense(session)
            captured = {}

            def fake_create(client, payload):
                captured["p"] = payload
                return "sw-777"

            original = sw_client.create_expense
            sw_client.create_expense = fake_create
            try:
                sw_id = await writer.push_create(session, expense, group, object())
            finally:
                sw_client.create_expense = original
            assert sw_id == "sw-777" and expense.splitwise_expense_id == "sw-777"
            assert captured["p"]["group_id"] == 500
            assert {u["user_id"] for u in captured["p"]["users"]} == {"11", "22"}
    finally:
        await _purge()


async def test_push_carries_notes():
    """The full writer chain (_expense_to_dict → build_payload) forwards the expense's notes as `details`."""
    await _purge()
    try:
        async with async_session() as session:
            group, expense = await _seed_expense(session, notes="Table 12")
            captured = {}

            def fake_create(client, payload):
                captured["p"] = payload
                return "sw-778"

            original = sw_client.create_expense
            sw_client.create_expense = fake_create
            try:
                await writer.push_create(session, expense, group, object())
            finally:
                sw_client.create_expense = original
            assert captured["p"]["details"] == "Table 12"
    finally:
        await _purge()


async def test_push_update_calls_sdk():
    await _purge()
    try:
        async with async_session() as session:
            group, expense = await _seed_expense(session, splitwise_expense_id="sw-existing")
            captured = {}

            def fake_update(client, sw_id, payload):
                captured["id"] = sw_id
                return sw_id

            original = sw_client.update_expense
            sw_client.update_expense = fake_update
            try:
                result = await writer.push_update(session, expense, group, object())
            finally:
                sw_client.update_expense = original
            assert result == "sw-existing" and captured["id"] == "sw-existing"
    finally:
        await _purge()


async def test_push_delete_calls_sdk():
    captured = {}

    def fake_delete(client, sw_id):
        captured["id"] = sw_id

    original = sw_client.delete_expense
    sw_client.delete_expense = fake_delete
    try:
        await writer.push_delete(object(), "sw-del")
    finally:
        sw_client.delete_expense = original
    assert captured["id"] == "sw-del"


async def test_select_token_prefers_payer():
    await _purge()
    try:
        async with async_session() as session:
            group, expense = await _seed_expense(session)
            session.add(SplitwiseToken(user_identifier="pw-alice", access_token="tok-alice"))
            session.add(SplitwiseToken(user_identifier="anyone", access_token="tok-other"))
            await session.commit()
            token = await writer.select_token(session, expense)
            assert token.user_identifier == "pw-alice"  # payer (paid_share > 0)
    finally:
        await _purge()


async def test_select_token_prefers_caller_over_payer():
    # With duplicate tokens, the authenticated caller's token wins even though the payer differs - this is
    # the "connected but no token" case where the expense payer id isn't the id the token is stored under.
    await _purge()
    try:
        async with async_session() as session:
            group, expense = await _seed_expense(session)
            session.add(SplitwiseToken(user_identifier="pw-alice", access_token="tok-alice"))   # payer
            session.add(SplitwiseToken(user_identifier="pw-caller", access_token="tok-caller"))  # the caller
            await session.commit()
            token = await writer.select_token(session, expense, caller="pw-caller")
            assert token.user_identifier == "pw-caller"
    finally:
        await _purge()


async def test_select_token_falls_back_to_single():
    # Caller has no token, but exactly one is stored → use it (a lone token works regardless of its id).
    await _purge()
    try:
        async with async_session() as session:
            group, expense = await _seed_expense(session, swid_users=False)
            session.add(SplitwiseToken(user_identifier="anyone", access_token="tok-only"))
            await session.commit()
            token = await writer.select_token(session, expense, caller="pw-caller")
            assert token.user_identifier == "anyone"
    finally:
        await _purge()


async def test_push_guard_rails_http():
    sw_id = json.loads(_req("POST", "/groups", {"name": "pw-http"})[1])["id"]
    # turn it into a Splitwise group directly
    async with async_session() as session:
        from uuid import UUID
        grp = await session.get(Group, UUID(sw_id))
        grp.backend_type = BackendType.splitwise
        grp.splitwise_group_id = "900"
        await session.commit()
    try:
        balanced = [{"user_identifier": "pw-x", "paid_share": "10.00", "owed_share": "10.00"}]
        # no token stored -> 409
        assert _req("POST", "/expenses", {"group_id": sw_id, "description": "x", "amount": "10.00", "date": "2023-01-01", "splits": balanced})[0] == 409
        # token present but participant has no splitwise_user_id -> 422
        async with async_session() as session:
            session.add(SplitwiseToken(user_identifier="anyone", access_token="x"))
            await session.commit()
        assert _req("POST", "/expenses", {"group_id": sw_id, "description": "x", "amount": "10.00", "date": "2023-01-01", "splits": balanced})[0] == 422
    finally:
        async with async_session() as session:
            await session.execute(delete(Group).where(Group.id == __import__("uuid").UUID(sw_id)))
            await session.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == "anyone"))
            await session.commit()


def test_status_and_import_without_token():
    status = json.loads(_req("GET", "/splitwise/status")[1])
    assert status["connected"] is False
    assert _req("POST", "/splitwise/import", {"dry_run": True})[0] == 400


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
