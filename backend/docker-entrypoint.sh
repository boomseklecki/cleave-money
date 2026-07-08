#!/bin/sh
# Container entrypoint: bring the schema to head, then start the server.
#
# One-click app stores (Unraid/Umbrel/CasaOS/Runtipi/Helm) install a prebuilt image and expect it to be ready
# after a single action - there's no place to run `alembic upgrade head` by hand. So the server self-migrates
# on start. `alembic upgrade head` is a no-op once at head, so re-running every boot is safe and idempotent.
#
# The auto-migrate only fires for the default server command. An explicit command (e.g. the deploy's one-off
# `docker compose run --rm api alembic upgrade head`) falls through to `exec "$@"` untouched, so those paths
# keep their existing pre-`up` migration ordering and don't double-run. Opt out with RUN_MIGRATIONS=false.
set -e

if [ "${RUN_MIGRATIONS:-true}" != "false" ] && { [ "$#" -eq 0 ] || [ "$1" = "uvicorn" ]; }; then
  # compose `depends_on: service_healthy` already gates on Postgres; k8s/Helm has no such gate, so retry.
  attempts=30
  i=1
  while [ "$i" -le "$attempts" ]; do
    if alembic upgrade head; then
      break
    fi
    if [ "$i" -eq "$attempts" ]; then
      echo "entrypoint: migrations failed after ${attempts} attempts" >&2
      exit 1
    fi
    echo "entrypoint: database not ready (attempt ${i}/${attempts}), retrying in 2s..." >&2
    i=$((i + 1))
    sleep 2
  done
fi

exec "$@"
