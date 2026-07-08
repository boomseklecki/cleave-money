# Operations

Running the shared and optional pieces of Cleave that sit outside the core single-instance path: exposing
your backend to the internet, the **push relay**, the **public demo** stack, and **backup / disaster
recovery**. Everything here is written generically - substitute your own hostnames and paths.

- [Server settings reference](#server-settings-reference)
- [Public / remote access](#public--remote-access)
- [Sharing the app (join link)](#sharing-the-app-join-link)
- [Push relay](#push-relay)
- [Demo / public instance](#demo--public-instance)
- [Backups & disaster recovery](#backups--disaster-recovery)

---

## Server settings reference

Everything here is edited **in-app** (Settings → Server Settings, admin only) and stored in the
`server_settings` table - **no restart or redeploy**. Values seed from sensible defaults on first migration.

| Setting | Default | What it does |
| --- | --- | --- |
| `public_hostname` | - | Friendly instance name/label shown to clients. |
| `default_currency` | USD | ISO code new expenses/accounts/goals default to when the client doesn't specify one. |
| `invites_open_to_members` | false | Let enrolled members (not just admins) mint invites. |
| `sync_interval_hours` | - | Background Plaid/Splitwise full-sync cadence (`0` = paused). |
| `backup_interval_hours` | - | Local backup cadence (`0` = paused). |
| `backups_retention_days` | 30 | Keep local backups for N days... |
| `backups_retention_min_keep` | 7 | ...but always keep at least N (manual backups are never pruned). |
| `refresh_plaid_stale_minutes` | 60 | Pull-to-refresh only calls Plaid if data is older than this; otherwise it just reconciles the cache. |
| `refresh_splitwise_stale_minutes` | 15 | Same, for Splitwise. |
| `notifications_poll_minutes` | 0 | Optional fast, notifications-only poll (`0` = off) - see below. |
| `notifications_retention_count` | 100 | Prune the activity/notification feed to the most recent N. |
| `push_enabled` | true | Master on/off for device push (relay creds stay in `.env`); shown in-app only on a non-demo server with a relay configured. |
| `budget_push_enabled` | false | Push a spend-goal owner once when a budget crosses ~85% (nearing) / 100% (over). |
| `splitwise_receipt_download_enabled` | - | Allow downloading a receipt for a single Splitwise expense. |
| `splitwise_receipt_backfill_enabled` | - | Enable the bulk "download all" + scheduled receipt backfill from Splitwise. |
| `groups_/expenses_hard_delete_enabled` | false | Whether Delete hard-deletes (and propagates) vs. is blocked. |
| `offsite_backup_enabled` / `offsite_backup_target` | false / - | The off-device restic tier + its repository string (see [Backups](#backups--disaster-recovery)). |

**Smart pull-to-refresh.** The two `refresh_*_stale_minutes` thresholds make a pull-to-refresh cheap when data
is fresh: it reconciles the local cache and only calls Plaid/Splitwise when the data is actually stale.

**Near-real-time Splitwise.** Setting `notifications_poll_minutes` runs a lightweight notifications-only poll
between full syncs, so a partner's Splitwise activity appears (and pushes) promptly without paying for a full
sync each time.

---

## Public / remote access

To reach the backend from outside your LAN (so the iOS app works anywhere), pick one of the built-in
connectors - a **Cloudflare Tunnel** (public HTTPS) or **Tailscale** (your private tailnet). Both are
Compose-only side profiles; the API never reads their config. Any external reverse proxy (nginx, Caddy, ...)
works too. Whatever hostname you land on is what you set as the app's server URL (Settings → Backend).

### Cloudflare Tunnel - remotely-managed (default)

Everything is managed from the Cloudflare dashboard; the connector only carries a token.

1. Cloudflare **Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared** → name it → copy the
   connector token.
2. Add a **public hostname** for each stack you run (Cloudflare auto-creates DNS). The service is the compose
   service name on its container port `:8000` - the connector shares the stacks' network:
   - `your-host.example.com` → `http://api:8000` (the default/real instance)
   - `dev.your-host.example.com` → `http://api-dev:8000` (`--profile dev` sandbox)
   - `demo.your-host.example.com` → `http://api-demo:8000` (`--profile demo`)
   - `push.your-host.example.com` → `http://relay:8000` (the push relay)
3. Put the token in `.env`: `CLOUDFLARE_TUNNEL_TOKEN=<token>`.
4. Start the connector: `docker compose --profile tunnel up -d cloudflared`.

### Cloudflare Tunnel - locally-managed (advanced)

Prefer to manage ingress yourself (custom path routing, extra services, no dashboard)? Copy
`cloudflared/config.yml.example` → `cloudflared/config.yml` and drop the tunnel's credentials JSON alongside
it as `cloudflared/credentials.json`. The connector **auto-detects** that file and switches to it - no token,
no compose edit. One-time setup (cloudflared on your machine, or `docker run cloudflare/cloudflared`):
`cloudflared tunnel login` → `tunnel create cleave` (prints the UUID + credentials JSON) →
`tunnel route dns cleave your-host.example.com`. Fill in the UUID + `ingress:` hostnames in `config.yml`, then
`docker compose --profile tunnel up -d --build cloudflared`. (`config.yml` + `credentials.json` are gitignored.)

### Tailscale (tailnet-private, or public via Funnel)

Instead of a public tunnel, join the backend to your **tailnet** and reach it from your own devices - no public
exposure. Install Tailscale on your phone and point the app at the node's HTTPS name.

1. Generate a **tailnet auth key** (Tailscale admin console → Settings → Keys; reusable + tagged is handy).
2. Put it in `.env`: `TS_AUTHKEY=<key>` (optionally `TS_HOSTNAME=cleave`, `TS_EXTRA_ARGS=--advertise-tags=tag:cleave`).
3. Copy `tailscale/serve.json.example` → `tailscale/serve.json` (it proxies the node's `:443` → `http://api:8000`;
   change the target to `api-demo:8000` etc. for other stacks).
4. Start it: `docker compose --profile tailscale up -d tailscale`.
5. Reach the backend at `https://${TS_HOSTNAME}.<your-tailnet>.ts.net` from any device on the tailnet - set
   that as the app's server URL.

**Public exposure (Funnel):** `serve.json` ships with an `AllowFunnel` entry set to `false` (tailnet-private).
To serve it to the open internet like the Cloudflare tunnel, **flip that one line to `true`** and enable
Funnel for the node in your tailnet ACLs / admin console. Funnel only supports the standard ports
(443/8443/10000).

## Sharing the app (join link)

The **backend serves the onboarding site itself** - no separate static host. Share one link:

```
https://your-host.example.com/join                          # endpoint defaults to this host
https://your-host.example.com/join?name=Your%20Household    # optional friendlier label
```

The backend serves, all unguarded:

- `GET /join` - an install button (TestFlight / App Store), an invite **QR** (encodes
  `cleave://join?api=...`) for the app's "Scan invite", and the server URL as copyable text. `?api=` overrides
  the endpoint (defaults to the serving host); `?name=` sets the label.
- `GET /.well-known/apple-app-site-association` - the Universal-Link association, served as
  `application/json`, generated from `APPLE_TEAM_ID` + `APPLE_AUDIENCE` (appID = `<team>.<bundle>`). Returns
  404 until `APPLE_TEAM_ID` is set. With the app installed, tapping the link opens it and pre-fills the
  endpoint; otherwise the page guides installation.
- `GET /server-info` (`{app, version, name, requires_auth, auth_providers}`) - pinged by the app to verify a
  URL is a real Cleave server before adopting it.

The iOS app's `applinks:` associated domain must match your public hostname. After exposing the backend, verify
the AASA:

```bash
curl -I https://your-host.example.com/.well-known/apple-app-site-association
# expect: content-type: application/json over HTTPS, no redirect (set APPLE_TEAM_ID first)
```

## Push relay

Push notifications go through a **standalone relay** (`relay/`) rather than the backend, so the open-source
server never holds Apple credentials.

- **What it is.** The relay holds the official APNs `.p8` key and forwards notifications for one or more
  backends. A backend points at it with `PUSH_RELAY_URL` + `PUSH_RELAY_API_KEY` (empty = push disabled).
- **Run your own.** `docker compose up -d relay` (or move it to a separate host and point each backend's
  `PUSH_RELAY_URL` at it). It reads `.env.relay` (`APNS_*` + an admin token); self-hosters register for an
  instance key via the relay's self-serve form.
- **Manage the keys.** With `ADMIN_TOKEN` set, the relay serves a web UI at `/admin` (published port `8003`
  locally, or the `push.<host>` tunnel route) to list every issued key with its usage and approve / revoke /
  reactivate / issue / delete. It's HTTP Basic-auth protected - log in with `ADMIN_USER` (default `admin`) and
  `ADMIN_TOKEN` as the password.
- **Relay-blind by design (E2E).** Push content is end-to-end encrypted: the backend seals the real title/body
  to each device's P-256 key (ECIES), and the relay only ever forwards ciphertext plus a generic "New activity"
  alert. There is no plaintext fallback - a device with no published key is skipped, never downgraded - so the
  relay can never see notification content.

The relay is fully separable and has its own test suite (`bash scripts/test-relay.sh`); it shares no code with
the backend.

## Demo / public instance

A public, disposable **demo** backend lets anyone try the app with sample data before linking real accounts -
hand it to a friend, or run it as a TestFlight tester backend.

```bash
cp .env.demo.example .env.demo     # fill: sandbox Plaid creds, a FRESH AUTH_JWT_SECRET (DEMO_MODE=true preset)
docker compose --profile demo up -d
docker compose exec api-demo alembic upgrade head
```

- It runs **guest login** (`DEMO_MODE` → `POST /auth/demo`, name only, no OAuth): each guest gets an isolated,
  auto-seeded sample app; Plaid is **sandbox**; there is no Splitwise.
- Put it behind a public hostname (`demo.your-host.example.com → http://api-demo:8000`, via the tunnel above or
  any reverse proxy).
- **Share it:** send a friend `https://demo.your-host.example.com/demo`. That page offers "Get the app" and
  "Open in Cleave" - the app adopts your demo server (via the `cleave://` scheme) and its sign-in screen
  shows a **Start Demo** button (OAuth hidden). `/demo` and `POST /auth/demo` exist only when `DEMO_MODE=true`,
  so your prod/dev stacks never expose them.
- Guests are auto-pruned hourly (24h retention) when `DEMO_MODE` is on; prune manually with
  `docker compose exec api-demo python -m app.cli.prune_demo --days 7`.

## Backups & disaster recovery

Admin-only, managed in-app (Settings → Backups / Server Settings). A backup - local or off-device - is a full
snapshot: a Postgres custom-format dump (`database.dump`) **plus every receipt object**.

### The two secrets you must escrow off-host

A backup deliberately does **not** contain `ENCRYPTION_KEYS`. Only `plaid_items.access_token` and
`splitwise_tokens.access_token` are encrypted at rest (Fernet, keyed by `ENCRYPTION_KEYS`); the dump holds the
**ciphertext**, never the key. Store both of these somewhere you'll still have after losing the host:

| Secret | Lives in | If lost |
| --- | --- | --- |
| `ENCRYPTION_KEYS` | `.env` | All non-token data restores, but Plaid/Splitwise tokens are **permanently undecryptable** - every user must re-link banks and re-authorize Splitwise. |
| `RESTIC_PASSWORD` | `.env` | The **off-device restic repo cannot be opened at all**. (The local backup bucket is unaffected.) |

The API warns at startup if it comes up with a DB whose tokens don't match the configured `ENCRYPTION_KEYS`
(i.e. you restored without the right key).

### Local tier

A `pg_dump -Fc` of the whole DB plus every receipt object, packed into one `tar.gz` in the `BACKUPS_BUCKET`
MinIO bucket, on an admin-set cadence with retention (keep-days + always-keep-newest). Manual backups are never
auto-pruned. Restore via the admin API/app: `POST /backups/{name}/restore` takes a safety backup first, then
`pg_restore --clean --single-transaction` and re-uploads receipts. Ensure `.env` has the **original**
`ENCRYPTION_KEYS` before restoring.

### Off-device tier (restic)

A second, **encrypted, off-host** copy via [restic](https://restic.net), pushed after each local backup with
the same retention. The repository target (`offsite_backup_target`) is a Server Setting; its secrets
(`RESTIC_PASSWORD`, plus any `AWS_*` / `RCLONE_*`) live only in `.env`. restic supports many transports - set
the target to `s3:...`, `sftp:...`, or `rclone:...` for anything rclone can reach.

Enable it in **Settings → Server Settings → Off-device backup** (toggle + target string); the operator must set
`RESTIC_PASSWORD` (and any cloud creds) in server `.env` first - the app never collects secrets.

**Health checks:** the admin app shows the last run + `ok`/`error`; `GET /backups/offsite` returns
`{enabled, target, last_run_at, last_status}`; `POST /backups/offsite` runs one now; `restic check` (inside the
`api` container) verifies repo integrity.

### Full rebuild from the off-device repo (host lost)

1. Stand up the stack (Postgres + MinIO + api) and put the **original** `ENCRYPTION_KEYS`, the
   `RESTIC_PASSWORD`, and any remote credentials into `.env`. Set the same `offsite_backup_target`.
2. Pull the latest snapshot (run inside the `api` container, which ships `restic`):
   ```sh
   export RESTIC_REPOSITORY="<your offsite_backup_target>"
   restic snapshots
   restic restore latest --target /tmp/dr     # yields /tmp/dr/.../database.dump + receipts/
   ```
3. Restore the database from the recovered dump:
   ```sh
   pg_restore --clean --if-exists --no-owner --single-transaction -d "<libpq DSN>" /tmp/dr/.../database.dump
   ```
4. Re-upload the recovered `receipts/` tree into the receipts bucket.
5. `alembic upgrade head` (no-op if the dump is already at head); start the api and confirm there's no
   `ENCRYPTION_KEYS` drift warning in the logs.

### Setting up an `sftp:` target (SSH-key auth)

restic's `sftp:` backend backs up over SSH with key auth (no password). The `api` service mounts
`./secrets/ssh` (gitignored) read-only at `/root/.ssh`. On the host, in the compose project dir:

```sh
mkdir -p secrets/ssh && chmod 700 secrets/ssh
ssh-keygen -t ed25519 -N '' -C splitback-backup -f secrets/ssh/id_ed25519
ssh-keyscan -p <port> <backup-host> > secrets/ssh/known_hosts        # then VERIFY the fingerprint
cat > secrets/ssh/config <<'EOF'
Host backup
  HostName <backup-host-or-ip>
  User <backup-user>
  Port <port>
  IdentityFile /root/.ssh/id_ed25519    # in-CONTAINER path
  IdentitiesOnly yes
EOF
chown -R 0:0 secrets/ssh    # OpenSSH refuses a key not owned by the running user (the container runs as root)
```

Add `id_ed25519.pub` to the backup account's `authorized_keys`, set `RESTIC_PASSWORD` in `.env`, rebuild the
`api` image, and set the target (e.g. `sftp:backup:/splitback-backup`) in Server Settings. The first push runs
`restic init` automatically. NAS/appliance SFTP servers often have their own permission and chroot quirks -
consult your device's documentation.
