#!/usr/bin/env bash
# Run every test suite before you push - the one manual command. GHA-independent: this is what CI runs,
# and what you (or a self-hoster with no GitHub Actions) run to trust the build.
#
# Relay first (fast, no services), then backend (Docker + the `test` profile). Runs both even if the
# first fails, and exits non-zero if either did.
set -uo pipefail
cd "$(dirname "$0")"
rc=0

echo "== relay =="
bash ./test-relay.sh || rc=1

echo "== backend =="
bash ./test-backend.sh || rc=1

echo
if [ "$rc" -eq 0 ]; then
  echo "ALL SUITES PASSED"
else
  echo "SOME SUITES FAILED"
fi
exit "$rc"
