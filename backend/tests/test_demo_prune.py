"""Demo auto-prune: removes only `demo-*` guests older than the cutoff; keeps recent demo + non-demo users."""
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select, update

from app.cli.prune_demo import prune_demo_guests
from app.db import async_session
from app.models import User
from app.models.enums import UserSource

IDS = ["demo-zzz-old", "demo-zzz-new", "real-zzz"]


async def _cleanup(session):
    await session.execute(delete(User).where(User.identifier.in_(IDS)))
    await session.commit()


async def test_prunes_old_demo_only():
    async with async_session() as s:
        await _cleanup(s)
        s.add_all([
            User(identifier="demo-zzz-old", display_name="Old", source=UserSource.app, enrolled=True),
            User(identifier="demo-zzz-new", display_name="New", source=UserSource.app, enrolled=True),
            User(identifier="real-zzz", display_name="Real", source=UserSource.app, enrolled=True),
        ])
        await s.commit()
        # Backdate the "old" demo guest beyond the cutoff.
        await s.execute(update(User).where(User.identifier == "demo-zzz-old")
                        .values(created_at=datetime.now(timezone.utc) - timedelta(days=2)))
        await s.commit()
        try:
            count = await prune_demo_guests(s, timedelta(days=1))
            await s.commit()
            assert count == 1
            remaining = set(await s.scalars(select(User.identifier).where(User.identifier.in_(IDS))))
            assert remaining == {"demo-zzz-new", "real-zzz"}  # old demo gone; recent demo + non-demo kept
        finally:
            await _cleanup(s)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
