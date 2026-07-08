# Contract: Deep links / URL routing

The URL shapes two clients must parse/emit identically to share invites and route pushes. Reference:
`ios/CleaveAPI/Sources/CleaveAPI/Logic/JoinLink.swift`, `NotificationTarget.swift`, `Views/RootView.swift`.
Fixtures: `fixtures/deep-links/` (join-link parse + reachability, notification-target parse).

## Join link (fixtured)

- Shape: `https://cleave.money/join?api=<backend>&name=<label>&invite=<code>` (Universal Link), or the
  `cleave://join?...` scheme form.
- `parse(url)` -> `{api, invite?}`; requires host `cleave.money` + path `/join` (or scheme `cleave`
  host/suffix `join`); a missing/empty `api` or any other URL -> null. The single-use `invite` rides
  through sign-in.
- `isPubliclyReachable(api)` rejects a backend that only resolves on the LAN: `localhost`, `127.0.0.1`,
  `*.local`, `*.lan`, and private ranges `192.168.` / `10.` / `172.` -> not reachable. (The invite UI
  warns when a link points at an unreachable backend.)

## Notification tap target (fixtured)

- `NotificationTarget(type, id)` from a push payload / inbox row `(entity_type, entity_id)`:
  `expense` / `transaction` / `account` / `goal` / `group` require a **valid UUID**; `friend` takes any
  non-empty string id; an unknown type, invalid UUID, or empty/nil -> null. Stable id string is
  `"type:value"`. On iOS the NSE injects the decrypted `target` into `userInfo`, and a tap routes to the
  matching detail view.

## Other routes (documented, not fixtured - they drive live OS/SDK flows)

- **Splitwise OAuth callback**: `cleave://auth?token=<jwt>` - the app extracts `token` from an
  `ASWebAuthenticationSession` redirect (callback scheme `cleave`).
- **Plaid OAuth resume**: `https://cleave.money/plaid/oauth` - app-handled (no backend route); resumes a
  live Link handler, or re-presents Link if the app was killed mid-flow.
- These are per-platform SDK flows (GoogleSignIn, Plaid LinkKit, ASWebAuthenticationSession) with direct
  cross-platform analogues; the **URL shapes** above are the portable contract.
