#!/usr/bin/env bash
# Relay test suite - the source-of-truth check (CI runs this exact script).
#
# The relay is fully standalone: 8 pytest tests, temp SQLite per test, APNs mocked - no external
# services, no secrets, no env. Prefers uv (isolated env with dev-deps); falls back to a throwaway venv.
set -euo pipefail
cd "$(dirname "$0")/../relay"

if command -v uv >/dev/null 2>&1; then
  # uv run provisions runtime + [tool.uv] dev-dependencies (pytest) in an isolated env and runs.
  uv run --quiet pytest -q
else
  # pip fallback: a throwaway venv so we never touch the system Python.
  venv="$(mktemp -d)"
  trap 'rm -rf "$venv"' EXIT
  python3 -m venv "$venv"
  # shellcheck disable=SC1091
  . "$venv/bin/activate"
  pip install --quiet -e . pytest pytest-asyncio
  pytest -q
fi
