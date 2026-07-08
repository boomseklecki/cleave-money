"""Sync all Plaid items (for cron / scheduled runs).

Usage (inside the api container):
    python -m app.cli.plaid_sync
"""
import asyncio

from sqlalchemy import select

from app.db import async_session
from app.integrations.plaid import client as plaid_client
from app.integrations.plaid import sync as plaid_sync
from app.models import PlaidItem


async def _run() -> None:
    async with async_session() as session:
        items = (await session.scalars(select(PlaidItem))).all()
        if not items:
            print("No Plaid items linked; nothing to sync.")
            return
        client = plaid_client.make_client()
        for item in items:
            stats = await plaid_sync.sync_item(session, item, client)
            label = item.institution_name or item.plaid_item_id
            print(f"Synced {label}: {stats}")


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
