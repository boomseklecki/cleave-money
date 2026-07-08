"""Plaid SDK wrapper.

Responses are converted to plain dicts via `.to_dict()` so the rest of the code
never touches Plaid model objects. All methods are blocking - call via to_thread.
"""
import base64
from urllib.parse import urlsplit

import plaid
from plaid.api import plaid_api
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.country_code import CountryCode
from plaid.model.institutions_get_by_id_request import InstitutionsGetByIdRequest
from plaid.model.institutions_get_by_id_request_options import InstitutionsGetByIdRequestOptions
from plaid.model.item_get_request import ItemGetRequest
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.item_remove_request import ItemRemoveRequest
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
from plaid.model.link_token_transactions import LinkTokenTransactions
from plaid.model.products import Products
from plaid.model.transactions_sync_request import TransactionsSyncRequest

from app.config import settings


def _build_api() -> plaid_api.PlaidApi:
    host = getattr(plaid.Environment, settings.plaid_env.capitalize(), plaid.Environment.Sandbox)
    configuration = plaid.Configuration(
        host=host,
        api_key={"clientId": settings.plaid_client_id, "secret": settings.plaid_secret},
    )
    return plaid_api.PlaidApi(plaid.ApiClient(configuration))


def _domain_from_url(url: str | None) -> str | None:
    """Registrable host from an institution URL (lowercased, `www.` stripped), for the /logos proxy."""
    if not url:
        return None
    host = urlsplit(url if "//" in url else f"//{url}").hostname
    if not host:
        return None
    host = host.lower()
    return host[4:] if host.startswith("www.") else host


def _institution_status(status: dict | None) -> str | None:
    """A coarse connection-health string, preferring the transactions product's status."""
    if not isinstance(status, dict):
        return None
    for key in ("transactions_updates", "item_logins", "auth"):
        section = status.get(key)
        if isinstance(section, dict) and section.get("status"):
            return section["status"]  # e.g. "HEALTHY" / "DEGRADED" / "DOWN"
    return None


def _decode_logo(logo: str | None) -> bytes | None:
    """Decode Plaid's base64 institution logo (PNG) to bytes, or None."""
    if not logo:
        return None
    try:
        return base64.b64decode(logo)
    except (ValueError, TypeError):
        return None


def _normalize_account(account: dict) -> dict:
    balances = account.get("balances") or {}
    return {
        "plaid_account_id": account.get("account_id"),
        "name": account.get("name") or account.get("official_name"),
        "type": str(account.get("subtype") or account.get("type") or "") or None,
        "balance": balances.get("current"),
        "available_balance": balances.get("available"),  # available credit (cards) / funds (depository)
        "currency": balances.get("iso_currency_code") or "USD",
        # Account number's last few digits - persisted and shown on each account row.
        "mask": account.get("mask"),
    }


def _transaction_category(transaction: dict) -> str | None:
    """Plaid's category. Prefers the current `personal_finance_category` taxonomy (the legacy
    `category` array is deprecated and comes back null on modern items) - `detailed` first so we can
    tell e.g. groceries from restaurants, then `primary`, then the legacy array as a last resort."""
    pfc = transaction.get("personal_finance_category") or {}
    if isinstance(pfc, dict):
        detailed = pfc.get("detailed") or pfc.get("primary")
        if detailed:
            return detailed
    legacy = transaction.get("category")
    return legacy[0] if isinstance(legacy, list) and legacy else None


def _normalize_transaction(transaction: dict) -> dict:
    return {
        "plaid_transaction_id": transaction.get("transaction_id"),
        "plaid_account_id": transaction.get("account_id"),
        "description": transaction.get("name") or transaction.get("merchant_name") or "",
        "amount": transaction.get("amount"),
        "currency": transaction.get("iso_currency_code") or "USD",
        "date": transaction.get("date"),
        "category": _transaction_category(transaction),
        "pending": transaction.get("pending", False),
        # On a posted transaction, points back to the pending transaction it replaced (used during sync to
        # carry the pending row's user data - overrides, items, expense link - onto the posted row).
        "pending_transaction_id": transaction.get("pending_transaction_id"),
    }


