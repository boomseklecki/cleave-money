# Porting / Rebuild Architecture Spec

> Planning document. No code, no scaffolding - a decision record for two independent
> tracks. Written against the current architecture as described in the repo, backend,
> iOS, and relay READMEs. Product name is **Cleave**; repo codename is `splitback`.

## What this is deciding

Cleave today is a self-hosted, two-user personal-finance and expense-splitting system with
three deployed pieces:

- **Backend** - FastAPI (async) + Postgres 16 + MinIO, `uv`-managed, run as a Docker Compose
  stack (default + dev/demo/test profiles), exposed via a Cloudflare Tunnel (or Tailscale),
  with restic off-device backups and an in-process scheduler.
- **iOS app** - SwiftUI + SwiftData, offline-first, targeting iOS 26+. Almost all logic lives
  in one Swift package (`CleaveAPI`): ~57 files of pure on-device computation, ~31 repositories
  that reconcile server responses into a disposable SwiftData cache via an `updated_since`
  delta cursor, a generated `swift-openapi-generator` client, Apple **Foundation Models** for
  on-device receipt extraction / category refinement / merchant resolution, VisionKit scanning,
  and **CryptoKit** ECIES for end-to-end-encrypted push.
- **Push relay** - a standalone, blind APNs forwarder (FastAPI + SQLite) that never sees
  plaintext when E2EE is on.

Two tracks are on the table, and they are **largely independent** because the client/server
boundary is a versioned HTTP + OpenAPI contract. Track interactions are called out at the end
- they exist, but neither track blocks the other.

- **Track 1** - take the iOS-only client to (a) a web client and (b) a cross-platform native
  client, starting from the current Swift codebase.
- **Track 2** - move the backend off the Docker runtime to a more portable, rootless-friendly
  runtime, for portability and to shed Docker's security model (not for performance).

---

# Track 1: Client - iOS to web + cross-platform native

## 1.1 The porting surface: what the current app actually is

The mistake to avoid is treating "the iOS app" as one monolith to reimplement. It decomposes
into three layers with very different portability:

| Layer | Current form | Portability |
| --- | --- | --- |
| **Business logic** | ~57 `Logic/` files: split math (integer cents), category taxonomy + precedence chain, subscription/cadence detection, unified spend engine (dedup of split share vs card charge), transaction-match scoring, brand-name normalization | **Pure and portable.** No UI, no OS APIs. This is the crown jewel and the thing most expensive to get subtly wrong twice. |
| **Platform capabilities** | Foundation Models (on-device AI), VisionKit (scan), CryptoKit (ECIES push), Keychain (per-server tokens), LocalAuthentication (Face ID lock), APNs registration, background sync | **Per-platform.** Each needs a mapped equivalent or a declared fallback. This is where "cross-platform" gets expensive, not the UI. |
| **UI** | 91 SwiftUI view files, Swift Charts | **Reimplement or share depending on framework choice.** The cheapest layer to redo and the one users judge; also the one where a shared toolkit can either save or cost the most. |
| **Sync / cache** | SwiftData mirror + repositories, `updated_since` cursor, upsert-in-place reconciliation, disposable-store-on-schema-mismatch | **Design is portable, implementation is not.** SwiftData has no cross-platform twin; the *reconciliation protocol* (delta cursor, upsert by id, periodic full reconcile) is what ports, re-expressed on another local store. |

The single most important architectural fact for this track: **the server is the source of
truth and the client is a disposable cache over an HTTP/OpenAPI contract.** That is what makes
new clients feasible at all - a web or Android client is "another cache," not a second system
of record. It also means the hard correctness surface (balances, dedup, taxonomy) is already
mirrored and parity-tested against the backend, so a new client has an executable spec to
conform to rather than a blank page.

## 1.2 On-device AI: the load-bearing constraint

Cleave's stated trust principle is "all the intelligence runs on your device ... there is no
AI backend and nothing is ever sent to an LLM." On iOS this is delivered by Apple Foundation
Models with a deterministic fallback. Porting this is the crux of Track 1, because the
equivalent capability is **strong on iOS, emerging-but-real on Android, and effectively absent
on the web.**

