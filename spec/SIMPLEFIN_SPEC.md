# Spec: SimpleFIN aggregator + pluggable provider choice

## Why

Add **SimpleFIN** as a second bank aggregator alongside Plaid, and make the "connect a bank" path
**pluggable** so a self-hoster (or the end user) can pick per account: Plaid / SimpleFIN / OFX-CSV import /
manual. SimpleFIN matters because it (a) removes the biggest self-host barrier - every self-hoster currently
needs their own Plaid production approval - with a simple token; (b) covers institutions Plaid doesn't,
including Fidelity; and (c) fits the "you own your data" ethos (a read-only, user-held credential). The model
is already provider-agnostic (`TransactionSource` enum, per-account external-id dedup), so this is additive.

## SimpleFIN protocol (the facts we build to)

Ref: <https://www.simplefin.org/protocol.html>. Consumer flow:

1. User pastes a **setup token** (a base64 of a URL `<root>/claim/<token>`).
2. Base64-decode -> `POST` that claim URL -> body is an **Access URL** with embedded Basic-Auth creds
   (`https://user:pass@host/...`). 200 = ok, 403 = invalid/already-claimed. **Store the Access URL encrypted.**
3. Poll: `GET <access_url>/accounts?start-date=<epoch>&pending=1&version=2` -> an **Account Set**. Date range
   capped at **90 days** per request. 200 ok, 402 payment-required, 403 auth-failed.

Account Set (v2): `{ errors[], accounts[] }`. Each **account**: `id`, `name`, `currency` (ISO or URL),
`balance` (numeric string), `available-balance?`, `balance-date` (epoch), `org { name, domain, url, id }`,
`transactions[]`, `extra`. Each **transaction**: `id` (unique *within an account*), `posted` (epoch; 0 if
pending), `amount` (numeric string), `description`, `transacted_at?`, `pending?`, `extra`.

Two facts that drive the mapping:
- **Amount sign is inverted vs Cleave.** SimpleFIN: `+` = deposit/inflow, `-` = withdrawal/outflow. Cleave's
  `Transaction.amount` is `+` = outflow, `-` = inflow. **Negate on import.** (Cover with a test.)
- **Dedup = `(account, transaction.id)`.** Maps exactly onto the existing per-account partial-unique index
  `(account_id, external_transaction_id)` used for OFX FITID - **reuse it**, no new column.
- **One access URL spans many institutions.** Unlike a Plaid *item* (one institution), a SimpleFIN connection
  can return accounts across several orgs, each account carrying its own `org`. So **institution branding is
  per-account** (from `account.org`), and the connection is just the credential holder.

## Part A - SimpleFIN backend integration

Mirror the Plaid shape (`app/integrations/plaid/{client,sync,mapper}.py`, `app/routers/plaid.py`,
`app/services/sync.py`), but simpler: no OAuth, no link token, no cursor.

