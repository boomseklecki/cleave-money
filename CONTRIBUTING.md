# Contributing to Cleave

Thanks for your interest in Cleave. It is a self-hosted personal-finance and expense-splitting
project: a FastAPI + Postgres + MinIO backend (`backend/`), a SwiftUI iOS app (`ios/`), and a small
standalone push relay (`relay/`). Contributions of all kinds are welcome: bug reports, documentation,
and code.

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug or request a feature** by opening an issue. Include your setup (self-hosted from
  source, the prebuilt `deploy/` stack, or the demo), what you expected, and what happened. For the
  backend, redact any secrets and real financial data from logs.
- **Improve the docs.** The READMEs, `docs/`, and `deploy/` are all fair game.
- **Send a pull request.** Small, focused PRs are easier to review than large ones. If a change is
  big or changes behavior, please open an issue first so we can agree on the approach.

## Licensing and the DCO

Cleave is licensed under **AGPL-3.0** (see [LICENSE](LICENSE)); contributions are accepted under the
same license.

We use the **Developer Certificate of Origin** (DCO): a lightweight statement that you wrote the
change, or otherwise have the right to submit it under the project license. Read the full text at
<https://developercertificate.org>. You certify it by signing off each commit:

```bash
git commit -s -m "Your message"
```

This appends a `Signed-off-by: Your Name <you@example.com>` line using your git `user.name` and
`user.email`. Every commit in a pull request must be signed off. To sign off commits you already made,
use `git rebase --signoff` (or `git commit --amend -s` for the last one).

## Development setup

### Backend (Python 3.12+, Docker)

The backend and its Postgres + MinIO dependencies run under Docker Compose. From `backend/`:

```bash
cp ../.env.example ../.env          # fill in the required secrets (see backend/README.md)
docker compose up -d db minio api   # migrations auto-run on the api container's first boot
```

The API is Python 3.12+, formatted and linted with [ruff](https://docs.astral.sh/ruff/) (line length
100). Run `ruff check .` and `ruff format .` before you commit.

Database schema changes go through Alembic. The existing history is collapsed into a single
`backend/migrations/versions/0001_squashed.py` baseline that runs automatically on boot; add a new
revision for your change with `alembic revision --autogenerate -m "short description"` and review the
generated file by hand (autogenerate misses partial indexes and enum details).

### Relay (Python 3.12+)

The push relay is a self-contained project under `relay/` with its own `Dockerfile`, `pyproject.toml`,
and tests. It needs no Apple credentials to run in a disabled state. See `relay/README.md`.

### iOS (macOS + Xcode 26)

The iOS app builds on macOS only. The Xcode project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from `ios/project.yml` (the `.xcodeproj` is not
committed):

```bash
brew install xcodegen
cd ios && xcodegen generate
open Cleave.xcodeproj
```

Change `DEVELOPMENT_TEAM` in `project.yml` to your own for device builds; the simulator needs no
signing. Re-run `xcodegen generate` whenever you add or move source files. After changing the backend
API contract, refresh `ios/openapi.json` and re-run
`python3 ios/scripts/prepare_openapi.py ios/openapi.json ios/CleaveAPI/Sources/CleaveAPI/openapi.json`
to regenerate the transformed copy the API client is built from.

## Running the tests

From the repository root:

```bash
bash scripts/test-all.sh        # backend + relay
bash scripts/test-backend.sh    # backend only (spins up an ephemeral Postgres)
bash scripts/test-relay.sh      # relay only
```

The backend and relay suites must pass before a PR is merged. iOS changes should build and pass the
app's test target locally (that runs on your Mac, not in CI).

## Pull request checklist

1. Branch off `main`.
2. Keep the change focused; update docs and tests alongside code.
3. `ruff check` / `ruff format` clean for Python; the relevant test script green.
4. Every commit is signed off (`git commit -s`).
5. Write a clear PR description: what changed, why, and how you tested it.

Maintainers review PRs as time allows. Thanks for helping make Cleave better.