| Platform | On-device receipt extraction path | Reality (mid-2026) |
| --- | --- | --- |
| **iOS 26+** | VisionKit scan → Foundation Models `@Generable` struct | Shipping today. The reference behavior. |
| **Android** | ML Kit **Document Scanner** + **Text Recognition** (OCR, deterministic, ships on essentially all devices) → **ML Kit GenAI Prompt API** (Gemini Nano) for structuring the OCR text into merchant/date/items | OCR is dependable and universal. The *LLM structuring* step (Gemini Nano via ML Kit GenAI) is real but **device-gated** - best on Pixel 8+/flagships (Pixel 10 runs nano-v3) and still Alpha as of late 2025. So Android gets true on-device extraction on capable devices and must fall back to **OCR + deterministic parsing** on the rest. [1][2] |
| **Web** | Chrome built-in **Prompt API** (Gemini Nano, WebGPU) exists (Chrome 138+, origin trial, ~4 GB VRAM, image input emerging) but is **Chrome-desktop-only**, not in Safari/Firefox, and unreliable on mobile browsers | Not a dependable cross-browser capability. For a web client, on-device LLM extraction is **not viable as a shipped feature.** [3] |

The design implication is sharper than "pick a library." The trust principle is
**tiered by platform**, and the spec should say so explicitly rather than pretend parity:

- **iOS**: on-device LLM extraction (unchanged).
- **Android**: on-device OCR everywhere; on-device LLM structuring on capable devices; deterministic
  parse as the floor. Still "nothing leaves the device" - the promise holds, the sophistication varies.
- **Web**: OCR-in-browser (WASM, e.g. Tesseract-class) + deterministic parse is the only path
  that *keeps* the on-device promise; it is materially weaker than the LLM path. The tempting
  alternative - **server-side extraction** - is fast and accurate but **breaks the central design
  principle** ("no AI backend, nothing sent to an LLM"). See 1.4.

## 1.3 Cross-platform native framework options

Evaluated specifically against this app's four hard requirements: (1) reuse the pure logic layer,
(2) map on-device AI, (3) map CryptoKit ECIES push, (4) offline-first local store + reconciliation.

### Kotlin Multiplatform (+ optional Compose Multiplatform) - **shared logic, native or shared UI**
- **Logic reuse**: Strong. The `Logic/` layer is pure algorithms; reimplementing it *once* in
  Kotlin `commonMain` and sharing it to Android + iOS (and JS via Kotlin/JS or Wasm) means one
  parity-tested source instead of N. This is the highest-value option for the crown-jewel layer.
- **AI**: `expect`/`actual` - `actual` on Android = ML Kit GenAI / ML Kit OCR; `actual` on iOS =
  bridge to Foundation Models. Clean seam, honest per-platform behavior.
- **Crypto**: P-256 ECDH → HKDF → AES-256-GCM maps cleanly. Either `expect`/`actual` to CryptoKit
  (iOS) and Android Keystore/Tink (Android), or a KMP crypto library (e.g. `cryptography-kotlin`)
  that implements all three primitives across targets. Private key in Secure Enclave (iOS) /
  StrongBox-or-TEE-backed Keystore (Android).
- **UI**: choose per-platform native UI (SwiftUI on iOS, Compose on Android - maximum fidelity,
  double the UI work) **or** Compose Multiplatform, which went **Stable for iOS in May 2025** (CMP
  1.8.0) and is in production at Netflix/Cash App. CMP on iOS is now a real option, but renders its
  own UI (not native SwiftUI controls) - an aesthetics/accessibility tradeoff to weigh for a
  polished finance app whose current selling point is native feel.
- **Verdict**: Best fit for *sharing the logic layer* while keeping iOS native. The pragmatic
  sweet spot is **KMP for logic + native SwiftUI (kept) + native Compose (new Android UI)**, with
  CMP considered only if UI-maintenance cost dominates.

### Flutter - **single codebase, own rendering**
- **Logic reuse**: Reimplement in Dart. No sharing with the existing Swift or a future Kotlin core -
  a third implementation of split math to keep in parity. That is the main strike against it here.
