"""Thin wrapper over the `splitwise` package that normalizes objects to plain dicts.

Keeping the read layer dict-based decouples the mapper from the package and makes
both independently testable.
"""
import html
import re
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

import requests
from splitwise import Splitwise
from splitwise.category import Category as SplitwiseCategory
from splitwise.expense import Expense as SplitwiseExpense
from splitwise.group import Group as SplitwiseGroup
from splitwise.user import ExpenseUser
from splitwise.user import User as SplitwiseUser

from app.config import settings

_PAGE_SIZE = 200
_API_BASE = "https://secure.splitwise.com/api/v3.0"


def make_client(access_token: str) -> Splitwise:
    client = Splitwise(settings.splitwise_consumer_key, settings.splitwise_consumer_secret)
    client.setOAuth2AccessToken({"access_token": access_token, "token_type": "bearer"})
    return client


def fetch_receipt_bytes(access_token: str, url: str) -> tuple[bytes, str]:
    """Fetch a Splitwise receipt image. The receipt URL is an authenticated API endpoint, so it needs
    the user's OAuth token - it can't be loaded directly by the app. Returns (bytes, content_type)."""
    resp = requests.get(url, headers={"Authorization": f"Bearer {access_token}"}, timeout=30)
    resp.raise_for_status()
    content_type = (resp.headers.get("content-type") or "image/jpeg").split(";")[0].strip().lower()
    # A 200 isn't enough - a CDN/login error page returns 200 with text/html. Only store real receipt media,
    # so an error page never lands in MinIO as a "receipt".
    if not (content_type.startswith("image/") or content_type == "application/pdf"):
        raise ValueError(f"Splitwise receipt is not image/pdf (content-type={content_type})")
    return resp.content, content_type


_RECEIPT_SIZES = {"small", "medium", "large", "original"}


def receipt_url_with_size(url: str, size: str | None) -> str:
    """Rewrite the `size` query param on a Splitwise receipt URL (large/original/...). Unknown sizes
    leave the URL unchanged."""
    if size not in _RECEIPT_SIZES:
        return url
    parts = urlparse(url)
    query = parse_qs(parts.query)
    query["size"] = [size]
    return urlunparse(parts._replace(query=urlencode(query, doseq=True)))


def _method(obj, name: str):
    """Call ``obj.name()`` only when it is a real callable method, else return None.

    The `splitwise` SDK objects define ``__getattr__`` to return None for unknown attributes, so
    ``hasattr(obj, "getWhatever")`` is always True and ``obj.getWhatever()`` raises
    ``TypeError: 'NoneType' object is not callable`` for getters the package doesn't implement.
    Guarding on ``callable()`` is the only safe check.
    """
    fn = getattr(obj, name, None)
    return fn() if callable(fn) else None


def _flag(obj, attr: str, getter: str):
    """A bool-ish flag: prefer the data attribute, fall back to a real getter method."""
    val = getattr(obj, attr, None)
    return val if val is not None else _method(obj, getter)


def _str_or_none(value) -> str | None:
    return str(value) if value is not None else None


def _registration_status(user) -> str | None:
    """Splitwise registration_status ('confirmed' | 'invited' | 'dummy'), when the package exposes it."""
    return _method(user, "getRegistrationStatus") or getattr(user, "registration_status", None)


def _first_url(obj, getters: tuple[str, ...]) -> str | None:
    """First non-empty URL from an image object (avatar/cover/receipt) across the given getters."""
    if obj is None:
        return None
    for getter in getters:
        url = _method(obj, getter)
        if url:
            return url
    return None


def _group_type(group) -> str | None:
    return _method(group, "getGroupType") or getattr(group, "group_type", None)


def _avatar_url(group) -> str | None:
    """Group avatar URL - only a *custom* one (Splitwise serves a generated default otherwise)."""
    if _flag(group, "custom_avatar", "getCustomAvatar") is False:
        return None
    return _first_url(_method(group, "getAvatar"), ("getMedium", "getLarge", "getOriginal"))


