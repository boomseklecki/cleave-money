# Deploy Cleave (prebuilt images)

This is the minimal, one-command way to run your own Cleave backend using **prebuilt images** from GHCR -
no source checkout, no build, no manual database step. It stands up Postgres + MinIO + the API on `:8000`, and
the API migrates its own schema on first boot.

> Prefer to build from source, or want the dev/demo side stacks? Use the repo-root `docker-compose.yml`
> instead. This `deploy/` stack is the trimmed distribution build and the base that the one-click store
> templates (Unraid / Umbrel / CasaOS / Runtipi / Helm) wrap.

## Quickstart

```bash
# 1. Get these two files (from the repo, or copy their contents):
#      deploy/docker-compose.yml   deploy/.env.example
cp .env.example .env

# 2. Fill in the four required secrets in .env:
openssl rand -hex 32                                                    # -> AUTH_JWT_SECRET
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"   # -> ENCRYPTION_KEYS (put inside the [])
openssl rand -hex 20                                                    # -> POSTGRES_PASSWORD
openssl rand -hex 20                                                    # -> MINIO_SECRET_KEY

# 3. Start it. Migrations run automatically before the API serves.
docker compose up -d
```

The API is now at `http://localhost:8000` (health at `/health`, interactive docs at `/docs`). The **first
person to sign in claims the server** as admin; everyone after needs a single-use invite you generate in-app
(Settings -> Invite).

Open the iOS app, point it at your server's URL, and sign in.

## Expose it (TLS)

The API speaks plain HTTP on `:8000` and expects **you** to put TLS in front of it - the iOS app talks to your
public HTTPS hostname, never to `:8000` directly. Any of these work:

- A reverse proxy you already run (Caddy, nginx, Traefik) terminating TLS and proxying to `localhost:8000`.
- A Cloudflare Tunnel or Tailscale (with Funnel for public access).

Set `ALLOWED_HOSTS` in `.env` to the hostname(s) you serve on. Full runbook: [`../docs/OPERATIONS.md`](../docs/OPERATIONS.md).

## What persists

Two named Docker volumes hold everything: `cleave_db_data` (Postgres - accounts, transactions, goals, auth)
and `cleave_minio_data` (receipt objects + local backups). They survive `docker compose down`; only
`docker compose down -v` deletes them.

## Notes

- **Image tag:** the compose pins `ghcr.io/boomseklecki/cleave-api:latest`. For a reproducible deploy, pin an
  explicit release tag instead (e.g. `:1.0.0`) and bump it when you want to upgrade.
- **Upgrades:** `docker compose pull && docker compose up -d`. The new container migrates the schema on start.
- **RUN_MIGRATIONS:** defaults to `true` (the API runs `alembic upgrade head` before serving). Set it to
  `false` in the compose `environment:` if you'd rather run migrations yourself
  (`docker compose run --rm api alembic upgrade head`).
- **MinIO** is internal-only (no published ports); the API streams receipt bytes itself. Publish `9001`
  temporarily if you need the console.
- **Push notifications** are optional and go through the shared relay - set `PUSH_RELAY_API_KEY` +
  `PUSH_RELAY_URL` in `.env`. Running your own relay needs an Apple `.p8` and is out of scope for this stack.