- **AI**: Platform channels to ML Kit (Android) / Foundation Models (iOS); community packages exist
  (e.g. Gemini Nano wrappers) but you own the bridge.
- **Crypto**: Dart `cryptography`/`pointycastle` cover ECDH-P256/HKDF/AES-GCM, or platform-channel to
  native. Secure key storage via `flutter_secure_storage` (Keychain/Keystore).
- **UI**: One UI for Android + iOS, Skia-rendered (non-native controls). Fast to build, consistent,
  but least "native-feeling" on iOS - a real cost for this product's positioning.
- **Verdict**: Fastest way to *one* new cross-platform app if you were greenfield. Weak fit as a
  *complement* to a kept native-iOS app, because it shares nothing with the existing code and adds a
  parallel logic implementation.

### React Native - **JS ecosystem, native views**
- **Logic reuse**: Reimplement in TS/JS. Same "third implementation" problem as Flutter, but the JS
  logic *could* be shared with a web client (see 1.4) - the one place RN's calculus differs.
- **AI**: Bridge/native modules to ML Kit and Foundation Models; less mature first-party story than KMP.
- **Crypto**: No dependable built-in subtle crypto; use `react-native-quick-crypto` or native modules.
  More friction to get the ECIES scheme byte-compatible with the backend's pinned interop vector.
- **UI**: Native views, good iOS feel, largest ecosystem/hiring pool.
- **Verdict**: Only compelling if a **shared TS logic core across RN + web** is the strategy. Otherwise
  KMP dominates it on logic-sharing and crypto ergonomics.

### .NET MAUI / others
- MAUI, Tauri (native shell over web), etc. are credible in the abstract but add a runtime with a
  smaller mobile-finance track record and no advantage on this app's specific constraints. Named for
  completeness, not recommended.

### The AI + crypto mapping, consolidated

| Capability | iOS (today) | Android | Web |
| --- | --- | --- | --- |
| Receipt OCR | VisionKit | ML Kit Text Recognition / Doc Scanner | WASM OCR (Tesseract-class) |
| Structured extraction | Foundation Models `@Generable` | ML Kit GenAI (Gemini Nano), device-gated → deterministic fallback | none dependable → deterministic or server (breaks principle) |
| Push crypto (ECDH P-256/HKDF/AES-256-GCM) | CryptoKit | Keystore + Tink/Conscrypt | Web Crypto `SubtleCrypto` |
| Push transport | APNs (via blind relay) | **FCM** (new relay path) | **Web Push / VAPID, RFC 8291** (different scheme, new relay path) |
| Secure key storage | Keychain / Secure Enclave | Keystore (StrongBox/TEE) | non-extractable `CryptoKey` in IndexedDB (weaker) |
| Biometric lock | LocalAuthentication | BiometricPrompt | WebAuthn (partial equivalent) |

Two rows deserve emphasis because they are often missed: **push transport is not portable.** APNs
is Apple-only, so Android needs an FCM path and web needs the standard Web Push protocol - each is a
*new relay capability*, not a client-only change (see Track interactions). The E2EE *envelope* (the
`{epk, box}` ECIES ciphertext) is portable across all three; the *delivery rail* under it is not.

## 1.4 Web client: PWA vs full web app, and what's lost

**Recommendation for web: a PWA (installable, service-worker, offline-capable), not a
thin server-rendered web app** - because offline-first is a core product property, and a PWA is
the only web form that preserves it. A traditional server-rendered app would discard the
disposable-local-cache model that defines the client.

