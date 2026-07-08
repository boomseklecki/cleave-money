"""Pure unit tests for backup retention selection (no DB / no MinIO)."""
from datetime import datetime, timedelta, timezone

from app.services.backups import KIND_MANUAL, KIND_SCHEDULED, BackupInfo, select_prunable

NOW = datetime(2026, 6, 22, 12, 0, tzinfo=timezone.utc)


def _b(name: str, *, days_ago: int, kind: str) -> BackupInfo:
    return BackupInfo(name=name, size_bytes=1, created_at=NOW - timedelta(days=days_ago),
                      label=None, kind=kind)


def test_keeps_min_recent_even_when_old():
    # All scheduled and older than 30d, but min_keep=7 protects the newest 7.
    infos = [_b(f"s{i}", days_ago=40 + i, kind=KIND_SCHEDULED) for i in range(10)]
    doomed = select_prunable(infos, retention_days=30, min_keep=7, now=NOW)
    assert len(doomed) == 3                      # 10 scheduled - 7 kept
    assert set(doomed) == {"s7", "s8", "s9"}     # the three oldest


def test_age_floor_within_min_keep_window_keeps_all():
    # Fewer than min_keep scheduled -> nothing pruned regardless of age.
    infos = [_b(f"s{i}", days_ago=100 + i, kind=KIND_SCHEDULED) for i in range(5)]
    assert select_prunable(infos, retention_days=30, min_keep=7, now=NOW) == []


def test_only_old_beyond_floor_pruned():
    # Newest 7 kept; of the rest, only those older than 30d are deleted.
    infos = ([_b(f"recent{i}", days_ago=i, kind=KIND_SCHEDULED) for i in range(7)]
             + [_b("old", days_ago=45, kind=KIND_SCHEDULED),
                _b("young", days_ago=10, kind=KIND_SCHEDULED)])
    doomed = select_prunable(infos, retention_days=30, min_keep=7, now=NOW)
    assert doomed == ["old"]                      # "young" is past the floor but not old enough


def test_manual_never_pruned():
    infos = [_b(f"m{i}", days_ago=500 + i, kind=KIND_MANUAL) for i in range(20)]
    assert select_prunable(infos, retention_days=30, min_keep=7, now=NOW) == []


def test_manual_does_not_count_toward_min_keep():
    # Manual backups are ignored entirely; the floor applies only across scheduled ones.
    infos = ([_b(f"m{i}", days_ago=1, kind=KIND_MANUAL) for i in range(7)]
             + [_b("sched-old", days_ago=40, kind=KIND_SCHEDULED)])
    # Only 1 scheduled, so it's within the min_keep=7 scheduled floor -> not pruned.
    assert select_prunable(infos, retention_days=30, min_keep=7, now=NOW) == []


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
