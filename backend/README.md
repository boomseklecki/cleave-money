# Cleave - Backend

**Self-hosted personal finance + expense splitting. Own your money data.**

Cleave is a self-hosted backend that pulls your bank and credit-card activity into one
place, splits shared expenses with friends, and keeps your Splitwise history in sync - all
on infrastructure you control. It is the server half of the Cleave iOS app: a single
Postgres + object-store stack you run behind your own tunnel, with no third party sitting
between you and your financial data. The app reaches it over HTTPS at a stable hostname - 
public via a Cloudflare Tunnel or Tailscale Funnel, or tailnet-private via Tailscale
`serve` - while the raw database and storage ports never leave the internal network.

<p>
  <img alt="License: AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-blue">
  <img alt="Python 3.12+" src="https://img.shields.io/badge/python-3.12%2B-blue">
  <img alt="FastAPI" src="https://img.shields.io/badge/FastAPI-async-009688">
  <img alt="Status: early" src="https://img.shields.io/badge/status-v0.1.0%20(early)-orange">
</p>

> **Status:** early and evolving (v0.1.0). Cleave is a working, tested, self-hosted stack
> that one household runs in production, but it is not yet a turnkey "one-click deploy" for
> strangers. Expect to read a config file and set up a tunnel. Feedback and issues welcome.

---

## Table of contents