def _cover_photo_url(group) -> str | None:
    return _first_url(_method(group, "getCoverPhoto"), ("getXxlarge", "getXlarge", "getOriginal"))


def _receipt_url(expense) -> str | None:
    return _first_url(_method(expense, "getReceipt"), ("getLarge", "getOriginal"))


def _repayments(expense) -> list[dict]:
    """Splitwise's simplified net transfers for an expense: [{from, to, amount}]."""
    out: list[dict] = []
    for r in (_method(expense, "getRepayments") or []):
        out.append({
            "from": _str_or_none(_method(r, "getFromUser")),
            "to": _str_or_none(_method(r, "getToUser")),
            "amount": _method(r, "getAmount"),
        })
    return out


def _user_ref(obj, getter: str) -> dict | None:
    """Extract {user_id, first_name, last_name} from a related Splitwise user (e.g. created_by)."""
    user = _method(obj, getter)
    uid = _method(user, "getId") if user is not None else None
    if uid is None:
        return None
    return {
        "user_id": str(uid),
        "first_name": _method(user, "getFirstName") or "",
        "last_name": _method(user, "getLastName") or "",
    }


def _picture_url(user) -> str | None:
    """The medium avatar URL for a Splitwise user/member - but only a *custom* one.

    Splitwise returns a generic placeholder picture for users who never set one; `custom_picture`
    is False for those, and we'd rather fall back to initials than show the placeholder. When the
    flag isn't available, we keep the picture so we never regress.
    """
    if _flag(user, "custom_picture", "getCustomPicture") is False:
        return None
    return _first_url(_method(user, "getPicture"), ("getMedium", "getLarge", "getOriginal"))


def get_current_user(client: Splitwise) -> dict:
    """The authenticated Splitwise user, normalized for sign-in/find-or-create."""
    user = client.getCurrentUser()
    return {
        "splitwise_id": str(user.getId()),
        "first_name": user.getFirstName() or "",
        "last_name": user.getLastName() or "",
        "email": user.getEmail(),
        "picture": _picture_url(user),
    }


def fetch_friends(client: Splitwise) -> list[dict]:
    """The authenticated user's Splitwise friends with their authoritative current balances. Splitwise keeps
    its own friend-level ledger (settle-ups, cross-group netting), so this - not a sum of per-expense
    repayments - is the source of truth for the Friends view. Each balance is per-currency."""
    out: list[dict] = []
    for friend in (client.getFriends() or []):
        out.append({
            "splitwise_id": str(_method(friend, "getId")),
            "first_name": _method(friend, "getFirstName") or "",
            "last_name": _method(friend, "getLastName") or "",
            "email": _method(friend, "getEmail"),
            "picture": _picture_url(friend),
            "balances": [
                {"currency": _method(b, "getCurrencyCode"), "amount": _method(b, "getAmount")}
                for b in (_method(friend, "getBalances") or [])
            ],
            # Per-group breakdown: each entry's balance is the friend's net WITH YOU in that group.
            "groups": [
                {
                    "splitwise_group_id": str(_method(g, "getId")),
                    "balances": [
                        {"currency": _method(b, "getCurrencyCode"), "amount": _method(b, "getAmount")}
                        for b in (_method(g, "getBalances") or [])
                    ],
                }
                for g in (_method(friend, "getGroups") or [])
            ],
        })
    return out


def _normalize_group(group) -> dict:
    members = [
        {
            "user_id": str(m.getId()),
            "first_name": m.getFirstName() or "",
            "last_name": m.getLastName() or "",
            "email": m.getEmail(),
            "picture": _picture_url(m),
            "registration_status": _registration_status(m),
        }
        for m in (group.getMembers() or [])
    ]
    return {
        "splitwise_id": str(group.getId()),
        "name": group.getName(),
        "group_type": _group_type(group),
        "avatar_url": _avatar_url(group),
        "cover_photo_url": _cover_photo_url(group),
        "members": members,
    }


