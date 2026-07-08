# Testing

**The local scripts are the source of truth.** CI (GitHub Actions) runs the *same* scripts - it's a
convenience mirror, not a gatekeeper. If Actions is flaky, degraded, or you self-host without it, run the
scripts locally and trust them.

## Run everything

```bash
bash scripts/test-all.sh
```

Runs the relay suite (fast, no services) then the backend suite (Docker), and exits non-zero if either
fails. Run it before you push.

## The two suites

They're independent - different tooling, different needs, no shared code - so they're separate scripts and
separate CI workflows.

### Backend - `bash scripts/test-backend.sh`
Needs **Docker**. Brings up the compose `test` profile (ephemeral Postgres on `tmpfs` + a second API
`api-test` + the shared MinIO), migrates a clean DB, then runs the standalone module runner. It:

1. `docker pull postgres:16 minio/minio:latest` - these images are `pull_policy: never` in
   `docker-compose.yml`, so a clean host/runner must have them present. **This is the #1 gotcha.**
2. `docker compose --profile test up -d --build db-test api-test`
3. `docker compose exec -T api-test alembic upgrade head`
4. `docker compose exec -T api-test sh run_tests.sh` - runs every `backend/tests/test_*.py`.

Teardown removes only the ephemeral `db-test`/`api-test` containers (the `tmpfs` DB vanishes with them);
it deliberately does **not** `down -v`, which would delete the shared `minio_data` volume and stop a real
running stack.

There's no pytest in the backend image - each test is a standalone module. For a fast single-module
iteration loop while the stack is up:

```bash
docker compose exec -T api-test python -m tests.test_server_info
```

`run_tests.sh` runs `test_migrations_roundtrip.py` last (its downgrade→upgrade invalidates cached
statement plans, which would 500 later DB tests).

### Relay - `bash scripts/test-relay.sh`
Needs only **Python 3.12**. The relay is fully standalone: 8 pytest tests with a temp SQLite DB per test
and APNs mocked - no Postgres, no MinIO, no secrets, no network. The script prefers `uv run pytest`
(isolated env with dev-deps) and falls back to a throwaway pip venv when `uv` isn't installed.

## CI is a mirror, not a gate

- `.github/workflows/backend-ci.yml` runs `scripts/test-backend.sh`; triggers only on `backend/**`
  (or `docker-compose.yml`) changes.
- `.github/workflows/relay-ci.yml` runs `scripts/test-relay.sh`; triggers only on `relay/**` changes.

Both are **path-filtered** (a backend change never runs relay CI, and vice-versa) and **advisory** - not
required merge checks. GitHub Actions can be unreliable, so it is never the thing that blocks a ship: the
authoritative check is `scripts/test-all.sh` locally (or on the deploy host). Only turn on branch
protection requiring these checks once they've proven stable in this repo.

Neither workflow needs secrets (relay mocks APNs; the backend `test` profile sets `AUTH_REQUIRED=false`),
so there's no secret-availability flakiness. Both have `timeout-minutes` (fail fast on a hung runner) and
`concurrency: cancel-in-progress` (no pile-ups).

> Reproducibility note: `uv.lock` is gitignored, so backend deps resolve fresh per build. If CI install
> flakiness ever bites, committing a lockfile for deterministic installs is the fix.
