#!/usr/bin/env bash
# Backend test suite - the source-of-truth check (CI runs this exact script).
#
# Brings up the compose `test` profile: an ephemeral Postgres on tmpfs (`db-test`) + a second API
# (`api-test`) + the shared MinIO, migrates a clean DB, then runs the standalone module runner
# (backend/run_tests.sh). Runs from anywhere; needs Docker.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

# `api-test` bases its config on .env.dev (compose overrides DB + AUTH_REQUIRED=false on top). That file is
# gitignored, so a fresh checkout / CI runner won't have it - provision a throwaway from the template (which
# is written for dev/tests: open auth, matching MinIO creds), with a real JWT secret. Never clobber a real one.
if [ ! -f .env.dev ]; then
  echo "test-backend: .env.dev missing — generating a throwaway from .env.dev.example"
  secret="$(openssl rand -hex 32 2>/dev/null || echo devtestsecret00000000000000000000000000000000)"
  sed "s|^AUTH_JWT_SECRET=.*|AUTH_JWT_SECRET=${secret}|" .env.dev.example > .env.dev
fi
# `docker compose` parses EVERY service (incl. their env_file) even when we only run db-test/api-test, so the
# other services' env files must exist. They aren't started by the test profile, so empty placeholders suffice.
for f in .env .env.demo .env.relay; do
  [ -f "$f" ] || { echo "test-backend: creating empty $f (unused by the test profile, just satisfies parsing)"; : > "$f"; }
done

# The test-profile images are `pull_policy: never`, so make sure they're present on a clean host/runner.
docker pull postgres:16
docker pull minio/minio:latest

# Tear down ONLY the ephemeral test containers (db-test's tmpfs vanishes with it). Deliberately not
# `down -v` - that would delete the shared minio_data volume and stop a real running stack.
cleanup() { docker compose rm -sf db-test api-test >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker compose --profile test up -d --build db-test api-test
docker compose exec -T api-test alembic upgrade head
docker compose exec -T api-test sh run_tests.sh