def _normalize_expense(expense) -> dict:
    group_id = expense.getGroupId()
    category = expense.getCategory()
    users = [
        {
            "user_id": str(u.getId()),
            "first_name": u.getFirstName() or "",
            "last_name": u.getLastName() or "",
            "email": _method(u, "getEmail"),
            "picture": _picture_url(u),
            "registration_status": _registration_status(u),
            "paid_share": u.getPaidShare() or "0",
            "owed_share": u.getOwedShare() or "0",
        }
        for u in expense.getUsers()
    ]
    return {
        "splitwise_id": str(expense.getId()),
        "group_id": None if group_id in (None, 0) else str(group_id),
        "description": expense.getDescription() or "",
        "cost": expense.getCost() or "0",
        "currency_code": expense.getCurrencyCode() or settings.default_currency,
        "date": expense.getDate(),
        "category": category.getName() if category else None,
        "payment": bool(expense.getPayment()),
        "deleted_at": expense.getDeletedAt(),
        "receipt_url": _receipt_url(expense),
        "repayments": _repayments(expense),
        "created_by": _user_ref(expense, "getCreatedBy"),
        "updated_by": _user_ref(expense, "getUpdatedBy"),
        "created_at": _method(expense, "getCreatedAt"),
        "updated_at": _method(expense, "getUpdatedAt"),
        "notes": _method(expense, "getDetails"),
        "comments_count": _method(expense, "getCommentsCount"),
        "repeats": _method(expense, "isRepeat"),  # SDK method is isRepeat(), not getRepeats()
        "repeat_interval": _method(expense, "getRepeatInterval"),
        "expense_bundle_id": _method(expense, "getExpenseBundleId"),
        "users": users,
    }


_category_cache: dict[str, int] | None = None


def category_name_to_id(client: Splitwise) -> dict[str, int]:
    """Splitwise's global category taxonomy flattened to `{name.lower(): id}` (subcategory wins on a name
    collision). Cached for the process - the taxonomy is global and static."""
    global _category_cache
    if _category_cache is None:
        mapping: dict[str, int] = {}
        for parent in client.getCategories():
            if parent.getName():
                mapping.setdefault(parent.getName().strip().lower(), parent.getId())
            for sub in parent.getSubcategories() or []:
                if sub.getName():
                    mapping[sub.getName().strip().lower()] = sub.getId()  # subcategory overrides parent
        _category_cache = mapping
    return _category_cache


def _build_sw_expense(payload: dict, sw_id: str | None = None) -> SplitwiseExpense:
    expense = SplitwiseExpense()
    if sw_id is not None:
        expense.setId(int(sw_id))
    expense.setCost(payload["cost"])
    expense.setDescription(payload["description"])
    expense.setCurrencyCode(payload["currency_code"])
    expense.setDate(payload["date"])
    expense.setGroupId(payload["group_id"])
    # Push the Splitwise "details" note; coerce None → "" so it never serializes "None" and clearing propagates.
    expense.setDetails(payload.get("details") or "")
    if payload.get("category_id"):
        category = SplitwiseCategory()
        category.setId(int(payload["category_id"]))
        expense.setCategory(category)
    if payload.get("payment"):
        expense.setPayment(True)
    for member in payload["users"]:
        user = ExpenseUser()
        user.setId(int(member["user_id"]))
        user.setPaidShare(member["paid_share"])
        user.setOwedShare(member["owed_share"])
        expense.addUser(user)
    return expense


def create_expense(client: Splitwise, payload: dict) -> str:
    """Create an expense in Splitwise from a push payload; returns its id."""
    created, errors = client.createExpense(_build_sw_expense(payload))
    if errors:
        raise RuntimeError(errors.getErrors())
    return str(created.getId())


def update_expense(client: Splitwise, sw_id: str, payload: dict) -> str:
    """Update an existing Splitwise expense; returns its id."""
    updated, errors = client.updateExpense(_build_sw_expense(payload, sw_id=sw_id))
    if errors:
        raise RuntimeError(errors.getErrors())
    return str(updated.getId())


