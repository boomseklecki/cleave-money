"""Off-device (restic) backup tier + ENCRYPTION_KEYS drift check.

DB-backed. restic itself is never invoked - `backups._run` is swapped for a recorder, so these exercise the
wiring (settings gate, repo env, backup+forget calls, status markers, router) without a real repository.
"""
from cryptography.fernet import Fernet, MultiFernet
from fastapi import HTTPException
from sqlalchemy import delete, text

from app import server_settings
from app.db import async_session
from app.models import ServerSetting
from app.security import key_check
from app.services import backups

_OFF_KEYS = ("offsite_backup_last_run_at", "offsite_backup_last_status")
_PLAID_TAG = "offsite-keytest-zzz"


async def _reset_offsite_settings():
    async with async_session() as s:
        await s.execute(delete(ServerSetting).where(ServerSetting.key.in_(
            ["offsite_backup_enabled", "offsite_backup_target", *_OFF_KEYS])))
        await s.commit()


class _Recorder:
    """Stand-in for backups._run that records argv + env instead of shelling out."""
    def __init__(self):
        self.calls: list[tuple[tuple[str, ...], dict | None]] = []

    async def __call__(self, *args: str, env: dict | None = None) -> None:
        self.calls.append((args, env))


async def test_offsite_defaults_and_config():
    await _reset_offsite_settings()
    async with async_session() as s:
        assert await server_settings.get(s, "offsite_backup_enabled") is False
        assert await server_settings.get(s, "offsite_backup_target") == ""
    enabled, target = await backups.offsite_config()
    assert enabled is False and target == ""


async def test_offsite_push_disabled_raises():
    await _reset_offsite_settings()
    try:
        await backups.offsite_push(label="manual")
        assert False, "expected RuntimeError when the tier is disabled"
    except RuntimeError:
        pass


async def test_offsite_push_invokes_restic_with_repo_env():
    await _reset_offsite_settings()
    async with async_session() as s:
        await server_settings.set_value(s, "offsite_backup_enabled", True)
        await server_settings.set_value(s, "offsite_backup_target", "s3:test-repo/x")
        await s.commit()
    rec = _Recorder()
    original = backups._run
    backups._run = rec
    try:
        target = await backups.offsite_push(label="manual")
        assert target == "s3:test-repo/x"
        cmds = [a[0] for a in rec.calls]
        # staged the DB dump, then restic init-probe + backup + forget
        assert ("pg_dump", "-Fc", "-d", backups.settings.libpq_dsn) == cmds[0][:4]
        restic_backup = next(a for a in rec.calls if a[0][:2] == ("restic", "backup"))
        restic_forget = next(a for a in rec.calls if a[0][:2] == ("restic", "forget"))
        # the app-set target is injected as the repo; RESTIC_PASSWORD/creds come from the inherited env
        assert restic_backup[1]["RESTIC_REPOSITORY"] == "s3:test-repo/x"
        assert restic_forget[1]["RESTIC_REPOSITORY"] == "s3:test-repo/x"
        assert "--prune" in restic_forget[0]
    finally:
        backups._run = original
        await _reset_offsite_settings()


async def test_offsite_snapshots_disabled_empty():
    await _reset_offsite_settings()
    assert await backups.offsite_snapshots() == []  # tier off → empty, no restic call


async def test_offsite_snapshots_parses_restic_json():
    await _reset_offsite_settings()
    async with async_session() as s:
        await server_settings.set_value(s, "offsite_backup_enabled", True)
        await server_settings.set_value(s, "offsite_backup_target", "s3:test-repo/x")
        await s.commit()
    captured = {}

    async def fake_out(*args, env=None):
        captured["args"], captured["env"] = args, env
        return ('[{"short_id":"abcd1234","id":"abcd1234ffff","time":"2026-06-30T12:00:00Z",'
                '"hostname":"cleave","tags":["manual"],"paths":["/tmp/x"]}]')

    original = backups._run_out
    backups._run_out = fake_out
    try:
        snaps = await backups.offsite_snapshots()
        assert len(snaps) == 1
        assert snaps[0]["id"] == "abcd1234" and snaps[0]["tags"] == ["manual"]
        assert snaps[0]["hostname"] == "cleave"
        # scoped to our host, JSON, with the app-set repo injected (creds stay in the inherited env)
        assert captured["args"][:4] == ("restic", "snapshots", "--json", "--host")
        assert captured["env"]["RESTIC_REPOSITORY"] == "s3:test-repo/x"
    finally:
        backups._run_out = original
        await _reset_offsite_settings()


