# Contract: Out-of-cache state

What must survive the disposable cache being wiped (on sign-out / server-switch / schema mismatch).
Reference: `ios/CleaveAPI/Sources/CleaveAPI/Networking/KeychainTokenStore.swift`, `PushKeychain.swift`,
`Repositories/Preferences.swift`, `CategorySync.swift`, `SuggestionSync.swift`, `AppEnvironment`.

## Secrets (secure storage, per server)

- **Per-server bearer token** - stored keyed by a normalized server key (lowercased scheme+host+port,
  trailing slash stripped), so dev/prod/demo keep separate sessions and a token is only ever sent to
  the server that minted it. Not wiped by a cache erase; cleared per-server on sign-out.
- **E2E push keypair** - the device's static P-256 key-agreement private key, in shared (App-Group)
  secure storage so the notification extension can read it while locked (see `extensions.md`). Public
  key registered via `POST /devices`.

## Preference watermarks (apply-if-newer)

- User preferences (editable category taxonomy, split templates + dismissals + subscription rules, tab/
  goal order, link sensitivity, brand guesses/overrides, notification prefs) sync as opaque per-owner
  JSON blobs via `GET /preferences` / `PUT /preferences/{key}`, each backed by a **`<key>.syncedAt`
  watermark** and last-write-wins **"apply if the server copy is newer than my watermark."**
- **All watermarks are reset when the cache is wiped**, so a re-installed device re-restores from the
  server (otherwise apply-if-newer would think it's up to date and silently lose data).

## The `PreferenceSyncGate` rule (load-bearing)

- **No store may push a preference until this session's launch restore has run its apply-if-newer sweep
  and marked itself restored.** This prevents a not-yet-restored device from `PUT`-ing an empty/stale
  blob over the fuller server copy - the exact clobber this gate was added to fix (2026-07-07). A port
  that syncs preferences MUST implement this gate, plus the extra guard that a freshly-seeded device
  with only built-in categories never `PUT`s over real server data.

## Not persisted

- **Idempotency keys** are minted per create form as a transient value carried only for that one
  request; never stored.
- The **delta cursor** (`SyncCursor`) *is* inside the cache, so it's wiped too - after a wipe the client
  relies on a full reconcile (not a stale cursor), which is correct (see `sync.md`).