What a web PWA **keeps**: the full HTTP/OpenAPI contract, the entire logic layer (re-expressed in
whatever the web client's language is), offline reads/edits via IndexedDB + service worker as the
SwiftData analogue, per-server bearer tokens, and the E2EE push *envelope* via Web Crypto.

What a web PWA **loses or weakens**, and the fallback for each:

- **On-device AI receipt extraction** - effectively lost (1.2). Fallbacks, worst-to-best for the
  trust principle:
  1. **In-browser OCR + deterministic parse** (WASM). Keeps "nothing leaves the device," but weaker
     than the LLM path and heavier to run in a browser. *Preserves the principle.*
  2. **Server-side extraction** (OCR/LLM on the backend). Accurate and easy, but introduces exactly
     the "AI backend" the product was built to avoid, and sends receipt content to the server for
     processing. **This is a principle-level decision, not an implementation detail.** If chosen, the
     honest framing is: on-device AI becomes an *iOS/Android premium capability and trust signal*,
     while web is explicitly a *reduced-trust convenience client* - and the marketing/UX must say so
     rather than imply parity. It also changes the backend's security and resource profile (now
     processing user images server-side), which is a Track-2 input (see interactions).
  3. **No receipt AI on web at all** - manual entry only. Cleanest for the principle, weakest UX.
  - *Spec recommendation*: web v1 ships **manual entry + optional in-browser OCR prefill**, and
    **does not** add a server-side extraction endpoint, so the "no AI backend" invariant survives
    intact. Revisit only as a deliberate, documented principle change.
- **Secure key storage** - IndexedDB non-extractable `CryptoKey` is weaker than Secure
  Enclave/StrongBox (no hardware backing, clearable by the browser). Acceptable for a cache client;
  document it.
- **Background push** - Web Push works but is less reliable than APNs/FCM (especially iOS Safari's
  constraints on installed PWAs) and uses a **different encryption/transport** (RFC 8291 + VAPID),
  so the relay needs a Web Push path. Treat web push as best-effort.
- **Biometric app-lock** - approximated with WebAuthn; not identical.

## 1.5 What's shared vs reimplemented

- **Shared across all clients (ideally one implementation):** the logic layer - split math,
  category taxonomy + precedence, subscription detection, spend-engine dedup, match scoring, brand
  normalization. Today it exists twice (Swift client + Python backend), pinned by parity tests. A
  third and fourth client (Android, web) should **not** each re-derive it. The strategic question is
  whether to (a) let each client reimplement against the parity tests, or (b) extract a single shared
  core (KMP `commonMain`, or a TS core for RN+web) and converge clients onto it. **(b) is the better
  long-term bet** precisely because this logic is subtle and financial; every reimplementation is a
  place for balances to silently diverge.
- **Reimplemented per platform (unavoidable):** UI, local persistence binding, AI capability
  adapters, crypto/keystore adapters, push registration, biometric lock. These are thin adapters
  behind stable interfaces if the logic core is shared; thick and duplicated if it is not.
- **Reused as-is (no client work):** the entire backend contract. New clients are generated OpenAPI
  clients against the same spec - the same discipline that keeps iOS honest.

## 1.6 Phasing

**v1 (recommended scope):**
- **Web PWA** as the first non-iOS client: read-heavy money/splits views, expense create/edit/settle,
  offline cache, per-server login, manual receipt entry (+ optional in-browser OCR prefill). **No**
  server-side AI. Best-effort Web Push. This is the fastest way to a second platform, validates the
  "contract as the only integration point" thesis, and forces the logic-core extraction question early
  and cheaply (no app-store gate, no device-capability matrix).
- Extract the **shared logic core** (KMP or TS) as part of, not after, building the web client - so the
  first port pays down the duplication rather than adding to it.

**v2:**
- **Android native** (KMP logic core + Compose UI), with tiered on-device AI (OCR everywhere, Gemini
  Nano where available, deterministic floor) and an **FCM relay path**. This is where the cross-platform
  native investment lands, reusing the v1 logic core.

**Deferred:**
- Compose-Multiplatform-shared UI (only if per-platform UI maintenance proves too costly).
- Server-side extraction / any "AI backend" (only as an explicit, documented principle change).
- Full-parity web push and web biometric lock.

## 1.7 Track 1 recommendation

**Ship a web PWA first, extract a shared logic core while doing it, then build Android native on that
core with KMP - and keep iOS native.** Do **not** adopt a single-codebase framework (Flutter/RN) that
would force a third parallel reimplementation of the financial logic; the correctness risk of divergent
split/balance math outweighs the UI-velocity gain. Frame on-device AI as a **tiered trust property**
(full on iOS, capability-gated on Android, OCR-only-or-manual on web) and refuse server-side extraction
in the default product so the "no AI backend" invariant holds.

