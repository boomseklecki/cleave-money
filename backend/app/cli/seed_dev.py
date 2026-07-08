"""Seed the DEVELOPMENT backend with a populated, isolated sample app for one identifier (groups with
synthetic co-members + expenses, plus that identifier's accounts/transactions/goals). Same `seed_identity`
the demo guest login uses (app.integrations.dev_seed.seeder), so `--as alice` makes you a fully-populated
test user.

With --wipe it first resets the synthetic state: all groups (cascading expenses/splits/items), group
members, every user EXCEPT the self identifier, Splitwise tokens, and the synthetic personal data (manual
accounts - plaid_item_id NULL - with their transactions, plus goals). It NEVER touches Plaid-linked
accounts/transactions/plaid_items (sandbox banks a tester linked stay) or receipts.

Usage (inside the DEV api container - never run against production):
    python -m app.cli.seed_dev --as alice --wipe
"""
import argparse
import asyncio

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.dev_seed.seeder import seed_identity
from app.models import (
    Account,
    CategoryMap,
    Connection,
    Goal,
    Group,
    GroupMember,
    SpendCategory,
    SplitwiseToken,
    Transaction,
    TransactionOverride,
    User,
)


async def _wipe(session, self_identifier: str) -> None:
    # Groups cascade to expenses -> splits/items. Members, foreign users, and Splitwise tokens go too.
    await session.execute(delete(Group))
    await session.execute(delete(GroupMember))
    await session.execute(delete(SplitwiseToken))
    await session.execute(delete(User).where(User.identifier != self_identifier))
    # Synthetic category taxonomy/maps, per-txn overrides, and partner connections - all synthetic-only, so
    # a re-seed doesn't collide on their unique keys.
    await session.execute(delete(SpendCategory))
    await session.execute(delete(CategoryMap))
    await session.execute(delete(TransactionOverride))
    await session.execute(delete(Connection))
    # Synthetic personal data: goals + manual (non-Plaid) accounts and their transactions. Plaid-linked
    # accounts/transactions (a tester's sandbox banks) are left untouched.
    await session.execute(delete(Goal))
    manual_accounts = select(Account.id).where(Account.plaid_item_id.is_(None))
    await session.execute(delete(Transaction).where(Transaction.account_id.in_(manual_accounts)))
    await session.execute(delete(Account).where(Account.plaid_item_id.is_(None)))
    await session.flush()


async def seed(session, *, self_identifier: str, wipe: bool, seed_value: int = 1234) -> dict:
    """Seed a populated isolated sample app for `self_identifier` (committed). Reused by tests."""
    if wipe:
        await _wipe(session, self_identifier)
    seeded = await seed_identity(session, self_identifier, seed_value=seed_value)
    await session.commit()
    return {"self": self_identifier, "seeded": seeded}


async def _run(args: argparse.Namespace) -> None:
    async with async_session() as session:
        stats = await seed(session, self_identifier=args.as_user, wipe=args.wipe, seed_value=args.seed)
    print(f"Seeded sample app for {stats['self']} (seeded={stats['seeded']}, wipe={args.wipe}).")


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed the dev backend with synthetic data.")
    parser.add_argument("--as", dest="as_user", default="alice",
                        help="your local identifier, kept verbatim so you sign in as yourself")
    parser.add_argument("--seed", type=int, default=1234, help="RNG seed (deterministic output)")
    parser.add_argument("--wipe", action="store_true",
                        help="reset synthetic data first (keeps Plaid-linked accounts/transactions)")
    asyncio.run(_run(parser.parse_args()))


if __name__ == "__main__":
    main()
