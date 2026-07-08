# Cleave Push Relay

**A standalone, blind APNs relay for self-hosted [Cleave](../README.md) instances.**

The Cleave backend deliberately holds **no Apple credentials**. Instead it seals each notification to
the recipient device's key and POSTs the ciphertext to this relay, which forwards it to Apple's push
service (APNs). The relay holds the one Apple push key; with end-to-end encryption on, it forwards
opaque ciphertext and never sees a notification's contents. One relay can serve **many** self-hosted
backends - they self-register for an API key.

<p>
  <img alt="License: AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-blue">
  <img alt="FastAPI" src="https://img.shields.io/badge/FastAPI-httpx%20HTTP%2F2-009688">
  <img alt="Storage: SQLite" src="https://img.shields.io/badge/store-SQLite-044a64">
  <img alt="Python 3.12+" src="https://img.shields.io/badge/python-3.12%2B-blue">
</p>

---

## Table of contents

- [When you need this](#when-you-need-this)
- [What it can &amp; can't see](#what-it-can--cant-see)
- [Quick start](#quick-start)
- [How push flows](#how-push-flows)
- [API key management](#api-key-management)
- [HTTP API](#http-api)
- [APNs setup &amp; troubleshooting](#apns-setup--troubleshooting)
- [Configuration](#configuration)
- [Running standalone / for a community](#running-standalone--for-a-community)
- [Project layout](#project-layout)
- [License](#license)

---

## When you need this

Push is **optional**. Whether you need to run your own relay depends on which app your users run - 
the same split as sign-in (see [backend → Push notifications](../backend/README.md#push-notifications--use-the-official-relay-or-run-your-own)):

- **Your users run the published Cleave app** → you don't run a relay at all; register your backend
  with the **official relay** at [push.cleave.money](https://push.cleave.money) for an API key.
- **You built and ship your own app** (own bundle id + Apple team) → APNs authenticates every push
  against a **team + bundle id**, so the official relay physically can't deliver to your build. **You
  run this relay** with your own Apple push key. That's what this README covers.

> **One relay = one app identity.** A relay carries a single APNs key (one team) and pushes to a
> single `apns-topic` (one bundle id). It can serve unlimited *backends*, but only for the *one app*
> its key was issued for.

## What it can & can't see

The relay is designed to be **blind** and safe to operate for other people:

- **With `RELAY_REQUIRE_E2EE=true`** it accepts only end-to-end-encrypted pushes - an opaque
  `{epk, box}` ciphertext plus a generic fallback alert ("New activity"). It forwards the ciphertext
  to APNs and the recipient device decrypts it; the relay and Apple never see the real title/body.
  (Client half: [iOS → Privacy &amp; security](../ios/README.md#privacy--security) and the
  notification-service extension in [iOS → Architecture](../ios/README.md#architecture).)
- **API keys are never stored in the clear** - only their SHA-256 hash is persisted; the plaintext key
  is shown **once**, at issue time.
- It holds your **APNs `.p8`** (the one real secret) and a SQLite table of key hashes + metadata
  (email, instance name, usage counts). Nothing else.

A plaintext-push path exists for back-compat (the relay *would* see the content); leave
`RELAY_REQUIRE_E2EE=true` for any relay that isn't strictly your own single instance.

## Quick start

### Bundled with the Cleave stack (simplest)

The monorepo's `docker-compose.yml` already defines a `relay` service. Configure and start it:

```bash
cp .env.relay.example .env.relay      # from the repo root; fill in APNs creds (see below)
docker compose up -d relay            # in-cluster at http://relay:8000, published on :8003
```

The backend reaches it at `http://relay:8000` (already wired via `PUSH_RELAY_URL`); you just issue an
API key and set `PUSH_RELAY_API_KEY` on the backend - see [API key management](#api-key-management).

### Standalone (separate host)

The relay is a self-contained project (its own `Dockerfile`, `pyproject.toml`, `tests/`) - run it
anywhere, decoupled from the backend:

```bash
cd relay
docker build -t cleave-relay .
docker run -d --name cleave-relay \
  --env-file .env.relay \
  -e DB_PATH=/data/relay.db \
  -v cleave_relay_data:/data \
  -p 8003:8000 \
  cleave-relay
```

Put it behind TLS (e.g. a `push.your-host.example.com` tunnel hostname) so remote backends can reach
it, then point each backend's `PUSH_RELAY_URL` at that URL.

Verify: `curl -s https://push.your-host.example.com/health` → `{"status":"ok","apns_configured":true}`.

## How push flows

```
  backend                         relay                         Apple APNs            device
    │   POST /push  (Bearer key)     │                              │                    │
    │   { messages:[{token,epk,box}],│                              │                    │
    │     fallback_title/body }      │                              │                    │
    │ ─────────────────────────────▶ │  validate key + rate limit   │                    │
    │                                │  sign ES256 provider JWT     │                    │
    │                                │  POST /3/device/<token>      │                    │
    │                                │  apns-topic: <bundle id>     │                    │
    │                                │  {aps:{...,mutable-content:1}, │                    │
    │                                │   e2e:{epk,box}} ──────────▶ │  deliver ────────▶ │  NSE decrypts
    │   { "dead": [<tokens>] }       │  ◀── 410 / BadDeviceToken    │                    │  → real alert
    │ ◀───────────────────────────── │  (relay reports dead tokens) │                    │
```

The backend prunes any tokens the relay returns in `dead` (device uninstalled / token invalid). The
provider JWT is cached (~50 min) and signed with your `.p8` (ES256, `kid` = key id, `iss` = team id).

## API key management

Every backend that sends push authenticates with a **`relaysk_...` API key** (issued by this relay).
Keys are self-service or admin-issued, and have three states:

| State | Meaning | How it gets there |
| --- | --- | --- |
| **pending** | Registered but can't push yet | Self-registration when `RELAY_AUTO_ISSUE=false` |
| **active** | Can push | Auto-issue on registration, admin issue, or admin approve |
| **revoked** | Blocked (kept for audit) | Admin revoke |

**Self-service:** a backend operator opens the relay's `/` page, enters an email + optional instance
name, and gets a key (shown once). With `RELAY_AUTO_ISSUE=true` it's active immediately; otherwise it
waits for your approval. Registration is rate-limited per IP (`REGISTER_MAX_PER_HOUR`).

**Admin dashboard (`/admin`):** set `ADMIN_TOKEN` and visit `/admin` (Basic auth - username
`ADMIN_USER`, password `ADMIN_TOKEN`). From there you can **issue**, **approve**, **revoke**,
**reactivate**, and **delete** keys, and see each key's instance/email, status, created + last-used
times, and lifetime push count. The plaintext key is displayed only at issue time.

**On the backend side:** paste the key into `.env` as `PUSH_RELAY_API_KEY` (alongside
`PUSH_RELAY_URL`), then redeploy. Revoking the key in `/admin` cuts that backend off immediately.

## HTTP API

All JSON. `POST /push` needs a `Bearer <relaysk_...>` key; the `/admin/*` API needs the admin token
(`Bearer <ADMIN_TOKEN>` for curl, or Basic auth in a browser).

| Method &amp; path | Auth | Purpose |
| --- | --- | --- |
| `GET /health` | none | `{status, apns_configured}` - liveness + whether APNs creds are set |
| `POST /push` | API key | Forward alerts to APNs; returns `{dead: [...tokens]}` to prune |
| `GET /` | none | Self-serve registration form (HTML) |
| `POST /register` | none | Register `{email, instance}`; returns an HTML page (the key is embedded when auto-issue is on, else a pending-approval page). Rate-limited per IP. |
| `GET /admin` | admin | Key-management dashboard (HTML) |
| `GET /admin/keys` | admin | List keys (metadata only - no hashes, no plaintext) |
| `POST /admin/keys` | admin | Issue an active key `{email, instance}` → `{key}` |
| `POST /admin/keys/{id}/approve` | admin | Approve a pending key / reactivate a revoked one |
| `POST /admin/keys/{id}/revoke` | admin | Revoke (deactivate) a key |
| `DELETE /admin/keys/{id}` | admin | Delete a key permanently |

<details>
<summary><code>POST /push</code> request body</summary>

```jsonc
{
  // End-to-end-encrypted form (preferred): one entry per device.
  "messages": [
    { "token": "<apns-device-token>", "epk": "<base64 ephemeral pubkey>", "box": "<base64 ciphertext>" }
  ],
  "fallback_title": "Cleave",        // shown pre-decryption / if the extension can't run
  "fallback_body":  "New activity",

  // Plaintext form (back-compat; refused when RELAY_REQUIRE_E2EE=true).
  "tokens": ["<apns-device-token>"],
  "title":  "Cleave",
  "body":   "..."
}
```

Response: `{ "dead": ["<token>", ...] }` - device tokens APNs rejected as gone/invalid, which the
backend then deletes. A relay with unconfigured APNs returns **503**; a plaintext push to an
E2EE-only relay returns **400**.
</details>

## APNs setup & troubleshooting

**Create a key** (token-based auth, no certificates to renew):

1. Apple Developer → **Certificates, Identifiers &amp; Profiles → Keys → +** → enable **Apple Push
   Notifications service (APNs)** → download the `.p8` **once**. Note the **Key ID**.
2. Your **Team ID** is on the account/membership page.
3. Base64-encode the key for the env var: `base64 -i AuthKey_XXXXXXXX.p8`.

**Set** `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` (your app's bundle id), `APNS_AUTH_KEY` (the
base64), and `APNS_ENV`.

| Symptom | Likely cause |
| --- | --- |
| `/health` shows `apns_configured: false` | One of the four `APNS_*` creds is missing → `/push` returns 503. |
| Every token comes back in `dead` with `DeviceTokenNotForTopic` | `APNS_BUNDLE_ID` doesn't match the app the token came from - **the Model-A/Model-B mismatch**: the relay's bundle id must equal the installed app's. |
| Tokens `dead` as `BadDeviceToken`, only on TestFlight/dev builds | `APNS_ENV` mismatch - dev/TestFlight tokens need `sandbox`; App Store needs `production`. (APNs host switches on this.) |
| `410 Gone` for a token (`Unregistered`) | The app was uninstalled / token rotated - expected; the relay reports it as `dead` and the backend prunes it. |
| `403` in logs - `InvalidProviderToken` | Wrong `APNS_KEY_ID`/`APNS_TEAM_ID`, or the `.p8` doesn't belong to that team (the provider JWT signature can't be verified). |
| `403` in logs - `ExpiredProviderToken` | The provider JWT is stale - almost always a badly-skewed server clock (the relay refreshes the token every ~50 min, well inside Apple's 1-hour limit). |

## Configuration

Copy `.env.relay.example` → `.env.relay`. (Also documented in
[backend → Push relay secrets](../backend/README.md#push-relay-secrets-envrelay).)

| Variable | Notes |
| --- | --- |
| `APNS_KEY_ID` / `APNS_TEAM_ID` | From the APNs auth key + your Apple team. |
| `APNS_BUNDLE_ID` | **Your app's** bundle id - must match the installed build (this is the `apns-topic`). |
| `APNS_AUTH_KEY` | Base64 of the `.p8`: `base64 -i AuthKey_XXXX.p8`. |
| `APNS_ENV` | `production`, or `sandbox` for dev/TestFlight. |
| `ADMIN_TOKEN` | Gates `/admin*`; generate with `openssl rand -hex 32`. Empty = admin disabled. |
| `ADMIN_USER` | Basic-auth username for the `/admin` UI (password = `ADMIN_TOKEN`). Default `admin`. |
| `RELAY_AUTO_ISSUE` | `true` = registration returns an active key immediately; `false` = pending until you approve. |
| `DB_PATH` | SQLite path. In Docker, mount a volume at `/data` and set `/data/relay.db`. |
| `RELAY_REQUIRE_E2EE` | `true` refuses plaintext pushes - set this on any shared/public relay. |
| `REGISTER_MAX_PER_HOUR` | Registration attempts per IP (default 5). |
| `PUSH_MAX_PER_MINUTE` | Pushes per API key (default 600). |

## Running standalone / for a community

Because the relay holds no Cleave-specific logic - it's a **generic blind APNs forwarder** keyed by
env - one relay you operate can serve every self-hoster running *your* app:

- **Run it once, publicly** (e.g. `push.your-host.example.com`), and let other backends self-register
  at `/`. Keep `RELAY_REQUIRE_E2EE=true` so you can never see their notification content, and use
  `/admin` to approve/revoke keys and watch per-key usage.
- **Abuse control** is built in: per-IP registration limits and per-key push limits (both env-tunable),
  plus a `pending` approval gate (`RELAY_AUTO_ISSUE=false`) if you'd rather vet registrants.
- **Persistence** is a single SQLite file at `DB_PATH` - back up the `/data` volume to preserve issued
  keys across redeploys.

> Reusing this in another project? It's app-agnostic: point `APNS_BUNDLE_ID` at your app and have your
> backend speak the [`POST /push`](#http-api) contract (sealing payloads to match the device's key).

## Project layout

```
relay/
├── app/
│   ├── main.py       # FastAPI app: /push, /register, /admin*, the registration + admin HTML
│   ├── apns.py       # APNs HTTP/2 client: ES256 provider JWT, dead-token detection, retries
│   ├── db.py         # SQLite key store (hashes only) - issue/validate/list/approve/revoke/delete
│   ├── config.py     # .env.relay settings
│   └── ratelimit.py  # per-IP / per-key sliding-window limits
├── tests/            # test_relay.py
├── Dockerfile
└── pyproject.toml    # cleave-push-relay - fastapi · httpx[http2] · pyjwt[crypto]
```

## Testing

```bash
cd relay
uv run pytest        # or: pytest
```

## License

[GNU Affero General Public License v3.0](../LICENSE) - same as the rest of Cleave.

---

