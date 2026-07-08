# Provider setup

Cleave authenticates users through **Apple / Google / Splitwise** and connects banks through **Plaid**. This
is the operator-side setup: creating the OAuth apps and setting the matching backend config. With all of these
left empty the backend runs in **open mode** (no auth, no bank linking) - fine for first-run and local dev.

How auth works: the backend **verifies** a provider token server-side, finds-or-creates/links the user, and
issues its **own stateless JWT** (HS256, ~90-day). The app stores that JWT and sends
`Authorization: Bearer <jwt>` on every request. Apple/Google/Splitwise are only ever verified, never trusted
directly, and the backend never stores a provider password.

Set everything below in `.env` (see `.env.example`). Enforcement is controlled by `AUTH_REQUIRED`
(`false` = open; `true` = a valid token is required on guarded endpoints). `AUTH_JWT_SECRET` signs the
sessions - generate it with `openssl rand -hex 32`; rotating it revokes every session.

- [Sign in with Apple](#sign-in-with-apple)
- [Google Sign-In](#google-sign-in)
- [Splitwise](#splitwise)
- [Plaid](#plaid)
- [Config reference](#config-reference)

---

## Sign in with Apple

Native iOS sign-in verifies the identity token against Apple's public JWKS (RS256) - **no client secret or
Services ID is needed** (those are only for the web redirect flow, which Cleave doesn't use). The backend
only needs the audience.

1. **Apple Developer → Certificates, Identifiers & Profiles → Identifiers →** your app's App ID (e.g.
   `money.yourcompany.cleave`) → enable **Sign in with Apple** → Save.
2. In **Xcode**, add the **Sign in with Apple** capability to the app target.
3. Set `APPLE_AUDIENCE` to the bundle id.

For Universal Links (the join link / AASA) also set `APPLE_TEAM_ID` to your Apple Developer Team ID - the
backend serves `/.well-known/apple-app-site-association` built from `<APPLE_TEAM_ID>.<APPLE_AUDIENCE>` and
returns 404 until it's set.

## Google Sign-In

The iOS OAuth **client id** is the token audience; no server secret is needed for ID-token verification.

1. **Google Cloud Console** → create or select a project.
2. **APIs & Services → OAuth consent screen** → External; set app name + support email; scopes `openid`,
   `email`, `profile`; add test users (or publish).
3. **APIs & Services → Credentials → Create credentials → OAuth client ID → Application type: iOS** → set the
   bundle id.
4. Copy the generated **iOS client ID** (`...apps.googleusercontent.com`) into `GOOGLE_CLIENT_ID`.

## Splitwise

Splitwise doubles as a sign-in provider **and** the bridge for shared groups. Register a Splitwise app to get
an OAuth2 consumer key/secret.

1. Create an app at Splitwise's developer portal (**Register your application**) to obtain a **Consumer Key**
   and **Consumer Secret**.
2. Set the callback / redirect URL to `https://your-host.example.com/auth/splitwise/callback` (or
   `http://localhost:8000/auth/splitwise/callback` for local dev).
3. Set `SPLITWISE_CONSUMER_KEY`, `SPLITWISE_CONSUMER_SECRET`, and `SPLITWISE_REDIRECT_URI` accordingly.

Sign-in flow: the app opens `GET /auth/splitwise/login` in `ASWebAuthenticationSession` → consent →
`GET /auth/splitwise/callback` redirects to `cleave://auth?token=<jwt>`, which the app catches.

## Plaid

Plaid links bank accounts and syncs transactions (server-side only - the app talks to Plaid solely through the
Link SDK during account linking). The **Development** tier (~100 items) is typically sufficient and free for
personal use; **Production** requires Plaid's approval.

1. Create a **Plaid** account and get your `client_id` + secret from the dashboard.
2. Set `PLAID_CLIENT_ID`, `PLAID_SECRET`, and `PLAID_ENV` (`sandbox` / `development` / `production`).
3. For production/OAuth banks, register `https://your-host.example.com/plaid/oauth` as an allowed **redirect
   URI** in the Plaid dashboard and set it as `PLAID_REDIRECT_URI`. (Leave blank for sandbox / non-OAuth - an
   unregistered value breaks *all* link tokens.) The iOS app handles that redirect as a Universal Link (the
   AASA also covers `/plaid/oauth*`).

Link flow: the app requests a link token (`POST /plaid/link-token`), runs Plaid Link, and exchanges the public
token (`POST /plaid/exchange`); the backend stores the encrypted access token and syncs via
`/transactions/sync`.

## Config reference

| Key | Purpose |
| --- | --- |
| `AUTH_JWT_SECRET` | HS256 session-signing secret. `openssl rand -hex 32`. Rotating it revokes all sessions. Required (≥32 chars) when `AUTH_REQUIRED=true`. |
| `AUTH_REQUIRED` | `false` (open) or `true` (enforce a valid token on guarded endpoints). |
| `APPLE_AUDIENCE` | The iOS app **bundle id** (e.g. `money.yourcompany.cleave`) - the Apple identity-token audience. |
| `APPLE_TEAM_ID` | Apple Developer Team ID - used to serve the AASA for Universal Links. |
| `GOOGLE_CLIENT_ID` | Google OAuth **iOS** client id (`...apps.googleusercontent.com`) - the ID-token audience. |
| `SPLITWISE_CONSUMER_KEY` / `SPLITWISE_CONSUMER_SECRET` | Splitwise OAuth2 app credentials. |
| `SPLITWISE_REDIRECT_URI` | Splitwise OAuth callback (`https://<host>/auth/splitwise/callback`). |
| `PLAID_CLIENT_ID` / `PLAID_SECRET` | Plaid API credentials. |
| `PLAID_ENV` | `sandbox` / `development` / `production`. |
| `PLAID_REDIRECT_URI` | OAuth redirect for production banks (`https://<host>/plaid/oauth`); blank for sandbox. |
| `ENCRYPTION_KEYS` | JSON list of Fernet keys encrypting Plaid/Splitwise tokens at rest (first encrypts, any decrypts → rotatable). Empty = plaintext (dev only). |
| `ADMIN_USERS` | JSON list of identifiers granted admin (Server Settings, Backups, Invites). |

Generate a Fernet key for `ENCRYPTION_KEYS`:

```bash
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```
