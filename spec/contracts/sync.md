# Contract: Sync / wire semantics

The behaviors around the HTTP/OpenAPI surface that the schema does not state but every client must
honor. Reference: `ios/CleaveAPI/Sources/CleaveAPI/Repositories/*`, `Networking/*`, `AppEnvironment`.

## Cache model

The local store is a **disposable mirror** of the server. On any schema mismatch the whole store is
rebuilt and re-synced; sign-out / server-switch wipes it. The server is the sole source of truth.
Anything that must survive a wipe lives outside the cache (see `out-of-cache-state.md`).

## Delta cursor (`updated_since`)

- List endpoints accept an optional `updated_since` timestamp; the client stores one cursor per
  collection (last successful sync time) and passes it to fetch **only creates/updates**.
- **Invariant: `updated_since` never reports deletes.** A client that treats a delta response as
  authoritative for deletions will silently accumulate stale rows forever. Deletes are caught only by
  the periodic full reconcile below.
- Timestamps are ISO-8601; the wire may carry Postgres **microsecond** precision. Clients must accept
  microseconds (iOS normalizes the fractional part to exactly 3 digits before decoding, because the
  default transcoder rejects microseconds). Fixtures: none here (a date-transcoder fixture is a
  candidate follow-up); the rule is stated so a port doesn't reject valid server timestamps.

## Reconciliation (upsert-in-place, never delete-and-reinsert)

- Responses are **upserted by `id`**: an existing row is mutated field-by-field in place; a new row is
  inserted. **Never delete-and-reinsert** a row that live views may hold (it invalidates the object and
  crashes SwiftData; a port over any observable store should preserve object identity the same way).
- To-many children (splits, items, receipts, transaction items) are reconciled by `id`: matched
  children updated in place, new inserted, missing deleted.
- **Periodic full reconcile**: a full (cursor-less) fetch of a collection, upsert, then delete every
  local row whose id is not in the returned set - this is what removes server-side deletes. Guarded so
  a **partial/paged fetch never prunes** (only a full unfiltered fetch may delete).

## Cost-aware refresh

- Pull-to-refresh decides between an **expensive live provider sync** and a **cheap local reconcile**
  based on server-set freshness thresholds, keyed **by provider** (not screen): Plaid default 60 min,
  Splitwise default 15 min (`0` = always sync). Plaid costs money, so it syncs less often than free
  Splitwise. Stale = `freshness == nil || threshold <= 0 || age >= threshold`.

## Idempotency

- `POST /expenses` and `POST /transactions` accept an optional `Idempotency-Key` header (a UUID minted
  once per create form). A repeated key returns the original entity - no second row, no second
  Splitwise push. The key is carried per-request (task-local on iOS) so it never leaks onto other
  requests sharing the client. All reads/updates/deletes are unaffected.

## Errors / retries

- No automatic retry layer: retries are user-driven (pull-to-refresh) and idempotency-key-safe.
  Non-2xx maps centrally to typed errors (422 validation, 409 conflict, 502 upstream, 404 not-found).
  Concurrent bulk operations swallow per-item 404s so one stale row doesn't fail a batch.

## Auth

- A per-server bearer token is attached as `Authorization: Bearer <jwt>` when present; **no-op when
  absent** (the backend runs in open mode until auth is enabled). The token is scoped per server (see
  `out-of-cache-state.md`) and never sent to a server that didn't mint it.