class PlaidClient:
    def __init__(self) -> None:
        self._api = _build_api()

    def create_link_token(self, user_identifier: str) -> str:
        kwargs = dict(
            user=LinkTokenCreateRequestUser(client_user_id=user_identifier),
            client_name=settings.app_name,
            products=[Products(p.strip()) for p in settings.plaid_products.split(",")],
            country_codes=[CountryCode(c.strip()) for c in settings.plaid_country_codes.split(",")],
            language=settings.plaid_language,
        )
        # Request extended history ONLY when configured (>0). Sending a `transactions.days_requested` block
        # changes the data scope in the OAuth authorization, which some OAuth institutions (e.g. PNC) reject
        # at the bank ("Access Denied"). Set PLAID_TRANSACTIONS_DAYS_REQUESTED=0 to omit it entirely - the
        # original behavior that worked for those banks.
        if settings.plaid_transactions_days_requested > 0:
            kwargs["transactions"] = LinkTokenTransactions(
                days_requested=settings.plaid_transactions_days_requested
            )
        # Only include redirect_uri when configured - an unregistered value rejects every link token.
        if settings.plaid_redirect_uri:
            kwargs["redirect_uri"] = settings.plaid_redirect_uri
        return self._api.link_token_create(LinkTokenCreateRequest(**kwargs)).to_dict()["link_token"]

    def exchange_public_token(self, public_token: str) -> tuple[str, str]:
        response = self._api.item_public_token_exchange(
            ItemPublicTokenExchangeRequest(public_token=public_token)
        ).to_dict()
        return response["access_token"], response["item_id"]

    def get_institution(self, access_token: str) -> dict | None:
        """Resolve an item's institution metadata from Plaid (best-effort; None on any failure, so a
        link/sync never breaks just because the lookup did). Two calls: item_get for the institution id,
        then institutions_get_by_id (with optional metadata + status). Returns
        {institution_id, name, domain, primary_color, status, logo_bytes}."""
        try:
            item = self._api.item_get(ItemGetRequest(access_token=access_token)).to_dict()
            institution_id = (item.get("item") or {}).get("institution_id")
            if not institution_id:
                return None
            country_codes = [
                CountryCode(c.strip()) for c in settings.plaid_country_codes.split(",")
            ]
            response = self._api.institutions_get_by_id(
                InstitutionsGetByIdRequest(
                    institution_id=institution_id,
                    country_codes=country_codes,
                    options=InstitutionsGetByIdRequestOptions(
                        include_optional_metadata=True, include_status=True
                    ),
                )
            ).to_dict()
            inst = response.get("institution") or {}
            return {
                "institution_id": institution_id,
                "name": inst.get("name"),
                "domain": _domain_from_url(inst.get("url")),
                "primary_color": inst.get("primary_color"),
                "status": _institution_status(inst.get("status")),
                "logo_bytes": _decode_logo(inst.get("logo")),
            }
        except Exception:
            return None

    def get_institution_name(self, access_token: str) -> str | None:
        """Back-compat convenience: just the institution name."""
        info = self.get_institution(access_token)
        return info.get("name") if info else None

    def item_remove(self, access_token: str) -> None:
        """Invalidate an item's access token at Plaid (called on unlink / account deletion)."""
        self._api.item_remove(ItemRemoveRequest(access_token=access_token))

    def get_accounts(self, access_token: str) -> list[dict]:
        response = self._api.accounts_get(
            AccountsGetRequest(access_token=access_token)
        ).to_dict()
        return [_normalize_account(a) for a in response["accounts"]]

    def fetch_transactions_page(self, access_token: str, cursor: str | None) -> dict:
        kwargs = {"access_token": access_token}
        if cursor:
            kwargs["cursor"] = cursor
        response = self._api.transactions_sync(TransactionsSyncRequest(**kwargs)).to_dict()
        return {
            "added": [_normalize_transaction(t) for t in response["added"]],
            "modified": [_normalize_transaction(t) for t in response["modified"]],
            "removed": [t["transaction_id"] for t in response["removed"]],
            "next_cursor": response["next_cursor"],
            "has_more": response["has_more"],
        }


def make_client() -> PlaidClient:
    return PlaidClient()