**Tradeoffs accepted:** more total UI code than a single-toolkit approach; Android's on-device AI is
weaker on non-flagship devices; web loses the headline receipt-AI experience and hardware-backed key
storage; push is three transports, not one. **Tradeoffs rejected:** a fourth divergent copy of the
logic layer, and a server-side AI path that would quietly dissolve the product's central promise.

---

# Track 2: Backend - Docker to a portable, rootless-friendly runtime

## 2.1 Motivation (restated, to keep the evaluation honest)

The goal is **portability across hosts** and **moving off Docker's security model** (rootful daemon,
`docker.sock` attack surface) - explicitly **not** performance and **not** CM4 resource pressure. That
framing matters: it rules out "Docker is fine, just harden it" as a non-answer, and it means the bar for
an alternative is *security-model improvement + equal-or-better portability at equal operational cost*,
not raw speed.

## 2.2 The current runtime surface (what actually has to port)

From `docker-compose.yml`, the concrete things a new runtime must reproduce:

- **Images**: `postgres:16`, `minio/minio`, `tailscale/tailscale`, and two locally-built images
  (`./backend`, `./relay`, plus a thin `./cloudflared` wrapper) - all standard OCI images and Dockerfiles.
- **Named volumes**: `main_db`/`dev_db` (Postgres data, names interpolated for existing operators),
  `cleave_minio_data`, `cleave_db_data_demo`, `cleave_relay_data`, `tailscale_state`.
- **An internal service network** with DNS-by-service-name (`db`, `minio`, `relay`, `api`) and
  `depends_on` + healthchecks (`pg_isready`, `mc ready`).
- **Published ports** (8000-8003, 9000/9001) and **profiles** (default/dev/demo/test/tunnel/tailscale).
- **Bind mounts**: `./secrets/ssh` (restic sftp key, `root:root` 0600), `./cloudflared`, `./tailscale`.
- **Egress networking**: a **Cloudflare Tunnel connector** (or Tailscale `serve`, userspace mode - already
  chosen partly to avoid host `NET_ADMIN`) - i.e. **no inbound ports are opened on the host**; the tunnel
  dials out. This is important: the networking model is already daemon-of-a-different-kind, not host-port
  exposure.

Nothing here uses a Docker-proprietary feature. Everything is OCI images, named volumes, an internal
bridge network, and healthchecks - which is why a swap is plausible at all.

## 2.3 Options survey

### Podman (+ Quadlet) - the direct swap-in, and the recommended target
- **Rootless, daemonless, OCI-native.** `podman run` uses a fork-exec model: the container is a direct
  child of the invoking user's process, not of a long-lived root daemon. No `dockerd`, no root socket. [4][5]