### Data model (migration 0060)
- `TransactionSource` (`app/models/enums.py`) += `simplefin`. NB it IS a Postgres enum type
  (`Enum(TransactionSource, name="transaction_source")`), so the migration must `ALTER TYPE ... ADD VALUE`
  inside an `op.get_context().autocommit_block()` (a new value can't be added-and-used in one transaction).
- **New `SimpleFinConnection`** (`app/models/simplefin_connection.py`), parallel to `PlaidItem`:
  `id`, `owner_identifier`, `access_url: EncryptedString` (holds Basic-Auth creds - encrypt like
  `PlaidItem.access_token`), `status` / `error` (e.g. `HEALTHY` / `NEEDS_REAUTH` on 403), `last_synced_at`,
  timestamps, `accounts` relationship. **No cursor** (date-window sync). **No institution fields** (branding is
  per-account).
- **`Account`** (`app/models/account.py`) gains: `simplefin_connection_id: UUID|None` (FK, SET NULL) and
  `simplefin_account_id: str|None`, with a unique index on `(simplefin_connection_id, simplefin_account_id)`
  (the account upsert key). Institution branding reuses the existing `institution_name`/`institution_domain`
  columns, filled from each SimpleFIN `account.org`. Manual/OFX accounts leave all provider FKs null.
- **`Transaction`**: no new columns. `source = simplefin` (distinct from `plaid` and `manual`). Dedup via the
  existing per-account `external_transaction_id`. This can't collide with OFX even though OFX reuses the same
  column, because (a) an account has exactly one source - OFX find-or-creates a *manual* account
  (`source=manual`, `simplefin_connection_id` null) while SimpleFIN txns live on a `simplefin_connection_id`
  account - and (b) the index is scoped by `account_id`. NB: OFX imports are stored as `source=manual`
  (`statements.py:161`) - there is no distinct `ofx`/`statement` source, so today `source` alone doesn't
  separate imported-from-statement from hand-typed. The authoritative per-txn provider signal is the
  *account's* linkage (`plaid_item_id` / `simplefin_connection_id` / neither); `source=simplefin` is what the
  sync + SmartRefresh key on to treat a row as aggregator-owned (refresh/reap it) rather than a user's manual row.

### `app/integrations/simplefin/`
- **`client.py`** (httpx; injectable like `PlaidClient` so tests use a fake):
  - `claim(setup_token: str) -> str` - base64-decode -> `POST` claim URL -> return Access URL. Raise a typed
    error on 403.
  - `fetch_account_set(access_url, start_date: int, pending=True) -> dict` - `GET .../accounts` with the URL's
    Basic-Auth, params `start-date`, `pending=1`, `version=2`. Map 402/403 to a typed "needs reauth / payment"
    error the sync records on the connection.
- **`mapper.py`**: SimpleFIN account -> `{simplefin_account_id, name, currency, balance, available_balance,
  institution_name=org.name, institution_domain=org.domain}`. SimpleFIN txn ->
  `{external_transaction_id=id, description, amount = -Decimal(amount) (NEGATE), currency, date =
  epoch->date(transacted_at or posted, device tz per the date-only rule), pending}`. `category = None` (no
  SimpleFIN categories -> resolved by the same on-device path as OFX imports).
- **`sync.py`** (mirrors `plaid/sync.py:apply_sync` + `sync_item`):
  - **Initial backfill** (first sync of a new connection): page BACKWARD in 90-day windows -
    `[now-90d, now]`, then `[now-180d, now-90d]`, ... - until reaching the SAME depth Plaid uses
    (`plaid_transactions_days_requested`, default 730d = 24mo) OR a window returns zero transactions (data
    exhausted for that account). Gives history parity with a freshly-linked Plaid item despite SimpleFIN's
    90d-per-request cap; it's just N sequential calls, on first link only.
  - **Incremental sync** (every run after): one window, `start_date = last_synced_at - ~5d overlap` (re-pulls
    recent rows to catch late edits + pending->posted).
  - Either path, per account: upsert account `ON CONFLICT (simplefin_connection_id, simplefin_account_id)`
    (balance/name/currency/available/institution_*), upsert txns `ON CONFLICT (account_id,
    external_transaction_id)` (description/amount/date/pending) - never touching user-override tables (same
    guarantee as Plaid).
  - **Pending reap** (no SimpleFIN "removed" list): delete `pending=true` rows in these accounts whose
    `external_transaction_id` was absent from the latest window and are older than a small grace (mirrors
    `plaid/sync._carry_pending_data` + the iOS `reapStalePending`). Carry-forward of user data is best-effort
    (SimpleFIN id stability varies by org; if a pending posts under a new id, treat as new + reap the old).
  - Stamp `last_synced_at` + status; commit; post-commit budget eval (reuse the Plaid hook).
  - `resolve_logo(account)`: pre-warm the `/logos` favicon from `account.org.domain` (best-effort, like
    `plaid/sync.resolve_institution`'s logo seed).

### Routers `app/routers/simplefin.py`
- `POST /simplefin/connect {setup_token}` -> `claim` -> create `SimpleFinConnection` (owner=caller) ->
  `sync_connection` (initial pull) -> `{connection_id, status, error, accounts:[AccountResponse], warnings}`.
  **Cross-provider dup guard (advisory, tiered):** each SimpleFIN account's `org` is resolved through the
  shared OFX institution catalog (`institutions.resolve` - name-first, then registrable domain) so its
  `institution_domain` canonicalizes to the same value OFX/Plaid store. The guard then tiers on the same signal
  the OFX importer uses: institution + a last-4 mask (best-effort-extracted from the SimpleFIN account name,
  since SimpleFIN has no mask field) = a strong "you already have this" warning; institution-domain only = the
  soft advisory. Never auto-merges (a wrong merge mid-sync would drop an account); the user deletes a true dup.
- `POST /simplefin/sync {connection_id?}` -> sync caller's connection(s). Copy `/plaid/sync`'s per-connection
  `with_for_update` lock + per-connection try/except isolation + stats aggregation + 502-if-all-fail.
- `GET /simplefin/connections` -> caller's connections (+ accounts eager-loaded).
- `DELETE /simplefin/connections/{id}` -> self-owned; delete accounts+txns (cascade) + connection. No remote
  revoke (the user revokes at the Bridge); just drop the stored Access URL. Reuse the receipt-object cleanup
  from `plaid.delete_item`.

### Quota - the hard constraint
SimpleFIN expects **<= ~24 `GET /accounts` requests/day**; exceeding the warning level does not throttle - it
**DISABLES the access token**. So a shared `is_stale(conn, threshold)` gates BOTH the scheduler and the manual
`/simplefin/sync`: a connection synced within `refresh_simplefin_stale_minutes` is skipped without a request.
The one-time backfill (~9 windows for 730d) is within the setup leeway they allow; incremental is one request.
Also: SimpleFIN returns warnings in the `errlist`/`errors` array of a *successful* body (quota warnings land
here BEFORE the disable) - the sync captures them onto `connection.status`/`error` and the response `warnings`,
and the app must show them (the docs require it).

### Scheduler + config
- `app/services/sync.py:sync_all` += `sync_all_simplefin(session)` (per-connection `skip_locked` lock +
  isolation), gated on `is_stale`.
- Server settings (registry-default, no migration): `simplefin_enabled: bool = True` and
  `refresh_simplefin_stale_minutes: int = 720` (12h - SimpleFIN refreshes ~daily, and the gate protects the
  quota, not just a wasted call). Add to the `ServerSettings` schema (response + update) + `ServerSettingsView`.
- **No app-level SimpleFIN creds** - the per-user Access URL lives in the DB. Nothing in `.env`.

## Part B - Pluggable provider choice

### Backend seam (pragmatic, matching the codebase)
- No formal `AggregatorProvider` protocol: the codebase doesn't use one for Plaid/Splitwise either -
  `sync_all` just calls each provider's `sync_all_*(session)`. So pluggability = `sync_all` also calling
  `sync_all_simplefin` + the capability flags below + the account-level linkage. The provider-specific link
  routers stay separate (link semantics differ too much to merge). (A protocol can be extracted later if a
  3rd provider lands; forcing it now would be the only place in the code using that abstraction.)
- `Account.provider` helper property: `plaid` if `plaid_item_id`, `simplefin` if `simplefin_connection_id`,
  else `manual`.

### Capabilities on `/server-info` (the one new client-facing seam)
- Add to `ServerInfo` (`app/schemas/public.py` + `app/routers/public.py`, exactly like the recent
  `push_configured`): `plaid_configured: bool` (creds set) and `simplefin_enabled: bool`. (Statement import +
  manual are always available.) iOS reads them into `AppEnvironment` (`plaidConfigured`, `simplefinEnabled`)
  next to `serverIsDemo`/`serverHasPush`.

### iOS
- **`SimpleFinRepository`** (mirror `PlaidRepository`): `connect(setupToken)` -> `POST /simplefin/connect`;
  `sync(connectionId?)` -> `POST /simplefin/sync` then `refreshAccounts`/`refreshTransactions` +
  `reapStalePending` (reuse the Plaid post-sync path); `listConnections`, `delete`. Wire
  `AppEnvironment.simplefin(context)`.
- **`SimpleFinLinkView`**: a plain sheet - a paste field ("Paste your SimpleFIN setup token"), a Connect
  button -> `connect(...)` -> dismiss + refresh. No SDK, no OAuth handler (unlike `PlaidLinkView` /
  `PlaidLinkSession`). Link to the Bridge (<https://beta-bridge.simplefin.org>) for getting a token.
- **Provider picker**: replace the single `Button("Link Bank")` at `ManageAccountsView.swift:114`,
  `AccountsView.swift:155`, `SettingsView.swift:168` with a small menu of the *available* methods, gated on
  the new capability flags:
  - "Connect a bank (Plaid)" - if `plaidConfigured` (existing `PlaidLinkView`).
  - "Connect via SimpleFIN" - if `simplefinEnabled` (new `SimpleFinLinkView`).
  - "Import a statement" - existing OFX flow (`/statements/import`).
  - "Add manual account" - existing `NewAccountView`.
- **`SmartRefresh`** (`Logic/SmartRefresh.swift`): dispatch per account's provider - a Plaid-linked account
  syncs via `/plaid/sync` on `refresh_plaid_stale_minutes`; a SimpleFIN one via `/simplefin/sync` on
  `refresh_simplefin_stale_minutes`.
- Regenerate the OpenAPI client (`export_openapi.py` -> `prepare_openapi.py`) for the new schemas.

## Testing
- Backend (mock the SimpleFIN client, like Plaid's injectable `fetch_page`): `claim` parses a setup token;
  sync upserts accounts + txns; **amount is negated**; dedup on `(account, external_id)`; date-window +
  90-day floor; pending reap; 402/403 -> connection status. A golden fixture of a real-shaped Account Set.
  Extend `test_server_info` for the new capability flags; `test_server_settings` for the two new keys.
- iOS: `SimpleFinLinkView` connect happy-path; the provider menu shows only available methods; SmartRefresh
  routes to the right endpoint per provider.

## Effort
- **SimpleFIN backend: M** (~2-3 days) - module + model + migration 0060 + router + sync + scheduler wiring +
  tests. Simpler than Plaid (no OAuth/link-token/cursor).
- **Pluggable seam + capabilities: S** - the provider protocol + two `/server-info` fields.
- **iOS: S-M** - `SimpleFinLinkView` + repository + the provider menu + SmartRefresh dispatch + client regen.

## Open decisions / risks
- **Amount sign** (negate) - single biggest correctness risk; test first.
- **History parity** (resolved) - the initial backfill pages backward in 90-day windows to Plaid's depth
  (`plaid_transactions_days_requested`, default 730d), stopping early on an empty window. N sequential calls
  on first link only; incremental syncs are a single short window.
- **Cross-provider duplicate accounts** - SimpleFIN can return a card the user already linked via Plaid or
  imported via OFX. Reuse the OFX importer's `owner + mask + institution_domain` guard on connect so it isn't
  duplicated (see the connect endpoint). Same dedup keys don't cross sources, so without the guard you'd get
  two account rows + doubled transactions.
- **Access URL is permanent** until the user revokes at the Bridge. On `403`, set the connection
  `NEEDS_REAUTH` and prompt a re-paste (there's no refresh token).
- **Pending reap without a "removed" list** - reap by absence-in-window + age; accept best-effort carry-forward.
- **`simplefin_enabled` default** - proposed `True` (no creds needed); flip off to hide the option. Confirm.