- [Why Cleave](#why-cleave)
- [Feature highlights](#feature-highlights)
- [How it fits together](#how-it-fits-together)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Connecting your money](#connecting-your-money)
- [Multi-user: invites &amp; partner sharing](#multi-user-invites--partner-sharing)
- [Security &amp; privacy](#security--privacy)
- [Backups &amp; disaster recovery](#backups--disaster-recovery)
- [Operating in production](#operating-in-production)
- [Development](#development)
- [Testing](#testing)
- [Project layout](#project-layout)
- [API](#api)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## Why Cleave

Most money apps are a trade: you get a nice UI, they get a permanent copy of every
transaction you make. Splitwise paywalls basic features; Mint shut down; the aggregators
sell insight into your spending. Cleave takes the other side of that trade.

- **Your data lives on your box.** Postgres and an S3-compatible object store you run.
  No Cleave cloud, no analytics pipeline, no account to close.
- **And you can take it out again.** One-click export of everything - expenses, transactions,
  accounts, balances, and groups as CSV/JSON, transactions as re-importable OFX, or a single
  ZIP archive with your receipt files included. No lock-in, by construction.
- **Bring your history with you.** First-class, two-way Splitwise sync - and a one-way door
  to *leave* Splitwise entirely, cloning a group (expenses, splits, receipts) into a
  native self-hosted group you own.
- **One ledger for shared and personal.** The same backend that splits a dinner four ways
  also tracks your checking account, categorizes your card spend, and warns you when a
  monthly budget is running hot.
- **Credentials never leave the server.** Bank tokens are encrypted at rest; the open-source
  server holds no Apple push keys; merchant logos are proxied so a merchant list never
  reveals itself to a third party.
- **AGPL-3.0.** Copyleft, so a hosted fork stays open too.

## Feature highlights

### Bring your accounts

- **Live bank sync via [Plaid](https://plaid.com)** - link an institution and transactions,
  balances, and branding flow in continuously, categorized to match the app.
- **[SimpleFIN](https://www.simplefin.org/) bridge** - a cheaper, read-only, credential-light
  aggregator alternative to Plaid. Paste one setup token; no server-side app keys required.
- **OFX statement import** - for accounts no aggregator can reach (the motivating case:
  **Apple Card**, which only exports a monthly Wallet `.ofx`). A dependency-free, tolerant
  parser handles SGML and XML OFX, multi-account files, and European decimals.
- **Cross-source account merge** - connected the same card through two feeds? Fold them into
  one account with a clean cutover date instead of duplicate rows.

### Split expenses

- **Groups &amp; splits** with per-person paid/owed shares, validated to balance to the cent.
- **Two-way Splitwise sync** - import your whole history, keep edits/settle-ups/deletions
  live in both directions, and push locally-created expenses back to Splitwise.
- **"Cut the cord"** - clone a Splitwise group into a native self-hosted group (receipts and
  all), marking the source superseded so balances never double-count.
- **Itemized line items** and **per-user overrides** - two members can categorize the same
  shared expense differently for their own analytics without touching the shared record or
  anyone's balance.
- **Balances &amp; friends** - who-owes-whom, per group and as Splitwise-style pairwise nets,
  using Splitwise's authoritative ledger when connected and a pure server-side computation
  otherwise.

### Understand your spending

- **Server/app parity categorization** - a 25-category canonical taxonomy plus a resolver
  that reproduces the iOS app's exact precedence chain (your overrides → learned map →
  Plaid taxonomy → refined → raw), guarded by parity asserts so on-server numbers match the
  screen.
- **Budgets &amp; goals** - Mint-style monthly category budgets ("spend" goals) and
  balance-growth targets ("save" goals), with optional read-only sharing to a partner.
- **Budget push alerts** - a post-sync engine notifies you at 85% and 100% of a budget,
  once per month per threshold, even with the app closed - including combined household
  spend across a shared group.
- **Full data export** - download expenses, splits, transactions, accounts, balances, and
  groups as CSV or JSON, transactions as re-importable OFX, or grab a single ZIP with every
  receipt file bundled in. The archive streams to disk, so even a receipt-heavy export never
  has to fit in memory.

### Own the plumbing

- **Sign in with Apple / Google / Splitwise**, verified server-side, exchanged for one
  stateless backend JWT.
- **Invite-only by default** - registration is closed; the first person to claim a fresh
  server becomes admin, everyone else needs a single-use invite.
- **Optional, end-to-end-encrypted push** through a standalone blind relay you register your
  backend with - it forwards to Apple but only ever sees ciphertext.
- **Full-stack backups** - Postgres dump + every receipt object in one archive, with an
  optional encrypted off-device tier (restic over SFTP/S3/rclone) and a documented restore.
- **Admin-editable runtime settings** - change sync cadence, retention, invite policy, and
  provider toggles from the app without a redeploy.

## How it fits together

Cleave is an async **FastAPI** service backed by **Postgres 16** for relational data and
**MinIO** (S3-compatible) for receipt/avatar/logo objects. Optional push runs through a
separate, blind **push relay** that forwards notifications to Apple. Everything is orchestrated
with Docker Compose and reached over a Cloudflare Tunnel or Tailscale - the iOS app talks to
a stable HTTPS hostname (public via Cloudflare Tunnel or Tailscale Funnel, or tailnet-private
via Tailscale `serve`), never a raw port.

```
                         ┌─────────────────────────────┐
   iOS app  ── HTTPS ──▶ │  Cloudflare Tunnel / Tailscale │
                         └──────────────┬──────────────┘
                                        ▼
   ┌───────────────────────────── api (FastAPI) ─────────────────────────────┐
   │  auth · expenses · accounts · transactions · balances · goals ·         │
   │  categories · receipts · notifications · backups · server-settings      │
   │                                                                         │
   │  background loops:  sync · backups · notifications · demo-prune         │
   └───────┬───────────────────┬───────────────────┬──────────────┬─────────┘
           ▼                   ▼                   ▼              ▼
     Postgres 16            MinIO           push relay ──▶ APNs   external APIs
     (relational)        (objects: receipts,  (blind relay)       (Plaid, SimpleFIN,
                          avatars, logos,                          Splitwise, logos)
                          backups)

   Tech: Python 3.12 · SQLAlchemy 2.0 async · asyncpg · Pydantic v2 · Alembic · uv
```

**Design principles you'll see throughout the code**

- **Default-open, then it bites.** Every auth and scoping check is a no-op when there is no
  caller, so dev and tests run unguarded; enforcement engages only once you set
  `AUTH_REQUIRED`, `API_TOKENS`, or `ADMIN_USERS`.
- **Per-user overrides never clobbered by sync.** Shared/sourced data lives on a base table;
  each user's toggles live in a sibling `*_overrides` table, so a re-sync that rewrites base
  columns can't wipe your personal categorization.
- **Push-first, idempotent writes.** Outbound Splitwise pushes happen before the local
  commit (no lock held across a slow HTTP call), and create endpoints honor an
  `Idempotency-Key` so a retried request on a flaky network collapses to one row.
- **Server ⟷ app parity is a discipline.** Category maps and the spend engine mirror the
  Swift enums verbatim, asserted at import and covered by parity tests.

## Quick start

> **Just want it running?** Skip the source build: the [`deploy/`](../deploy) stack pulls the
> **prebuilt image** `ghcr.io/boomseklecki/cleave-api` (Postgres + MinIO + API, self-migrating) with
> `docker compose up -d` and no checkout - it's also the base the one-click store templates
> (**Unraid / Umbrel / CasaOS / Runtipi / Helm**) wrap. See [`deploy/README.md`](../deploy/README.md).
> Build from source (below) when you want the dev/demo/test stacks or to hack on the code.

**Prerequisites:** Docker + Docker Compose, plus a way for your phone to reach the backend
(for anything beyond a local poke) - either:

- a [**Cloudflare Tunnel**](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) - 
  needs a domain you control, gives you a public HTTPS hostname; or
- [**Tailscale**](https://tailscale.com/) - **no domain required**: you get a free
  `<host>.<tailnet>.ts.net` HTTPS hostname, your devices just join your tailnet
  (tailnet-private), and Tailscale Funnel makes it public if you ever want that.

```bash
# 1. Clone and enter the repo
git clone https://github.com/boomseklecki/cleave-money.git && cd cleave-money

# 2. Create your config from the template and fill in secrets
cp .env.example .env
#    At minimum, review: AUTH_JWT_SECRET, ENCRYPTION_KEYS, ADMIN_USERS,
#    and provider creds for whichever of Apple/Google/Splitwise/Plaid you'll use.

# 3. Bring up the core stack (Postgres, API, MinIO)
#    The API self-migrates on start (runs `alembic upgrade head`), so it's ready after this
#    one step - no manual migration. Opt out with RUN_MIGRATIONS=false to migrate by hand.
docker compose up -d db api minio

# 4. Verify it's alive
docker compose exec api curl -s localhost:8000/health         # -> {"status":"ok"}
docker compose exec api curl -s localhost:8000/server-info    # capability discovery
```

Interactive API docs are served by FastAPI at `/docs` (OpenAPI) and `/redoc`.

> **Generate the two secrets you must not lose:**
> ```bash
> openssl rand -hex 32                                                   # AUTH_JWT_SECRET
> python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"  # ENCRYPTION_KEYS entry
> ```
> These two are the minimum. For **every** key/secret/token - with a copy-paste block to generate
> the random ones and a note on where each provider value comes from - see
> [Configuration → Generate your secrets](#generate-your-secrets) and the
> [full variable reference](#full-variable-reference). [Security &amp; privacy](#security--privacy)
> explains what each protects; [`docs/DISASTER_RECOVERY.md`](docs/DISASTER_RECOVERY.md) covers escrow.

## Configuration

Configuration splits in two, by design:

| Kind | Where | Examples | Change requires |
| --- | --- | --- | --- |
| **Secrets &amp; deploy topology** | `.env` (see `.env.example`) | DB URL, provider keys, encryption keys, allowed hosts | redeploy |
| **Runtime policy** | `server_settings` table (admin UI / `PATCH /server-settings`) | sync cadence, retention, invite policy, provider on/off toggles | live, no redeploy |

All real `.env*` files are gitignored - secrets stay server-side and the iOS app never sees them.

### Which template do I copy?

There are three backend stacks, each with its own template. Most self-hosters only need the first.

| Copy | To | For | Notable differences |
| --- | --- | --- | --- |
| `.env.example` | `.env` | **The real instance** (`docker compose up`) | Production Plaid; `AUTH_REQUIRED=true` |
| `.env.dev.example` | `.env.dev` | Optional sandbox (`--profile dev`) | Sandbox Plaid, synthetic seed, open auth |
| `.env.demo.example` | `.env.demo` | Optional public demo (`--profile demo`) | `DEMO_MODE=true`, sandbox Plaid, no Splitwise |

Each stack **must have its own fresh `AUTH_JWT_SECRET`** (and its own DB volume) so a token minted
on one can't authenticate against another. The push relay has a **separate** template,
`.env.relay.example` → `.env.relay` (see [Push relay secrets](#push-relay-secrets-envrelay) below).

### Generate your secrets

Everything you generate yourself, sized for its slot. Run these and paste each into the matching
key. macOS/Linux ship `openssl`; the Fernet line needs the Python `cryptography` package (or run it
inside the container: `docker compose exec api python -c '...'`).

```bash
# AUTH_JWT_SECRET - HS256 session-signing secret (min 32 chars; this yields 64). Fresh per stack.
openssl rand -hex 32

# ENCRYPTION_KEYS - Fernet key encrypting bank tokens at rest. Wrap the output in a JSON list: ["<key>"]
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"

# POSTGRES_PASSWORD - Postgres password (compose reads it; the 'cleave' default is dev-only)
openssl rand -hex 24

# MINIO_ACCESS_KEY / MINIO_SECRET_KEY - object-store root creds. Rotate BOTH, then restart minio.
openssl rand -hex 12   # access key
openssl rand -hex 24   # secret key

# RESTIC_PASSWORD - encrypts the off-device backup repo. ESCROW THIS off-host (see DR); only if you
# enable the off-device backup tier.
openssl rand -hex 32

# API_TOKENS entries - only if you use legacy static bearer tokens instead of real sign-in.
# One per identifier, e.g. {"<paste>":"alice"}
openssl rand -hex 24
```

Everything **not** in that list is obtained from a provider/service dashboard (Apple, Google,
Plaid, Splitwise, Cloudflare, Tailscale, your push relay) - the reference below says which.

### Full variable reference

Grouped by purpose. "Source" = **generate** (above), **provider** (an external dashboard),
**placeholder** (leave as-is; compose pins the real value), or a plain default you may edit.

#### Core &amp; identity

| Variable | Source | Notes |
| --- | --- | --- |
| `APP_NAME` | default | Display name (`Cleave`). Set to e.g. `Cleave Demo` on the demo stack. |
| `DEFAULT_CURRENCY` | default | Fallback currency (`USD`). Also an admin-editable server setting. |
| `LOGO_UPSTREAM_TEMPLATE` | default | Upstream URL template (with a `{domain}` placeholder) for the merchant/institution logo proxy. Defaults to Google's favicon service; point it at a logo.dev token URL for higher-res brand logos. |
| `API_TOKENS` | generate | JSON map `token → identifier` for legacy static auth / dev impersonation. `{}` = off. Prefer real sign-in. |
| `ADMIN_USERS` | your id | JSON list of `/me` identifiers granted admin (backups, settings, invites). `[]` = none (but the first user to claim a fresh server becomes admin automatically). |
| `DEMO_MODE` | default | `true` enables the name-only guest login + auto-seed. Keep `false` on real/dev; the endpoint 404s when off. |

#### Auth &amp; security

| Variable | Source | Notes |
| --- | --- | --- |
| `AUTH_JWT_SECRET` | **generate** | HS256 secret for session tokens. **≥32 chars; startup fails without it when `AUTH_REQUIRED=true`.** Fresh per stack. |
| `AUTH_REQUIRED` | default | `true` enforces auth on guarded endpoints (production). `false` = open mode (dev/tests). |
| `ENCRYPTION_KEYS` | **generate** | JSON list of Fernet keys; first encrypts, any decrypts (rotation). Set **before** first boot (before linking any bank). `[]` = plaintext (dev only). Escrow off-host. |
| `ALLOWED_HOSTS` | your hosts | JSON list; rejects spoofed `Host` headers. Behind a tunnel, enumerate **every** public + LAN hostname. `[]` = off. |
| `CORS_ALLOWED_ORIGINS` | your origins | JSON list; only needed for a browser client (the native app needs none). `[]` = CORS not mounted. |

#### Sign-in providers

Short values, long setup - each dashboard walkthrough is linked. The app side is configured in
`ios/project.yml`; these are the **backend** halves (the audiences it verifies tokens against).

| Variable | Source | Notes |
| --- | --- | --- |
| `GOOGLE_CLIENT_ID` | provider | The Google **iOS** OAuth client id (`...apps.googleusercontent.com`); the id-token audience. **Your** app's id if you build your own; the App Store build's id if you point an existing one at your backend. → [Google OAuth setup](docs/google-oauth-setup.md) |
| `APPLE_AUDIENCE` | provider | The iOS app bundle id (e.g. `money.cleave.app`); the Apple identity-token audience. **Your** bundle id if you build your own app; the App Store build's if you point an existing one at your backend. → [`docs/PROVIDERS.md`](../docs/PROVIDERS.md) |
| `APPLE_TEAM_ID` | provider | Apple Developer Team ID; enables Universal Links (AASA 404s until set). **Only effective with your own app build** - no effect for a third-party App Store build. |

#### Database &amp; object storage

| Variable | Source | Notes |
| --- | --- | --- |
| `DATABASE_URL` | placeholder | Compose pins the real DSN to the `db` service - leave as-is. |
| `POSTGRES_PASSWORD` | **generate** | Compose var (`${POSTGRES_PASSWORD:-cleave}`); the `cleave` default is dev-only. Set a strong value before exposing. |
| `MINIO_ENDPOINT` | default | In-cluster address (`minio:9000`). The app never exposes MinIO publicly. |
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | **generate** | **Both** the app's S3 creds **and** MinIO's root user/password. Rotate together + restart minio. |
| `MINIO_BUCKET` | default | Receipts bucket (`receipts`; e.g. `receipts-demo` on demo). |
| `BACKUPS_BUCKET` | default | Backups bucket (`backups`). |
| `MINIO_SECURE` | default | `false` in-cluster (plain HTTP over the internal network). |
| `MAIN_DB_VOLUME` / `DEV_DB_VOLUME` | default | Docker volume names. Fresh installs keep defaults; an existing operator binds their current project-prefixed volumes here to avoid migrating data. |

#### Financial integrations

| Variable | Source | Notes |
| --- | --- | --- |
| `PLAID_CLIENT_ID` | provider | Plaid client id (shared across envs). → [`docs/PROVIDERS.md`](../docs/PROVIDERS.md) |
| `PLAID_SECRET` | provider | The secret **for the chosen `PLAID_ENV`** (sandbox vs production differ). |
| `PLAID_ENV` | default | `sandbox` \| `development` \| `production`. |
| `PLAID_REDIRECT_URI` | your host | Required for production OAuth banks; must be **registered verbatim** in the Plaid dashboard and handled by the app. Blank for sandbox - an unregistered value rejects every link token. |
| `SPLITWISE_CONSUMER_KEY` / `_CONSUMER_SECRET` | provider | Splitwise OAuth2 client id/secret. → [`docs/PROVIDERS.md`](../docs/PROVIDERS.md) |
| `SPLITWISE_REDIRECT_URI` | your host | Must match the callback registered in your Splitwise app (public https in prod). |
| `SPLITWISE_USER_MAP` | optional | JSON map of Splitwise user id → local identifier, e.g. `{"123":"alice"}`. |

#### Provider setup (step by step)

With all of these left empty the backend runs in **open mode** (no auth, no bank linking) - fine
for first-run and local dev. The backend only ever **verifies** a provider token and issues its own
JWT; it never stores a provider password. **Google** has its own reusable walkthrough:
[Google OAuth setup](docs/google-oauth-setup.md).

> **First, which app will people use?** This matters for Apple/Google below.
>
> _(The App Store listing isn't live yet - until it ships, everyone builds from source and the
> "build your own app" path applies. The published-app path below is how onboarding will work once
> it's listed.)_
>
> - **Your users install the published Cleave app and point it at your backend** (easiest - the
>   natural way to onboard a community: no Apple Developer account, no sideloading). Just share your
>   backend URL. **Splitwise, demo/guest, and bearer-token sign-in work out of the box** (they don't
>   depend on the app binary). For **Apple/Google sign-in**, set `APPLE_AUDIENCE` and
>   `GOOGLE_CLIENT_ID` to the **published app's public audiences** - they're public, they just have
>   to match what the binary was built with:
>   - `APPLE_AUDIENCE=money.cleave.app`
>   - `GOOGLE_CLIENT_ID=466528965386-hjlem1kitvnnbgg28ola7iempqr85gg1.apps.googleusercontent.com`
>
>   **Joining** is by pasting your backend URL or scanning its QR in the app; Universal Link *taps*
>   resolve to the official app's domain, not yours, so `APPLE_TEAM_ID` has no effect here. Skip the
>   Apple/Google walkthroughs below (they're for building your own app) - you only set those two
>   values.
> - **You build and ship your own app** (advanced - full white-label). Create your own Apple App ID
>   + Team ID and Google iOS client id; the values below are then *yours*, and Universal Link
>   join-links resolve to *your* own domain. Cost: an Apple Developer account and distributing the
>   app. The walkthroughs below assume this - "your bundle id" means *your* app.
>
> See [iOS → Two ways to run the app](../ios/README.md#connecting-to-a-backend) for the app side.

<details>
<summary><b>Sign in with Apple</b> - sets <code>APPLE_AUDIENCE</code>, <code>APPLE_TEAM_ID</code></summary>

Native iOS sign-in verifies Apple's identity token against Apple's public keys (RS256) - **no client
secret or Services ID needed** (those are only for the web redirect flow, which Cleave doesn't use).
The backend only needs the audience. *(This assumes you build your own app - see the note above if
people will use an existing App Store build against your backend.)*

1. **Apple Developer → Certificates, Identifiers &amp; Profiles → Identifiers →** your App ID (e.g.
   `money.cleave.app`) → enable **Sign in with Apple** → **Save**.
2. In **Xcode**, add the **Sign in with Apple** capability to the app target (already declared in
   `ios/project.yml`).
3. Set **`APPLE_AUDIENCE`** to the bundle id.
4. For Universal Links (the join link / AASA), also set **`APPLE_TEAM_ID`** to your Apple Developer
   Team ID - the backend serves `/.well-known/apple-app-site-association` built from
   `<APPLE_TEAM_ID>.<APPLE_AUDIENCE>` and returns 404 until it's set. **Only effective with your own
   app build** - Universal Links depend on associated domains compiled into the binary, so this does
   nothing for a third-party App Store build pointed at your backend.
</details>

<details>
<summary><b>Splitwise</b> - sets <code>SPLITWISE_CONSUMER_KEY</code>, <code>_CONSUMER_SECRET</code>, <code>_REDIRECT_URI</code></summary>

Splitwise doubles as a sign-in provider **and** the bridge for shared groups, so one OAuth app
covers both.

1. Register an app at Splitwise's developer portal (**Register your application**) to obtain a
   **Consumer Key** and **Consumer Secret**.
2. Set the app's callback / redirect URL to your public host:
   `https://your-host.example.com/auth/splitwise/callback` (or
   `http://localhost:8000/auth/splitwise/callback` for local dev).
3. Set **`SPLITWISE_CONSUMER_KEY`**, **`SPLITWISE_CONSUMER_SECRET`**, and **`SPLITWISE_REDIRECT_URI`**
   to match.

*Flow:* the app opens `GET /auth/splitwise/login` in an `ASWebAuthenticationSession` → consent →
`GET /auth/splitwise/callback` redirects to `cleave://auth?token=<jwt>`, which the app catches.
</details>

<details>
<summary><b>Plaid</b> - sets <code>PLAID_CLIENT_ID</code>, <code>PLAID_SECRET</code>, <code>PLAID_ENV</code>, <code>PLAID_REDIRECT_URI</code></summary>

Plaid links banks and syncs transactions server-side (the app only talks to Plaid through the Link
SDK during linking). Plaid's free **Trial** plan allows up to **10 Production Items** (linked
institutions) with real bank data - typically enough for personal use; beyond that you upgrade to a
paid plan. (Plaid retired the old standalone **Development** tier.)

1. Create a **Plaid** account; copy your `client_id` + secret from the dashboard. The secret differs
   per environment - grab the one matching your `PLAID_ENV`.
2. Set **`PLAID_CLIENT_ID`**, **`PLAID_SECRET`**, and **`PLAID_ENV`**
   (`sandbox` / `development` / `production`).
3. **Production/OAuth banks only:** register `https://your-host.example.com/plaid/oauth` as an
   allowed **redirect URI** in the Plaid dashboard and set it as **`PLAID_REDIRECT_URI`**. Leave it
   blank for sandbox - an *unregistered* value rejects **every** link token. The iOS app handles that
   redirect as a Universal Link (the AASA covers `/plaid/oauth*`, so `APPLE_TEAM_ID` must be set).

*Flow:* app requests a link token (`POST /plaid/link-token`) → runs Plaid Link → exchanges the
public token (`POST /plaid/exchange`); the backend stores the **encrypted** access token and syncs
via `/transactions/sync`.
</details>

#### Off-device backups (restic - optional)

Only needed if you enable the off-device backup tier (the target repo string + on/off toggle are
admin-editable in-app, **not** here). See [Backups &amp; disaster recovery](#backups--disaster-recovery).

| Variable | Source | Notes |
| --- | --- | --- |
| `RESTIC_PASSWORD` | **generate** | Encrypts the off-device repo. **Always required** for the tier; **escrow off-host** - losing it makes the offsite copy unrecoverable. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | provider | Only for an **S3-compatible** target (AWS/B2/Wasabi). For rclone remotes use `RCLONE_CONFIG_*`; for SFTP use an SSH key in `./secrets/ssh` (no env). |

#### Ingress (Compose-only - the API never reads these)

| Variable | Source | Notes |
| --- | --- | --- |
| `CLOUDFLARE_TUNNEL_TOKEN` | provider | Cloudflare dashboard tunnel token (remotely-managed). Omit for a locally-managed `cloudflared/config.yml`. `--profile tunnel`. |
| `TS_AUTHKEY` | provider | Tailscale auth key. `--profile tailscale`. |
| `TS_HOSTNAME` | default | Tailnet node name (e.g. `cleave`). |
| `TS_EXTRA_ARGS` | optional | Extra `tailscale up` flags (e.g. `--advertise-tags=tag:cleave`). |

#### Push

| Variable | Source | Notes |
| --- | --- | --- |
| `PUSH_RELAY_URL` | your host | Compose sets `http://relay:8000` if you run the bundled relay; override to point at a remote relay. Empty = push disabled. |
| `PUSH_RELAY_API_KEY` | provider | Issued by your relay's self-serve registration form. Empty = push disabled. |

### Push relay secrets (`.env.relay`)

The push relay is a **separate service** with its own template (`.env.relay.example` → `.env.relay`)
because it - and only it - holds your Apple push credentials. Copy the `.p8` from your Apple
Developer account and base64-encode it for `APNS_AUTH_KEY`. See [Operating in production](#operating-in-production).

| Variable | Source | Notes |
| --- | --- | --- |
| `APNS_KEY_ID` / `APNS_TEAM_ID` | provider | From the APNs auth key + your Apple Developer team. |
| `APNS_BUNDLE_ID` | provider | Your app bundle id (e.g. `money.cleave.app`). |
| `APNS_AUTH_KEY` | provider | **base64 of the `.p8`**: `base64 -i AuthKey_XXXX.p8`. |
| `APNS_ENV` | default | `production`, or `sandbox` for dev/TestFlight. |
| `ADMIN_TOKEN` | **generate** | Gates the relay's `/admin` key-management UI/API (`openssl rand -hex 32`). Empty = admin off. |
| `ADMIN_USER` | default | Basic-auth username for `/admin` (password = `ADMIN_TOKEN`). |
| `RELAY_AUTO_ISSUE` | default | `true` = registration returns a key immediately; `false` = pending approval. |
| `DB_PATH` | default | SQLite store path (mount a volume at `/data`). |
| `RELAY_REQUIRE_E2EE` | default | `true` refuses plaintext-body pushes (set before opening the relay to other self-hosters). |
| `REGISTER_MAX_PER_HOUR` / `PUSH_MAX_PER_MINUTE` | default | Abuse limits (per IP / per key). |

## Connecting your money

Cleave supports three ways to get transactions in, so you can match cost, coverage, and
privacy per account:

| Method | Cost / setup | Coverage | Direction | Best for |
| --- | --- | --- | --- | --- |
| **Plaid** | Server-side API keys; per-item pricing | Broadest, live | Read | Most banks, hands-off sync |
| **SimpleFIN** | One pasted token; ~$1.50/mo, ~24 reqs/day | Good, live | Read-only | Privacy, no app credentials |
| **OFX import** | Free, manual upload | Anything with a statement export | Read | Apple Card &amp; aggregator-hostile banks |

And two ways to handle shared expenses:

- **Splitwise (two-way sync).** OAuth2 + PKCE sign-in, full-history import, live incremental
  sync (edits, settle-ups, deletions), and local→Splitwise push. Receipts behind Splitwise's
  authenticated API are proxied and can be backfilled into your own storage.
- **Native self-hosted groups.** No external dependency; the same split/item/receipt model,
  fully under your control. Migrate a Splitwise group here whenever you're ready to leave.

Institution and merchant branding is handled by a self-hosted **logo proxy**: favicons/logos
are fetched once, cached in MinIO, and served token-lessly to the app - so your merchant and
bank list never leaves the backend to a logo CDN, with negative-caching so a long list stays
fast.

Step-by-step setup for each provider is in the collapsible walkthroughs under
[Configuration → Provider setup](#provider-setup-step-by-step) (and [`docs/PROVIDERS.md`](../docs/PROVIDERS.md)).

## Multi-user: invites &amp; partner sharing

One backend serves several **people**, each scoped server-side to their own data. Two distinct
mechanisms make that work, and it's worth keeping them straight: **invites** get someone *onto* your
server; **partner connections** let two people already on it *share* selected data one-to-one.
(App side: [iOS → Share &amp; collaborate](../ios/README.md#share--collaborate).)

### Enrollment &amp; invites

Registration is **closed by default**: signing in isn't enough - a user must be *enrolled* (the DB
`users.enrolled` flag, re-checked on every request, so clearing it cuts access instantly). Enrollment
is granted exactly two ways:

- **Claiming a fresh server** - the first person to sign in when no users are enrolled is auto-enrolled
  *and* made admin.
- **Redeeming a single-use invite** - an enrolled member mints an invite and shares its join link / QR;
  a new person redeems the code **at sign-in**. Redemption is atomic (one `UPDATE ... RETURNING` spends
  the code, so it can't be double-spent) and notifies the inviter.

Invites carry an optional label and TTL and have a lifecycle status - **active / redeemed / expired /
revoked** (revoking a spent or already-revoked invite is inert).

- **Endpoints:** `POST /invites` (mint), `GET /invites` (list + status), `DELETE /invites/{id}` (revoke).
  Redemption has no endpoint - the code rides in via the join link / OAuth state at sign-in.
- **Who may invite:** `require_can_invite` - an admin always, or any enrolled member when the
  `invites_open_to_members` server setting is on.

### Partner connections &amp; sharing

Two enrolled users can **connect** (Zeta-style) to share money data one-to-one - entirely separate from
Splitwise groups. A connection is a request → accept handshake:

- `POST /connections` - invite a partner by identifier or email (they must **already be enrolled**) →
  **pending**; fires a `connection_request` notification.
- `POST /connections/{id}/accept` - only the invited party; → **accepted**, fires `connection_accepted`.
- `DELETE /connections/{id}` - decline a pending invite or disconnect an accepted partner (either party).
- `GET /connections` - incoming/outgoing pending + accepted, each resolved to the other person.

An **accepted connection is the sharing seam**: server-side scoping treats your accepted partners as
your "audience," and each sharing feature widens exactly that seam without touching read paths - 

- **Accounts** carry a `share_level` - **private** (default), **balances** (partner sees the balance
  only), or **full** (balance + transactions). A shared-in account is read-only, tagged with who shared
  it (a `full` partner can read its transactions by id, while your unscoped list stays yours). Sharing
  fires `account_shared`.
- **Goals** can be shared read-only to your accepted partners (`goal_shared`); a partner's shared goals
  appear in your list tagged `shared_by`.
- **Household budgets** build on this - a shared "spend" goal counts *both* partners' spending across
  your shared groups toward one limit, computed so both apps arrive at the same number.

Sharing is always **opt-in per item and read-only** - a partner never gains write access to your data.

## Security &amp; privacy

Security is the reason to self-host, so it is treated as a feature:

- **Token encryption at rest.** Plaid and Splitwise access tokens are Fernet-encrypted at the
  column level (`MultiFernet`, so keys rotate). A DB dump leaks only ciphertext. A startup
  health check warns loudly if the configured keys can't decrypt stored tokens (the classic
  "restored the DB without its keys" trap).
- **Optional, end-to-end-encrypted push.** Push notifications are opt-in: enable them by
  registering your backend with a **blind push relay** - a standalone service that hands your
  alerts to Apple. Before a notification leaves your server, its real text is encrypted so
  that only the destination phone can read it (ECIES: P-256 ECDH → HKDF → AES-256-GCM). The
  relay and Apple therefore only ever see two things: an encrypted blob they can't read, and a
  fixed placeholder alert that just says "New activity." Your phone decrypts the blob and swaps
  in the real message, so the actual notification content is only ever readable on your own
  device. A device with no encryption key is skipped rather than sent in the clear.
- **Owner scoping / multi-tenancy.** Every request runs as a resolved caller; resources are
  scoped to their owner plus explicitly shared or group data, through a single auditable
  sharing seam.
- **Invite-only enrollment.** A session is valid only while the user's `enrolled` flag is set,
  re-checked on every request - so revoking someone kills their existing token immediately.
  Sharing is opt-in, per-item, read-only. Details: [Multi-user](#multi-user-invites--partner-sharing).
- **HTTP hardening.** Trusted-host allow-list, opt-in CORS, and baseline security headers
  (`nosniff`, `frame-ancestors 'none'`, HSTS, ...) on every response.
- **Idempotency &amp; rate limiting.** `Idempotency-Key` collapses retried creates (and avoids a
  duplicate Splitwise push); a per-IP sliding-window limiter bounds abuse of unauthenticated
  endpoints behind Cloudflare.
- **Real account deletion.** `DELETE /users/{id}` (your own account, or any account for an admin)
  purges personal data - Plaid items (**revoking the token at Plaid**), the Splitwise token, and
  owned accounts/transactions/goals - while retaining co-owned shared-group history so others'
  balances stay intact. A separate reversible **deactivate/re-enroll** (clearing the `enrolled`
  flag) cuts off access without deleting data.

## Backups &amp; disaster recovery

A backup is a complete, restorable snapshot of one stack - a Postgres custom-format dump plus
every receipt object - packed into a single `tar.gz` in a dedicated MinIO bucket.

- **Scheduled + manual** backups; retention keeps the newest N scheduled backups and prunes
  the rest, while manual backups are never auto-deleted.
- **Atomic restore** takes a pre-restore safety backup, then restores in a single transaction
  and re-uploads receipts - roll-forward that rolls back cleanly on failure.
- **Off-device tier** (optional): [restic](https://restic.net/) pushes an encrypted, deduped
  copy to an SFTP target (e.g. a Synology NAS), S3, or any rclone remote, so losing the host
  doesn't lose the backups. Repo password and remote creds come only from container env,
  never the settings API.
- **Two secrets to escrow off-host:** `ENCRYPTION_KEYS` (lose it → re-link banks/Splitwise)
  and `RESTIC_PASSWORD` (lose it → the off-device repo is unrecoverable). The backup archive
  deliberately contains neither.

Full procedure, including SFTP/Synology setup gotchas, in
[`docs/DISASTER_RECOVERY.md`](docs/DISASTER_RECOVERY.md).

## Operating in production

- **Ingress:** Cloudflare Tunnel or Tailscale (`serve`/Funnel) compose profiles - the app
  reaches a stable HTTPS hostname (public via the tunnel or Funnel, or tailnet-private via
  `serve`), while raw Postgres/MinIO ports stay on the internal network.
- **Universal Links &amp; onboarding:** the API serves its own join/demo landing pages and the
  Apple App Site Association file (`/.well-known/apple-app-site-association`, live once
  `APPLE_TEAM_ID` is set) - no separate static host.
- **Capability discovery:** the app pings `/server-info` to confirm a URL is really a Cleave
  backend and learn which providers/features are enabled before adopting it.
- **Health checks:** `/health` (liveness) and `/health/db` (`SELECT 1`), matching the compose
  `pg_isready` probes.
- **Background loops** run in-process from the app lifespan (sync, backups, notifications,
  demo-prune); each re-reads its interval from server settings every tick and is paused by
  setting the interval to `0`.
- **Demo mode:** an opt-in public instance with a name-only guest login and auto-seeded,
  isolated sample data, pruned on a schedule - 404s everywhere when off.

### Exposing the backend (step by step)

Pick one connector so the app works off your LAN. Both are Compose-only side profiles - the API
never reads their config - and whatever hostname you land on is what you set as the app's server URL.
Any external reverse proxy (nginx, Caddy, ...) works too.

<details>
<summary><b>Cloudflare Tunnel</b> - public HTTPS at your domain (needs a domain in Cloudflare)</summary>

Remotely-managed (dashboard token) is the simplest path:

1. Cloudflare **Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared** → name it → copy
   the connector **token**.
2. Add a **public hostname** for each stack you run (Cloudflare auto-creates DNS). The service is the
   compose service name on container port `:8000`, since the connector shares the stack's network:
   - `your-host.example.com` → `http://api:8000` (the real instance)
   - `dev.your-host.example.com` → `http://api-dev:8000` (`--profile dev`)
   - `demo.your-host.example.com` → `http://api-demo:8000` (`--profile demo`)
   - `push.your-host.example.com` → `http://relay:8000` (the push relay)
3. Put the token in `.env`: `CLOUDFLARE_TUNNEL_TOKEN=<token>`.
4. Start it: `docker compose --profile tunnel up -d cloudflared`.

*Prefer to manage ingress yourself?* Copy `cloudflared/config.yml.example` →
`cloudflared/config.yml` and drop the tunnel's `credentials.json` alongside it - the connector
auto-detects the file and switches to locally-managed (no token, no compose edit). Full runbook:
[`docs/OPERATIONS.md`](../docs/OPERATIONS.md).
</details>

<details>
<summary><b>Tailscale</b> - tailnet-private (no domain), or public via Funnel</summary>

Join the backend to your tailnet and reach it from your own devices - no public exposure:

1. Generate a **tailnet auth key** (Tailscale admin console → **Settings → Keys**; reusable + tagged
   is handy).
2. Put it in `.env`: `TS_AUTHKEY=<key>` (optionally `TS_HOSTNAME=cleave`,
   `TS_EXTRA_ARGS=--advertise-tags=tag:cleave`).
3. Copy `tailscale/serve.json.example` → `tailscale/serve.json` (it proxies the node's `:443` →
   `http://api:8000`; change the target to `api-demo:8000` etc. for other stacks).
4. Start it: `docker compose --profile tailscale up -d tailscale`.
5. Reach the backend at `https://${TS_HOSTNAME}.<your-tailnet>.ts.net` from any device on the
   tailnet - set that as the app's server URL.

**Public exposure (Funnel):** `serve.json` ships with `AllowFunnel` set to `false` (tailnet-private).
To serve it to the open internet, flip that one line to `true` and enable Funnel for the node in your
tailnet ACLs. Funnel supports only the standard ports (443/8443/10000).
</details>

### Push notifications - use the official relay, or run your own

Push is **optional** and end-to-end encrypted: the backend holds no Apple credentials - it seals each
payload to the device's key and POSTs the ciphertext to a **push relay**, which forwards it to Apple's
APNs. (How the sealing + on-device decryption works:
[iOS → Privacy &amp; security](../ios/README.md#privacy--security) and the notification-service extension
in [iOS → Architecture](../ios/README.md#architecture).)

**Which relay you need is tied to which app your users run** - the same split as sign-in. APNs
authenticates every push against an Apple **team + bundle id** (the relay's `.p8` auth key and its
`apns-topic`), so a relay can only deliver to the exact app its key was issued for:

- **Your users run the published Cleave app** → register your backend with the **official relay** at
  [push.cleave.money](https://push.cleave.money) for an API key, set `PUSH_RELAY_API_KEY`, and point
  `PUSH_RELAY_URL` at it. Done.
- **You built your own app** (own bundle id + team) → the official relay **cannot** push to it (APNs
  rejects a device token that isn't for its bundle id - `DeviceTokenNotForTopic`). You must **run your
  own relay** configured with **your own** APNs key. It's the push counterpart of building your own app.

<details>
<summary><b>Run your own push relay</b> - for a self-built app (sets <code>.env.relay</code>)</summary>

The relay is a small standalone service (bundled as the `relay` compose service, or run it on its own
host). It holds your APNs key and nothing else app-specific; self-hosted backends register with it for
an API key and then POST sealed pushes. One relay serves one app identity (its bundle id + team), but
can serve **many backends** running that same app.

1. **Create an APNs auth key.** Apple Developer → **Certificates, Identifiers &amp; Profiles → Keys →
   +** → enable **Apple Push Notifications service (APNs)** → download the `.p8` **once**. Note its
   **Key ID**; your **Team ID** is on the account page.
2. **Configure `.env.relay`.** Copy `.env.relay.example` → `.env.relay` and set:
   - `APNS_KEY_ID`, `APNS_TEAM_ID` - from step 1.
   - `APNS_BUNDLE_ID` - **your app's** bundle id (must match the build your users install).
   - `APNS_AUTH_KEY` - base64 of the `.p8`: `base64 -i AuthKey_XXXX.p8`.
   - `APNS_ENV` - `production`, or `sandbox` for a dev/TestFlight build.
   - `ADMIN_TOKEN` - `openssl rand -hex 32` (gates the relay's `/admin` key UI).
   See [Push relay secrets](#push-relay-secrets-envrelay) for the full list.
3. **Start it.** `docker compose up -d relay` (bundled, reachable in-cluster at `http://relay:8000`,
   published on `:8003`) - or deploy it on a separate host and expose it (e.g. a
   `push.your-host.example.com` tunnel hostname).
4. **Issue an API key.** Open the relay's registration page (`/`) - or its `/admin` UI with
   `ADMIN_TOKEN` - and issue a key. Put it in `.env` as `PUSH_RELAY_API_KEY`, and point
   `PUSH_RELAY_URL` at the relay (the bundled compose already sets `http://relay:8000`; override for a
   remote relay).
5. **Serving other self-hosters?** If you open your relay to other backends running your app, set
   `RELAY_REQUIRE_E2EE=true` so it refuses any non-encrypted payload - it then physically cannot see
   notification content it forwards.

Full operator runbook - API-key management (issue/approve/revoke), the backend↔relay HTTP contract,
APNs troubleshooting, and standalone/community deployment - is in the
[**relay README**](../relay/README.md).
</details>

More in [`docs/OPERATIONS.md`](../docs/OPERATIONS.md).

## Development

```bash
# Optional dev profile: sandbox Plaid + synthetic seed data on :8001 (auto-migrates on start)
docker compose --profile dev up -d db-dev api-dev
docker compose exec api-dev python -m app.cli.seed_dev     # synthetic sample data
```

Dependencies are managed with [uv](https://github.com/astral-sh/uv) and pinned in
`pyproject.toml`. Linting/formatting is [ruff](https://docs.astral.sh/ruff/) (line length 100,
target py312) - the only style opinion imposed.

Useful CLI entry points (`python -m app.cli.<name>`): `import_splitwise`, `splitwise_sync`,
`plaid_sync`, `seed_dev`, `prune_demo`.

## Testing

The suite runs against Postgres with a **deliberately dependency-free runner** (no pytest in
the image). One command does the whole thing - it's the exact script CI runs:

```bash
bash scripts/test-backend.sh   # from the repo root; or scripts/test-all.sh for relay + backend
```

It brings up the ephemeral, tmpfs-backed `test` profile (auth forced open), migrates a clean DB,
and runs the module runner - equivalent to:

```bash
docker compose --profile test up -d db-test api-test
docker compose exec -T api-test alembic upgrade head   # the test service sets RUN_MIGRATIONS=false
docker compose exec -T api-test sh run_tests.sh
```

There are **84 test modules** covering auth/scoping, every integration mapper and sync path,
idempotency and concurrent upserts, migrations round-trip, backups/retention, spend/category
parity, and more. See [`docs/TESTING.md`](../docs/TESTING.md) for the two-suite layout and how
CI mirrors (rather than gates) local runs.

## Project layout

```
backend/
├── app/
│   ├── main.py              # FastAPI app, router wiring, lifespan (schedulers, MinIO, key check)
│   ├── config.py            # .env settings (secrets + deploy topology)
│   ├── server_settings.py   # admin-editable runtime policy (typed registry)
│   ├── auth/                # JWT, identity resolution, owner scoping, admin gating
│   ├── security/            # Fernet field encryption + key-health check
│   ├── routers/             # 29 API routers (expenses, accounts, balances, goals, export, backups, ...)
│   ├── models/              # 31 SQLAlchemy models
│   ├── schemas/             # Pydantic request/response models
│   ├── services/            # sync, spend/budget engine, notifications, push, backups, schedulers
│   ├── integrations/        # splitwise/ plaid/ simplefin/ statements/ export/ auth/ storage/ logos
│   └── cli/                 # import / sync / seed / prune entry points
├── migrations/              # Alembic (single squashed baseline; auto-runs on boot)
├── tests/                   # 84 test modules + a pytest-free runner
├── docs/                    # DISASTER_RECOVERY.md (OPERATIONS / PROVIDERS / TESTING live in repo-root docs/)
├── Dockerfile
└── pyproject.toml
```

## API

- **Interactive docs:** `/docs` (Swagger UI) and `/redoc`, generated from the live app.
- **Export the schema:** `python scripts/export_openapi.py` writes the OpenAPI JSON the iOS
  client generates against.
- **Auth:** send the backend JWT as `Authorization: Bearer <token>`. Guarded routers pass
  through untouched in open mode (no `API_TOKENS`, `AUTH_REQUIRED` off).
- **Export your data:** per-format endpoints under `/export` (e.g. `GET /export/expenses.csv`,
  `/export/transactions.ofx`, `/export/accounts.json`) or `GET /export/archive.zip` for
  everything at once, with `?receipts=false` to omit the receipt files.

## Roadmap

- **Turnkey deployment** - one-click store templates (Unraid / Umbrel / CasaOS / Runtipi / Helm) on
  top of the prebuilt image, so first-run needs no hand-edited config file.
- **Apply AI categories directly** - an opt-in setting to apply on-device AI categorization without
  routing every suggestion through the Inbox.
- **Two-level categories** - a parent/sub taxonomy so budgets and reports can roll up or drill down.
- **More statement formats** - CSV / QFX / QBO import alongside the current OFX.
- **Notification deep-linking** - tap a push to open the exact expense or group, plus per-user mute.
- **Push relay hardening** - emailed keys, an admin dashboard, and splitting the relay into its own repo.

## Contributing

Issues and pull requests are welcome. Because Cleave handles financial data, changes to sync,
scoping, or the spend engine should come with tests (the parity tests exist precisely so the
server and app can't silently diverge). Run `bash scripts/test-backend.sh` (or `scripts/test-all.sh`)
and `ruff` before opening a PR.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full workflow (including DCO sign-off), the
[Code of Conduct](../CODE_OF_CONDUCT.md), and [SECURITY.md](../SECURITY.md) for reporting
vulnerabilities.

## License

[GNU Affero General Public License v3.0](LICENSE). If you run a modified Cleave as a network
service, the AGPL requires you to offer your users the modified source.

---