- **Compose story, two layers:**
  - `podman-compose` (or Podman's Docker-API-compatible socket + real `docker compose`) runs existing
    compose files - useful for a low-friction first move, but **not 100% compatible**, and crucially
    **`restart: unless-stopped` semantics don't map** without a daemon, so nothing auto-restarts on
    reboot the way Compose implies. [6]
  - **Quadlet** (in-box since Podman 4.4) is the *native, production* answer: each container/volume/network
    becomes a **systemd unit**, so start-on-boot, restart policy, ordering, and logging are handled by
    systemd rather than a container daemon. This is strictly better than the compose `restart:` policy for
    a single-host self-hosted service - but it is a **translation of the compose file, not a drop-in**, and
    Quadlet has **no native healthcheck-as-dependency** the way compose `depends_on: condition:
    service_healthy` does, so the `db`-healthy-before-`api` ordering needs a systemd-level expression. [6][7]
- **Verdict**: the intended destination. `podman-compose` for the incremental cutover, Quadlet as the
  end-state.

### Docker rootless mode - the "keep Docker, drop rootful" option
- Rootless `dockerd` **exists and has matured** and gives most of the same benefits (no root daemon owning
  the host, container escape lands unprivileged, smaller attack surface). If the *only* goal were "stop
  running the daemon as root," this is the lower-effort path - the compose files barely change. [5]
- But it is **opt-in and less polished**: extra install steps, `slirp4netns` networking overhead, some
  network modes unavailable, privileged operations behave differently. And it **keeps a daemon** - a
  per-user `dockerd` is still a long-lived broker with a socket, just not root-owned. It does **not**
  advance the "daemonless / portability" half of the motivation. [1][5]
- **Verdict**: a valid *fallback* if Podman's ecosystem gaps bite, but it only satisfies one of the two
  stated motivations.

### Others, named for completeness
- **containerd + nerdctl**: OCI-native, `nerdctl compose` is quite Docker-compatible, rootless supported -
  but containerd is still a daemon, and this is more a Kubernetes-substrate path than a self-hosted-single-box
  one. No advantage over Podman for this use case.
- **systemd-nspawn / LXC**: system containers, not the app-container/OCI model; would mean re-architecting,
  not porting. Out of scope.
- **Kubernetes / k3s**: massive operational overinvestment for a two-user household service. Explicitly not.

## 2.4 Security: Docker vs Podman, current and specific

Stated precisely rather than as slogans (verified against current sources; see references):

- **Daemon attack surface.** Docker's defining exposure is `dockerd` running as **root** plus its Unix
  socket `/var/run/docker.sock`. Anything that can talk to that socket is effectively root on the host
  (it can mount the host filesystem into a container). Podman has **no such daemon and no such socket** in
  its default mode - `podman` is a CLI that forks the runtime directly, so there is no always-on privileged
  broker to compromise. This is the single biggest, most concrete difference. [1][4]
- **Rootless posture.** Podman is **rootless by default**: the container runs as the invoking user, PIDs
  inside map to the user's `subuid`/`subgid` range via user namespaces, and a container escape lands as an
  **unprivileged user**, not root. Docker *can* do rootless too, but it is **not the default** and requires
  deliberate setup - so in practice most Docker installs run rootful. The security delta in the real world
  is therefore as much about *defaults* as about capability. [1][5]
- **Default capabilities.** Podman ships a slightly tighter default capability set (~11) than Docker (~14),
  i.e. least-privilege out of the box. Minor but real. [1]
- **The honest caveats** (so this isn't a sales pitch):
  - Rootless is **not a security panacea.** It shifts the boundary; it doesn't remove kernel attack surface.
    User-namespace and `slirp4netns`/`pasta` networking have their own considerations, and a badly
    configured rootless container is still a risk.
  - Rootless imposes **real constraints**: binding host ports `<1024` needs configuration, some storage
    drivers and filesystem-ownership behaviors differ (`subuid`/`subgid` mapping means files written to
    volumes are owned by mapped UIDs - relevant to the restic **sftp key that must be 0600 and the Postgres
    data dir ownership**), and anything expecting host-level privileges needs rework.
  - The Cloudflare Tunnel model **already** avoids opening inbound host ports, so one classic rootful pain
    (privileged port binding) is largely sidestepped here - a point in favor of this particular migration.

Net: for a **single-host, self-hosted, two-user** box, Podman's daemonless + rootless-by-default model is a
**genuine, current security improvement** over the present rootful-Docker setup, and it directly serves the
stated motivation - with eyes open about the rootless filesystem-ownership friction around volumes and the
sftp key.

## 2.5 What changes vs what stays the same

**Stays the same:**
- **Dockerfiles / images.** OCI images build and run unchanged (`podman build`); Postgres/MinIO/Tailscale
  images are pulled as-is.
- **Postgres and MinIO data.** These are just directories in named volumes. Migration is a **volume/data
  move, not a reformat** - the same bytes, remounted. (Watch ownership under rootless UID mapping.)
- **The internal service-name networking model.** Podman networks give the same DNS-by-service-name.
- **Cloudflare Tunnel / Tailscale egress.** The connectors are just containers dialing out; they run under
  Podman the same way. **No change to the public networking model**, which is the part most likely to be
  fragile in a migration - and it isn't touched.
- **The app itself.** FastAPI, Alembic, `uv`, the relay - all runtime-agnostic.

**Changes:**
- **Orchestration definition.** `docker-compose.yml` → either `podman-compose` (minimal change, incremental)
  or **Quadlet systemd units** (end-state, more work, better boot/restart integration). The **profiles**
  (dev/demo/test/tunnel/tailscale) map to separate Quadlet unit sets or compose profiles.
- **Restart/boot semantics.** `restart: unless-stopped` → systemd `Restart=`/`WantedBy=` under Quadlet (this
  is an *upgrade* in reliability, but it's a rewrite of that behavior, not a copy).
- **Healthcheck-gated dependencies.** `depends_on: condition: service_healthy` has no direct Quadlet twin;
  the `db`-before-`api` ordering must be re-expressed (systemd ordering + a readiness wait), or kept in
  `podman-compose` where the compose semantics still apply.
- **Volume ownership / the secrets bind mount.** Under rootless UID mapping, the `./secrets/ssh` key
  (`root:root` 0600, which OpenSSH insists on) and the Postgres data dir need their ownership reconciled with
  the mapped user namespace - the most likely concrete snag in the cutover.
- **Socket-dependent tooling, if any.** Anything that reached for `docker.sock` (the docker-socket-proxy
  pattern noted in ops memory) has no rootless-Podman equivalent by default and must be reconsidered.

## 2.6 Migration path: incremental, not a cutover

This can and should be done **incrementally on a spare/second host** (the dedicated `splitback-host`
migration is already in motion), staged so nothing risky happens to the live data until the end:

1. **Prove images build and run** under rootless Podman (`podman build`, `podman run`) - app, relay, and
   the third-party images. No data involved.
2. **Bring up a full stack via `podman-compose`** against the existing compose file on the new host, using
   **dev/demo profiles and throwaway volumes**. This isolates "does Podman run our stack" from "does our
   data survive," and the dev/demo/test profiles exist precisely for this kind of low-stakes validation.
3. **Resolve the rootless snags** found in step 2 (volume ownership, sftp-key perms, healthcheck ordering,
   port binding) while nothing production depends on it.
4. **Convert to Quadlet** for the services you want systemd-managed (at least `db`, `minio`, `api`, `relay`),
   keeping the tunnel/tailscale connectors as units too. Validate boot/restart behavior.
5. **Data cutover last**: stop the old stack, move the Postgres and MinIO volumes (byte-for-byte), start the
   Podman/Quadlet stack, run `alembic upgrade head`, verify `/health` and `/health/db`, verify backups still
   run. Because backups are restic to an off-device target, there is a **tested rollback**: worst case, restore
   onto the old Docker host.

So: **incremental to build confidence, with a single short data-cutover window at the end** - not a big-bang
rewrite, and not a live in-place daemon swap.

## 2.7 Podman tradeoffs / ecosystem gaps to weigh

- **Compose is second-class.** `podman-compose` isn't 100% compatible and the no-daemon model changes
  restart semantics; the "real" Podman way (Quadlet) is a different mental model the operator must learn.
  For a household service run by one person, that learning cost is non-trivial and should be counted. [6]
- **Healthcheck-as-dependency gap** in Quadlet (2.5) - needs a workaround. [7]
- **Tooling/docs skew Docker-first.** Most third-party guides, images' example commands, and Stack Overflow
  answers assume Docker; Podman is close but you occasionally translate. Podman Desktop narrows this but
  the CLI/ecosystem defaults still favor Docker.
- **Rootless filesystem-ownership friction** around volumes and the sftp secret (2.4/2.5) - the concrete
  thing most likely to cost an evening.
- **Against all that**: you get no root daemon, no `docker.sock`, rootless-by-default, tighter caps, and
  systemd-native lifecycle - which is exactly the security-model shift that motivated the track, plus real
  portability (Quadlet units + OCI images move cleanly to any systemd Linux host).

## 2.8 Track 2 recommendation

**Migrate to Podman, using `podman-compose` as the incremental bridge and Quadlet systemd units as the
end-state, on the new dedicated host, with a single short data-cutover at the end.** This satisfies **both**
stated motivations - it sheds the rootful daemon and `docker.sock` (security model) and yields portable
OCI-images + systemd-units that move to any Linux host (portability) - which plain Docker-rootless does not
(it fixes the root-daemon half but keeps a daemon and doesn't improve portability).

**Tradeoffs accepted:** a less-polished compose experience, a Quadlet learning curve, a healthcheck-ordering
workaround, and an evening of rootless volume-ownership/perms reconciliation (Postgres data dir + the 0600
sftp key). **Fallback if those bite harder than expected:** **rootless Docker**, which is a low-effort way to
kill the root-daemon exposure alone while staying on the existing compose files - a strictly smaller win, but
a safe floor. **Not recommended:** containerd/k3s/nspawn - operational overinvestment for a two-user box.

---

# Where the two tracks interact

The client/server contract (HTTP + OpenAPI) decouples the tracks, so they can proceed in parallel. But
three interaction points are real and should be decided jointly, not in isolation:

1. **Server-side receipt extraction is a cross-track decision.** If the web client (Track 1.4) is allowed a
   server-side AI extraction endpoint, the backend gains an image-processing/LLM workload it does not have
   today. That changes the runtime's **security and resource profile** (now handling user images
   server-side, possibly wanting a **sandboxed, isolated service** - exactly the kind of workload where
   Track 2's rootless containers are an asset) and it **breaks the "no AI backend" invariant** the product
   is built on. Recommendation stands: **don't add it by default.** If it's ever added, it should be a
   deliberately isolated, rootless-contained service - which is an argument for finishing Track 2 first.

2. **New push transports are backend/relay work, not just client work.** Android needs **FCM** and web needs
   **Web Push / VAPID (RFC 8291)** - both are *new capabilities on the relay/backend side*, not client-only
   changes (Track 1.3). The E2EE envelope (`{epk, box}` ECIES) is portable and the relay's blind-forwarder
   design generalizes, but each new client platform adds a delivery rail the server must speak. Sequence
   this so a client isn't built expecting push the relay can't yet deliver.

3. **CORS / `ALLOWED_HOSTS` / TLS become live for a browser client.** A web PWA makes the currently-optional
   `CORS_ALLOWED_ORIGINS` and `ALLOWED_HOSTS` mandatory and puts real browser-origin traffic through the
   Cloudflare Tunnel. This is minor, but it's a backend config surface that only matters once Track 1 ships a
   web client - worth noting so it isn't discovered at the end.

Everything else - the logic core, the local cache, the native UIs, the runtime swap - is genuinely
independent across the two tracks.

---

## References (current-state claims verified mid-2026)

- [1] Podman vs Docker security/architecture, rootless-by-default, capability defaults - Uptrace; NVISO;
  Last9. https://uptrace.dev/comparisons/podman-vs-docker · https://last9.io/blog/podman-vs-docker/
- [2] Android on-device receipt AI - ML Kit GenAI Prompt API (Gemini Nano) + ML Kit OCR/Document Scanner -
  Android Developers Blog. https://android-developers.googleblog.com/2025/10/ml-kit-genai-prompt-api-alpha-release.html
  · https://developers.google.com/ml-kit/genai
- [3] Chrome built-in Prompt API (Gemini Nano, WebGPU, origin trial, ~4 GB VRAM, Chrome-only) -
  Chrome for Developers. https://developer.chrome.com/docs/ai/prompt-api
- [4] Podman daemonless fork-exec model, no root socket - Uptrace; INTROSERV.
  https://introserv.com/blog/docker-vs-podman-the-ultimate-guide-to-daemonless-containerization/
- [5] Docker rootless mode exists but is opt-in/less-polished; Podman rootless-first - DDEV; Xurrent.
  https://ddev.com/blog/podman-and-docker-rootless/
- [6] podman-compose vs Quadlet, compatibility gaps, `restart:` semantics without a daemon - oneuptime;
  Podman discussions. https://oneuptime.com/blog/post/2026-03-18-choose-between-quadlet-docker-compose-systemd/view
- [7] Quadlet is in-box since Podman 4.4, systemd-native, no native healthcheck-as-dependency - oneuptime;
  xda. https://www.xda-developers.com/quadlet-guide/
- Compose Multiplatform for iOS Stable (1.8.0, May 2025), production use - JetBrains Blog.
  https://blog.jetbrains.com/kotlin/2025/05/compose-multiplatform-1-8-0-released-compose-multiplatform-for-ios-is-stable-and-production-ready/
