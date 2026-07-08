"""Historical Splitwise import.

Usage (inside the api container):
    python -m app.cli.import_splitwise --since 2020-01-01 --until 2026-06-18 [--dry-run]
    python -m app.cli.import_splitwise --as alice --dry-run
"""
import argparse
import asyncio

from sqlalchemy import select

from app.config import settings
from app.db import async_session
from app.integrations.splitwise import importer
from app.models import SplitwiseToken


async def _run(args: argparse.Namespace) -> None:
    async with async_session() as session:
        query = select(SplitwiseToken)
        if args.as_user:
            query = query.where(SplitwiseToken.user_identifier == args.as_user)
        tokens = (await session.scalars(query)).all()

        if not tokens:
            raise SystemExit(
                "No Splitwise token stored. Authorize first via /auth/splitwise/login."
            )
        if len(tokens) > 1 and not args.as_user:
            users = ", ".join(t.user_identifier for t in tokens)
            raise SystemExit(f"Multiple tokens stored ({users}); pick one with --as.")

        token = tokens[0]
        stats = await importer.run_import(
            session,
            access_token=token.access_token,
            dated_after=args.since,
            dated_before=args.until,
            user_map=settings.splitwise_user_map,
            dry_run=args.dry_run,
        )
        print(f"Import ({token.user_identifier}): {stats}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Import Splitwise expense history.")
    parser.add_argument("--since", help="dated_after, e.g. 2020-01-01")
    parser.add_argument("--until", help="dated_before, e.g. 2026-06-18")
    parser.add_argument("--as", dest="as_user", help="local identifier whose token to use")
    parser.add_argument("--dry-run", action="store_true", help="report counts, write nothing")
    asyncio.run(_run(parser.parse_args()))


if __name__ == "__main__":
    main()
