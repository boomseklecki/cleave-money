#!/bin/sh
# Run the full backend test suite against the current DATABASE_URL.
# Intended for the `api-test` service (clean, ephemeral DB): migrate first, then this.
#   docker compose --profile test up -d db-test api-test
#   docker compose exec -T api-test alembic upgrade head
#   docker compose exec -T api-test sh run_tests.sh
set -e
cd "$(dirname "$0")"
fail=0
total=0
# Run test_migrations_roundtrip last: its downgrade→upgrade recreates the schema, invalidating the api
# server's cached statement plans, which would 500 the next DB-backed test in the run.
ordered=""
last=""
for f in tests/test_*.py; do
    case "$f" in
        */test_migrations_roundtrip.py) last="$f" ;;
        *) ordered="$ordered $f" ;;
    esac
done
for f in $ordered $last; do
    m="tests.$(basename "$f" .py)"
    out=$(python -m "$m" 2>&1) && status=0 || status=1
    count=$(printf '%s\n' "$out" | grep -oE 'ALL PASS \([0-9]+ tests\)' | grep -oE '[0-9]+' | head -1)
    if [ "$status" -eq 0 ] && [ -n "$count" ]; then
        total=$((total + count))
        echo "ok   $m ($count)"
    else
        fail=1
        echo "FAIL $m"
        printf '%s\n' "$out" | tail -15
    fi
done
echo "TOTAL passing: $total  FAIL=$fail"
exit $fail