async def test_offsite_snapshots_error_returns_empty():
    # A never-initialized repo / missing RESTIC_PASSWORD errors - a read-only view returns empty, not 500.
    await _reset_offsite_settings()
    async with async_session() as s:
        await server_settings.set_value(s, "offsite_backup_enabled", True)
        await server_settings.set_value(s, "offsite_backup_target", "s3:test-repo/x")
        await s.commit()

    async def boom(*args, env=None):
        raise RuntimeError("restic failed (1): unable to open repository")

    original = backups._run_out
    backups._run_out = boom
    try:
        assert await backups.offsite_snapshots() == []
    finally:
        backups._run_out = original
        await _reset_offsite_settings()


async def test_offsite_status_markers_not_in_settings_api():
    await _reset_offsite_settings()
    async with async_session() as s:
        await server_settings.set_value(s, "offsite_backup_enabled", True)
        await server_settings.set_value(s, "offsite_backup_target", "sftp:host:/b")
        await s.commit()
    try:
        await backups.record_offsite_result(True, "")
        status = await backups.offsite_status()
        assert status["enabled"] is True and status["target"] == "sftp:host:/b"
        assert status["last_status"] == "ok" and status["last_run_at"] is not None
        # the internal markers must NOT leak into the member-readable settings payload
        async with async_session() as s:
            all_settings = await server_settings.get_all(s)
        for marker in _OFF_KEYS:
            assert marker not in all_settings
    finally:
        await _reset_offsite_settings()


async def test_offsite_router_now_and_status():
    from app.routers.backups import offsite_backup_now, offsite_status
    await _reset_offsite_settings()
    # disabled -> clean 409, and the failure is recorded
    try:
        await offsite_backup_now(_="admin")
        assert False, "expected 409 when disabled"
    except HTTPException as e:
        assert e.status_code == 409
    # enabled -> runs (restic mocked) and reports ok
    async with async_session() as s:
        await server_settings.set_value(s, "offsite_backup_enabled", True)
        await server_settings.set_value(s, "offsite_backup_target", "rclone:r:/p")
        await s.commit()
    original = backups._run
    backups._run = _Recorder()
    try:
        result = await offsite_backup_now(_="admin")
        assert result.enabled is True and result.last_status == "ok"
        status = await offsite_status(_="admin")
        assert status.target == "rclone:r:/p"
    finally:
        backups._run = original
        await _reset_offsite_settings()


async def test_key_check_noop_without_key():
    original = key_check.cipher
    key_check.cipher = lambda: None
    try:
        assert await key_check.check_encryption_key_health() == (0, 0)
    finally:
        key_check.cipher = original


async def test_key_check_flags_wrong_key():
    key_a, key_b = Fernet.generate_key(), Fernet.generate_key()
    ciphertext = Fernet(key_a).encrypt(b"token-xyz").decode()  # written under key A
    async with async_session() as s:
        await s.execute(
            text("INSERT INTO plaid_items (id, plaid_item_id, access_token, created_at, updated_at) "
                 "VALUES (gen_random_uuid(), :pid, :tok, now(), now())"),
            {"pid": _PLAID_TAG, "tok": ciphertext})
        await s.commit()
    original = key_check.cipher
    try:
        # wrong key decrypts nothing -> drift (sampled includes our row; every row fails under key B)
        key_check.cipher = lambda: MultiFernet([Fernet(key_b)])
        sampled, decryptable = await key_check.check_encryption_key_health()
        assert sampled >= 1 and decryptable == 0
    finally:
        key_check.cipher = original
        async with async_session() as s:
            await s.execute(text("DELETE FROM plaid_items WHERE plaid_item_id = :pid"), {"pid": _PLAID_TAG})
            await s.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
