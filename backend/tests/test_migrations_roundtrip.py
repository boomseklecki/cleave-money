"""Full alembic round-trip: `upgrade head → downgrade base → upgrade head`. Exercises every migration's
`downgrade()` in one pass, so a broken downgrade (dangerous during a real rollback) is caught in CI instead of
production. Leaves the shared test DB at head via a `finally`.

Note: this briefly drops all tables (downgrade to base), so it must not run concurrently with other DB-backed
tests - the suite runs modules sequentially, so that's fine.
"""
from alembic import command
from alembic.config import Config


def test_migrations_roundtrip():
    cfg = Config("alembic.ini")
    try:
        command.upgrade(cfg, "head")     # ensure a known starting point
        command.downgrade(cfg, "base")   # every downgrade() runs; raises if any is broken
        command.upgrade(cfg, "head")     # and back up cleanly
    finally:
        command.upgrade(cfg, "head")     # leave the shared DB usable for the rest of the suite


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
