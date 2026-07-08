"""Incremental Splitwise expense sync for every stored token (for cron / scheduled runs).

Pulls only what changed since each token's cursor (expenses_synced_at), deletes expenses
Splitwise has deleted, and advances the cursor. The first run (no cursor) does a full pull.

Usage (inside the api container):
    python -m app.cli.splitwise_sync
"""
import asyncio
from datetime import datetime, timezone

from sqlalchemy import select

from app.config import settings
from app.db import async_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import importer
from app.models import SplitwiseToken


async def _run() -> None:
    async with async_session() as session:
        tokens = (await session.scalars(select(SplitwiseToken))).all()
        if not tokens:
            print("No Splitwise tokens stored; nothing to sync.")
            return
        for token in tokens:
            client = sw_client.make_client(token.access_token)
            updated_after = (
                token.expenses_synced_at.isoformat() if token.expenses_synced_at else None
            )
            started = datetime.now(timezone.utc)
            stats = await importer.sync_expenses(
                session, client, settings.splitwise_user_map, updated_after=updated_after
            )
            token.expenses_synced_at = started
            await session.commit()
            print(f"Synced {token.user_identifier}: {stats}")


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