def delete_expense(client: Splitwise, sw_id: str) -> None:
    success, errors = client.deleteExpense(int(sw_id))
    if errors:
        raise RuntimeError(errors.getErrors())


def fetch_groups(client: Splitwise) -> list[dict]:
    return [_normalize_group(g) for g in client.getGroups()]


def fetch_group(client: Splitwise, sw_group_id: str) -> dict | None:
    """Fetch a single group by id (normalized), or None when missing."""
    group = client.getGroup(int(sw_group_id))
    if group is None or _method(group, "getId") is None:
        return None
    return _normalize_group(group)


def create_group(client: Splitwise, name: str, group_type: str | None = None) -> dict:
    """Create a group on Splitwise (the authenticated user is added as a member); returns the
    normalized new group (carries its `splitwise_id`)."""
    group = SplitwiseGroup()
    group.setName(name)
    if group_type:
        group.setGroupType(group_type)
    created, errors = client.createGroup(group)
    if errors:
        raise RuntimeError(errors.getErrors())
    return _normalize_group(created)


def delete_group(client: Splitwise, sw_group_id: str) -> None:
    """Delete a group on Splitwise (for everyone in it)."""
    success, errors = client.deleteGroup(int(sw_group_id))
    if errors:
        raise RuntimeError(errors.getErrors())


def add_user_to_group(
    client: Splitwise,
    sw_group_id: str,
    *,
    user_id: str | None = None,
    first_name: str | None = None,
    last_name: str | None = None,
    email: str | None = None,
) -> dict | None:
    """Add a member to a Splitwise group - by existing Splitwise `user_id`, or by name/email to invite a
    new person. Returns the added user (normalized) so the caller can upsert the directory."""
    user = SplitwiseUser()
    if user_id is not None:
        user.setId(int(user_id))
    if first_name:
        user.setFirstName(first_name)
    if last_name:
        user.setLastName(last_name)
    if email:
        user.setEmail(email)
    success, added, errors = client.addUserToGroup(user, int(sw_group_id))
    if errors:
        raise RuntimeError(errors.getErrors())
    if added is None:
        return None
    return {
        "splitwise_id": _str_or_none(_method(added, "getId")),
        "first_name": _method(added, "getFirstName") or "",
        "last_name": _method(added, "getLastName") or "",
        "email": _method(added, "getEmail"),
        "picture": _picture_url(added),
    }


