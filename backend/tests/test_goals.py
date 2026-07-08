"""Goals CRUD. (Per-(owner, account) overrides are covered in test_account_overrides.)"""
import json
import urllib.error
import urllib.request

from sqlalchemy import delete

from app.db import async_session
from app.models import Goal

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
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


async def test_spend_goal_crud_and_archive():
    goal_id = None
    try:
        status, body = _req("POST", "/goals", {
            "kind": "spend", "name": "Dining", "category": "Dining", "target_amount": "300.00",
        })
        assert status == 201, (status, body)
        goal_id = json.loads(body)["id"]
        assert any(g["id"] == goal_id for g in json.loads(_req("GET", "/goals")[1]))

        status, body = _req("PATCH", f"/goals/{goal_id}", {"target_amount": "250.00"})
        assert status == 200, (status, body)
        assert json.loads(body)["target_amount"] == "250.00"

        # Archive: gone from the default list, present with include_archived.
        assert _req("DELETE", f"/goals/{goal_id}")[0] == 204
        assert not any(g["id"] == goal_id for g in json.loads(_req("GET", "/goals")[1]))
        assert any(g["id"] == goal_id for g in json.loads(_req("GET", "/goals?include_archived=true")[1]))
    finally:
        if goal_id:
            async with async_session() as session:
                await session.execute(delete(Goal).where(Goal.id == goal_id))
                await session.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
