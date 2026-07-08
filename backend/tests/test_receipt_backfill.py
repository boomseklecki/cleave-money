"""pending_receipt_expense_ids: which expenses still need their Splitwise receipt downloaded - newest-first,
excluding ones already receipted / without a receipt URL / outside the given groups. DB-backed."""
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.splitwise.receipts import pending_receipt_expense_ids
from app.models import BackendType, Expense, Group, Receipt

TAG = "rcpt-bf-zzz"


def _expense(group_id, *, url, when, desc):
    return Expense(group_id=group_id, description=desc, amount=Decimal("1.00"), currency="USD",
                   date=when, splitwise_receipt_url=url)


async def _purge():
    async with async_session() as s:
        gids = (await s.scalars(select(Group.id).where(Group.name == TAG))).all()
        if gids:
            eids = (await s.scalars(select(Expense.id).where(Expense.group_id.in_(gids)))).all()
            if eids:
                await s.execute(delete(Receipt).where(Receipt.expense_id.in_(eids)))
            await s.execute(delete(Expense).where(Expense.group_id.in_(gids)))
            await s.execute(delete(Group).where(Group.id.in_(gids)))
        await s.commit()


async def test_pending_newest_first_and_filters():
    await _purge()
    try:
        async with async_session() as s:
            g1 = Group(name=TAG, backend_type=BackendType.self_hosted)
            g2 = Group(name=TAG, backend_type=BackendType.self_hosted)
            s.add_all([g1, g2]); await s.flush()
            e_old = _expense(g1.id, url="http://r/old", when=date(2026, 3, 3), desc="old")   # pending
            e_new = _expense(g1.id, url="http://r/new", when=date(2026, 3, 5), desc="new")   # pending (newer)
            e_done = _expense(g1.id, url="http://r/done", when=date(2026, 3, 4), desc="done")  # already receipted
            e_nourl = _expense(g1.id, url=None, when=date(2026, 3, 6), desc="nourl")          # no receipt URL
            e_other = _expense(g2.id, url="http://r/other", when=date(2026, 3, 9), desc="other")  # other group
            s.add_all([e_old, e_new, e_done, e_nourl, e_other]); await s.flush()
            s.add(Receipt(expense_id=e_done.id, bucket="b", object_key="k", content_type="image/jpeg"))
            await s.commit()

            ids = await pending_receipt_expense_ids(s, [g1.id])
            assert ids == [e_new.id, e_old.id]                          # newest-first, excludes done/nourl/other
            assert await pending_receipt_expense_ids(s, [g1.id], limit=1) == [e_new.id]
            assert await pending_receipt_expense_ids(s, []) == []        # no groups → nothing
            assert set(await pending_receipt_expense_ids(s, [g1.id, g2.id])) == {e_new.id, e_old.id, e_other.id}
    finally:
        await _purge()


def test_fetch_receipt_bytes_rejects_non_image():
    """A 200 with an HTML/CDN error-page body must NOT be stored as a receipt; only image/pdf is kept.
    Audit Medium #13(f)."""
    from app.integrations.splitwise import client as sw_client

    class _Resp:
        def __init__(self, content, ctype):
            self.content = content
            self.headers = {"content-type": ctype}

        def raise_for_status(self):
            pass

    orig = sw_client.requests.get
    try:
        sw_client.requests.get = lambda url, headers=None, timeout=None: _Resp(b"<html>err</html>",
                                                                                "text/html; charset=utf-8")
        raised = False
        try:
            sw_client.fetch_receipt_bytes("tok", "http://x")
        except ValueError:
            raised = True
        assert raised, "expected a non-image body to be rejected"
        sw_client.requests.get = lambda url, headers=None, timeout=None: _Resp(b"\x89PNG", "image/png")
        data, ctype = sw_client.fetch_receipt_bytes("tok", "http://x")   # a real image is accepted
        assert data == b"\x89PNG" and ctype == "image/png"
    finally:
        sw_client.requests.get = orig


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