def remove_user_from_group(access_token: str, sw_group_id: str, sw_user_id: str) -> None:
    """Remove a member from a Splitwise group. The SDK doesn't expose this, so call the REST endpoint."""
    resp = requests.post(
        f"{_API_BASE}/remove_user_from_group",
        headers={"Authorization": f"Bearer {access_token}"},
        json={"group_id": int(sw_group_id), "user_id": int(sw_user_id)},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    if not data.get("success", True):
        raise RuntimeError(data.get("errors") or "remove_user_from_group failed")


def restore_group(access_token: str, sw_group_id: str) -> None:
    """Restore a previously deleted Splitwise group **and its expenses**. The SDK doesn't expose this, so
    call the REST `undelete_group` endpoint."""
    resp = requests.post(
        f"{_API_BASE}/undelete_group/{int(sw_group_id)}",
        headers={"Authorization": f"Bearer {access_token}"},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    if not data.get("success", True):
        raise RuntimeError(data.get("errors") or "undelete_group failed")


def fetch_expenses(
    client: Splitwise,
    dated_after: str | None = None,
    dated_before: str | None = None,
    updated_after: str | None = None,
    updated_before: str | None = None,
    group_id: str | None = None,
    friend_id: str | None = None,
) -> list[dict]:
    """Page through the user's expenses. `dated_*` windows by expense date (backfill);
    `updated_after` returns only rows changed since a cursor (incremental sync) and includes
    deleted ones. `group_id` scopes to one group, `friend_id` to expenses shared with one friend
    (drill-in scoped syncs)."""
    out: list[dict] = []
    offset = 0
    while True:
        page = client.getExpenses(
            offset=offset,
            limit=_PAGE_SIZE,
            group_id=group_id,
            friend_id=friend_id,
            dated_after=dated_after,
            dated_before=dated_before,
            updated_after=updated_after,
            updated_before=updated_before,
        )
        if not page:
            break
        out.extend(_normalize_expense(e) for e in page)
        if len(page) < _PAGE_SIZE:
            break
        offset += _PAGE_SIZE
    return out


def fetch_expense(client: Splitwise, expense_id: str) -> dict | None:
    """Fetch a single expense by id (drill-in scoped sync). Returns the normalized dict, or None
    when Splitwise has no such expense. A deleted expense still returns (with `deleted_at` set) so
    the caller can archive it."""
    expense = client.getExpense(int(expense_id))
    if expense is None or _method(expense, "getId") is None:
        return None
    return _normalize_expense(expense)


def fetch_notifications(
    client: Splitwise, access_token: str | None = None, limit: int | None = None
) -> list[dict]:
    """The authenticated user's recent Splitwise notifications (mentions, added/updated expenses,
    settle-ups, etc.), normalized to `{splitwise_id, type, content, created_at}`. `limit` caps how many
    the API returns (Splitwise defaults to a small batch).

    The `splitwise` SDK doesn't reliably expose `getNotifications()` across versions (its
    `__getattr__` masks that - see `_method`), and even when present its typed parser raises
    (e.g. KeyError 'url' on a notification whose `source` has no url), so prefer it but fall back
    to the REST endpoint on ANY failure - mirroring `fetch_receipt_bytes`."""
    try:
        notifications = _method(client, "getNotifications", limit=limit) if limit else _method(
            client, "getNotifications")
    except Exception:
        notifications = None  # SDK typed-parse blew up (e.g. source missing 'url') → use REST below
    if notifications is not None:
        return [_normalize_notification_obj(n) for n in notifications]
    if access_token is None:
        return []
    resp = requests.get(
        f"{_API_BASE}/get_notifications",
        headers={"Authorization": f"Bearer {access_token}"},
        params={"limit": limit} if limit else None,
        timeout=30,
    )
    resp.raise_for_status()
    return [_normalize_notification_dict(n) for n in (resp.json().get("notifications") or [])]


_TAG = re.compile(r"<[^>]+>")


def _clean_content(raw: str | None) -> str:
    """Splitwise notification `content` is HTML (`<strong>Alex</strong> added &quot;Dinner&quot;`). Strip
    tags + decode entities → plain text for display."""
    text = html.unescape(raw or "")
    return " ".join(_TAG.sub("", text).split())


def _normalize_notification_obj(n) -> dict:
    source = _method(n, "getSource")
    return {
        "splitwise_id": _str_or_none(_method(n, "getId")),
        "type": _str_or_none(_method(n, "getType")),
        "content": _clean_content(_method(n, "getContent")),
        "created_at": _method(n, "getCreatedAt"),
        # The referenced entity (e.g. {"Expense", <splitwise_expense_id>}) - used to deep-link the row.
        "source_type": _str_or_none(_method(source, "getType")) if source is not None else None,
        "source_id": _str_or_none(_method(source, "getId")) if source is not None else None,
    }


def _normalize_notification_dict(n: dict) -> dict:
    source = n.get("source") or {}
    return {
        "splitwise_id": _str_or_none(n.get("id")),
        "type": _str_or_none(n.get("type")),
        "content": _clean_content(n.get("content")),
        "created_at": n.get("created_at"),
        # The referenced entity ({"type": "Expense", "id": <splitwise_expense_id>}) - for deep-linking.
        "source_type": _str_or_none(source.get("type")),
        "source_id": _str_or_none(source.get("id")),
    }
