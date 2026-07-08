# Cleave - iOS

**A private, offline-first iOS app for your money - expense splitting and personal finance,
against a backend you own.**

Cleave is the native iOS client for the [Cleave backend](../backend): split shared expenses
with friends, track your bank accounts and card spending, scan receipts, and stay on top of
budgets and subscriptions - all talking to a self-hosted server instead of someone else's
cloud. It's a modern SwiftUI + SwiftData app that does its thinking **on-device**: analytics,
categorization, receipt reading, and recurring-charge detection all run locally, and the ones
that use Apple Intelligence never send your data off the phone.

<p>
  <img alt="License: AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-blue">
  <img alt="Platform: iOS 26+" src="https://img.shields.io/badge/iOS-26%2B-black">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138">
  <img alt="SwiftUI + SwiftData" src="https://img.shields.io/badge/SwiftUI-SwiftData-blue">
  <img alt="Status: early" src="https://img.shields.io/badge/status-1.0%20(early)-orange">
</p>

> **Status:** early and evolving. Cleave is a complete, tested app one household runs day to day.
> The intended way to onboard users is the **published App Store app pointed at a self-hosted
> backend** (see [Two ways to run the app](#connecting-to-a-backend)); today you build it from source
> (open Xcode, set a signing team). This README covers building it. Feedback and issues welcome.

<p align="center">
  <img src="../docs/img/accounts.png"     width="24%" alt="Accounts and net worth"/>
  <img src="../docs/img/transactions.png" width="24%" alt="Transactions feed"/>
  <img src="../docs/img/splits.png"       width="24%" alt="Group balances"/>
  <img src="../docs/img/goals.png"        width="24%" alt="Spending and budgets"/>
</p>

---

## Table of contents

- [Why Cleave](#why-cleave)
- [Feature highlights](#feature-highlights)
- [On-device intelligence](#on-device-intelligence)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Build &amp; run](#build--run)
- [Connecting to a backend](#connecting-to-a-backend)
- [Privacy &amp; security](#privacy--security)
- [Project layout](#project-layout)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)

---

## Why Cleave

Splitwise paywalls the basics. Mint is gone. The finance apps that replaced them make money
from a permanent copy of your transactions. Cleave is the other trade: a polished native app
whose backend you run yourself.

- **Two apps in one.** The shared-expense app you'd use instead of Splitwise *and* the
  personal-finance app you'd use instead of Mint/Copilot - sharing one ledger, so a bill you
  split and the card charge that paid for it never double-count.
- **Your data stays yours.** The app talks only to *your* backend. The on-device cache is
  disposable; the server you control is the source of truth.
- **Private by construction.** Analytics and categorization run on the phone. The Apple
  Intelligence features (receipt reading, smart categorization) use Apple's **on-device**
  model - nothing is uploaded. Push notifications are end-to-end encrypted.
- **Works offline.** Everything you've synced is browsable and editable without a connection;
  changes reconcile when you're back online.
- **Bring your history.** Sign in with Splitwise and keep your groups, friends, and balances
  live - or migrate them into self-hosted groups you own.

## Feature highlights

### Split expenses (the "Splits" tab)

- **A genuinely complete expense editor** - eight split modes: Equal, Exact, Percent, Shares,
  +/− Adjustment, Reimburse, **Itemized** (assign each line item to a person), and **Settle
  Up**, with multi-payer support and a live "Balanced / off by $X" check.
- **Groups & friends** - per-group balances or Splitwise-style pairwise "who owes whom,"
  month-sectioned expense history, settle-up collapse, custom group avatars, and one-tap
  restore of a deleted Splitwise group.
- **Two-way Splitwise** - import your history and keep edits/settle-ups/deletions live in both
  directions, or **"Import as Local Group"** to move a group onto your own server for good.
- **"Remember this split"** - the app learns how you usually split a given merchant and
  offers to apply it next time.

### Track your money (the "Accounts" tab)

- **Accounts & net worth** - link banks via **Plaid**, connect via **SimpleFIN** (paste one
  token), or import **OFX statements** (Apple Card and other aggregator-hostile banks), with
  assets-minus-liabilities section headers and duplicate-account detection/merge.
- **Transactions** - searchable, pending/posted grouping, manual entry, per-row category
  overrides with "reset to automatic," itemization, and **turn any transaction into a split
  expense**.
- **Partner sharing** - share an account or a goal read-only with a connected partner, per-item
  and opt-in (see [Share & collaborate](#share--collaborate)).

### Budgets, goals & analytics (the "Goals" tab)

- **Spending donut & trends** - a monthly category donut and spending/net-income bar charts
  (Swift Charts), every slice tappable straight through to the transactions behind it.
- **Budgets & savings goals** - Mint-style monthly category budgets with status-colored
  progress, plus "reach a balance / save an amount" savings goals.
- **Combined household budgets** - count both partners' spending toward one shared limit,
  computed so both phones independently arrive at the same number.

### Stay on top of it (the "Inbox" tab)

- **Smart suggestions** - an on-device review queue: link a transaction to its expense,
  recategorize a merchant, track a detected subscription, split a recurring bill "like last
  time," settle up, or watch a budget - ranked so the most useful surface first.
- **Subscriptions** - Rocket-Money-style recurring-charge detection with estimated annual
  cost, upcoming-charge gallery, and price-increase flags.
- **Activity feed & notifications** - a shared-group activity log with per-category,
  independently-toggled in-app and push notifications, synced across your devices.

### Capture

- **Scan a receipt → a prefilled expense** - VisionKit document scanning plus on-device
  extraction of merchant, date, total, and line items, snapped to your own categories.
- **Receipt manager** - a zoomable carousel that unifies an expense's receipts, its linked
  transaction's receipts, and a view-only Splitwise original.

### Share & collaborate

Cleave servers are multi-user, and the app has the full UI for both halves of that - getting people
onto your server, and sharing data once they're there. (Backend model + endpoints:
[backend → Multi-user](../backend/README.md#multi-user-invites--partner-sharing).)

- **Invite people onto your server** - `InvitePeopleView` mints **single-use join links with a QR
  code** (`QRCodeView`), with an optional label + expiry, a live view of outstanding invites, and
  one-tap revoke. The recipient scans/opens the link and the code rides through sign-in; the app also
  adopts a server straight from a join link or Universal Link (`RootView`). Admins (or any member, if
  the server allows it) can invite.
- **People directory** - `PeopleView` lists everyone you share context with, badged by source
  (Splitwise / app / manual), partner status, and whether they've registered; admins get
  `LocalUsersView` to see enrolled users.
- **Connect a partner** - `PartnersView` runs a Zeta-style request → accept flow (invite by email,
  accept / decline / cancel / disconnect), backed by `ConnectionRepository`.
- **Share accounts & goals, read-only** - once connected, share an account at a chosen level
  (**private / balances / full** - `AccountShareLevel`, set in `AccountEditView`) or share a goal with
  a partner; shared-in items appear read-only tagged with who shared them (`SharedAccountTransactionsView`
  for a partner's full-shared account). Nothing is ever shared without your explicit, per-item opt-in.
- **Combined household budgets** - a shared goal counts both partners' spending toward one limit,
  computed on-device so both phones agree (see [On-device intelligence](#on-device-intelligence)).
  Partner activity also surfaces as accept/dismiss cards in the Inbox (`InboxView`).

## On-device intelligence

What sets Cleave apart from a thin API client is how much it computes locally - for speed,
for offline use, and for privacy. All of this runs on the phone:

- **Unified spend engine** - merges bank transactions and your owed share of split expenses
  into one consistent stream, de-duplicating a shared bill against the card charge that paid
  it, so a $2,000 mortgage split 50/50 counts as $1,000, not $3,000. Every total drills
  through to the exact rows behind it.
- **Transparent categorization** - a canonical taxonomy with a clear precedence chain (your
  override → your learned map → Apple-Intelligence refinement → Plaid/Splitwise built-in map →
  raw), each result carrying a **provenance badge** (You / AI / Auto) so nothing is a black box.
- **Apple Intelligence, optional and guarded** - receipt extraction, category refinement,
  merchant disambiguation, and transaction-match ranking use Apple's on-device
  `FoundationModels`. Every use checks availability, constrains output to a fixed list, and
  falls back to a deterministic path when the model isn't there - and nothing leaves the device.
- **Deterministic subscription detection** - clusters charges by merchant, classifies cadence
  from the median interval, and flags price increases, with a strict bar to avoid false
  positives and a "Possible" list for near-misses.
- **Penny-perfect split math** - all splitting works in integer cents with remainder handling,
  mirroring the server's balance rules so shared expenses always reconcile exactly.
- **Merchant & bank branding** - resolves clean brand names and logos from noisy strings
  ("SQ *BLUE BOTTLE 0123" → Blue Bottle Coffee), with an AI guess gated by a verbatim-token
  check so it can't hallucinate a logo.

> **Backend parity is deliberate.** The category maps, brand catalog, and split/balance rules
> are kept in lockstep with the backend, and covered by tests - so numbers computed on the
> phone match numbers computed on the server.

## Architecture

Cleave is a **SwiftUI + SwiftData** app. Almost all of it lives in one local Swift package,
`CleaveAPI`, layered cleanly; the app target imports it, while the two extensions compile a few shared source files directly (no package link) to stay tiny.

```
  ┌────────────── Cleave (app target) ───────────────┐   ┌─ Notification Service ─┐  ┌─ Share ─┐
  │  @main App shell · push app-delegate · deep links │   │  decrypts E2E push     │  │  OFX    │
  └───────────────────────┬──────────────────────────┘   │  on-device (blind      │  │  import │
                          │  imports                       │  relay stays blind)    │  │  from   │
                          ▼                                └────────────────────────┘  │  share  │
  ┌──────────────────── CleaveAPI (Swift package) ─────────────────────┐              │  sheet  │
  │  Views (SwiftUI) - 94 files, the screens                  │              └─────────┘
  │  Logic - 57 files, pure on-device computation    │
  │  Repositories - 31 files, fetch + reconcile into cache  │   all three targets share
  │  Networking - 18 files, generated client, auth, crypto│   the App Group keychain
  │  Models (SwiftData) - 20 files, the on-device cache schema    │   (E2E push key + tokens)
  └────────────────────────────────┬───────────────────────────────────┘
                                    ▼  HTTPS (generated OpenAPI client)
                         your self-hosted Cleave backend

  Stack: iOS 26 · Swift 6.2 · SwiftUI · SwiftData · Swift Charts · VisionKit ·
         Apple FoundationModels · swift-openapi-generator · Plaid LinkKit · GoogleSignIn
```

**Ideas worth knowing before you read the code**

- **The cache is disposable.** SwiftData is a pure on-device mirror of the server. On any
  schema mismatch the store is rebuilt and re-synced rather than migrated; sign-out wipes it.
- **Repositories reconcile, they don't just decode.** Responses are upserted into SwiftData
  in place (never delete-and-reinsert, which would break live views), with delta sync
  (`updated_since`) and periodic full reconciliation to catch server-side deletes.
- **Smart, cost-aware refresh.** Pull-to-refresh decides between an expensive live provider
  sync and a cheap cache re-fetch based on server-set freshness thresholds (Plaid costs money,
  so it's synced less often than free Splitwise).
- **The client is generated from the contract.** `swift-openapi-generator` builds the API
  types and client from `openapi.json` at build time, so the app and backend can't silently
  drift on the wire format.
- **Multi-backend by design.** The bearer token is stored in the Keychain keyed per server, so
  dev/prod/demo keep separate sessions and a token is never sent to a server that didn't mint it.

## Requirements

- **Xcode 26** or newer (targets the iOS 26 SDK; the app builds in the Swift 5 language mode, the CleaveAPI package in Swift 6.2).
- **iOS 26+** device or simulator. Apple Intelligence features additionally require a
  supported device with Apple Intelligence enabled - the app degrades gracefully without it.
- **A Cleave backend** to talk to - your own instance, or the demo server for a first look.
- An **Apple Developer team** for device builds (App Groups, Push, Sign in with Apple, and
  Associated Domains are all real capabilities that need provisioning).
- [**XcodeGen**](https://github.com/yonaskolb/XcodeGen) - the `.xcodeproj` isn't committed; it's
  generated from `project.yml`.

## Build & run

```bash
# 1. Generate the Xcode project from project.yml
brew install xcodegen        # if you don't have it
cd ios
xcodegen generate

# 2. Open and run
open Cleave.xcodeproj
#    Select the "Cleave" scheme + a simulator, then Run.
```

- **Signing:** `project.yml` pins a development team and automatic signing so on-device builds
  provision the app, notification-service, and share extensions in one go. Change
  `DEVELOPMENT_TEAM` to your own for device builds; the **simulator** needs no signing. For a
  device build under your own team you must also change the bundle identifiers, the App Group
  (`group.money.cleave.app`), `GIDClientID`, and the `applinks:` domain in `project.yml` to your
  own - you cannot provision `money.cleave.app` under a different team.
- **Default backend:** a fresh build points at `https://demo.cleave.money` (set via `API_BASE_URL`
  in `Cleave/Info.plist`). You can change servers at runtime - see below - so you don't need to
  rebuild to point at your own instance.
- **Regenerate after adding files:** because the project is generated, re-run `xcodegen
  generate` whenever you add or move source files.
- **Refresh the API client after a backend contract change:** update `ios/openapi.json`, then run
  `python3 ios/scripts/prepare_openapi.py ios/openapi.json ios/CleaveAPI/Sources/CleaveAPI/openapi.json`
  to regenerate the transformed copy the generator consumes.


## Connecting to a backend

The app can point at any Cleave backend, and switch at runtime:

- **On the sign-in gate**, set the API base URL, then sign in with **Apple**, **Google**, or
  **Splitwise** (only the providers your backend advertises are shown), start a **demo/guest**
  session with sample data, or paste an operator **bearer token**.
- **Self-hosted on your LAN?** The app allows local-network HTTP and `*.local` hosts; use the
  backend's LAN IP (not `localhost`, which resolves to the phone itself).
- **Join links & QR.** An invite is a Universal Link (`<YOUR_HOST>/join`) or QR code that adopts
  the server and carries a single-use invite code through sign-in.
- **Deep links.** Tapping a push routes to the right screen; Plaid OAuth returns resume the live
  Link session; Splitwise OAuth returns via a `cleave://auth?token=...` callback.

### Two ways to run the app against your backend

Which one you're in changes what "sign in" can do.

> ⚠️ **Not on the App Store yet.** Until the listing ships, everyone uses the "build your own app"
> path below; the published-app path is how onboarding will work once it's listed.

- **Use the published Cleave app** (easiest - the natural way to onboard a community). Your users
  install Cleave from the App Store and point it at your backend's URL via the Base-URL field above
 - no Apple Developer account, no sideloading. Works out of the box for **Splitwise, demo/guest,
  and bearer-token** sign-in. For **Apple / Google sign-in**, the backend operator just sets the
  backend's audiences to the published app's public values (`APPLE_AUDIENCE=money.cleave.app`,
  `GOOGLE_CLIENT_ID=...apps.googleusercontent.com`). **Joining** a server is by pasting its URL or
  scanning its QR in the app - Universal Link *taps* resolve to the official app's domain, not the
  self-hoster's.
- **Build and ship your own app** (advanced - full white-label). Create your own Apple App ID +
  Team ID and Google iOS client id, build and distribute the app yourself, and you additionally get
  **Universal Link join-links to your own domain** and your own bundle id/branding. This is the path
  [Build & run](#build--run) walks through. Cost: an Apple Developer account and distributing the app.
  **Push notifications also become your own to run:** because APNs authenticates against your app's
  team + bundle id, the official relay can't push to your build - you run your own relay with your own
  APNs key. See [backend → Run your own push relay](../backend/README.md#push-notifications--use-the-official-relay-or-run-your-own).

See [backend → Provider setup](../backend/README.md#provider-setup-step-by-step) for the backend
side of both.

## Privacy & security

- **On-device AI, no uploads.** Every Apple Intelligence feature runs on Apple's on-device
  model; receipts and transactions are never sent to a cloud model.
- **End-to-end-encrypted push.** Notification content is encrypted to the device's key (ECIES:
  P-256 ECDH → HKDF → AES-256-GCM, via CryptoKit). The push relay and Apple only ever see
  ciphertext and a generic "New activity" placeholder; a **Notification Service Extension**
  decrypts on-device to show the real text. The private key lives in the App Group Keychain so
  the extension can read it while the phone is locked.
- **Per-server Keychain tokens.** Bearer tokens are stored in the Keychain, scoped per backend,
  and never sent to a different server.
- **Face ID / passcode lock.** An optional privacy gate covers the app on launch and on return
  from background until you authenticate (`LocalAuthentication`).
- **Data ownership.** Sign-out and server-switch erase the local cache and reset every
  preference watermark so one account's data can't bleed into the next.

## Project layout

```
ios/
├── project.yml                 # XcodeGen project definition (targets, signing, capabilities)
├── openapi.json                # the backend contract the API client is generated from
├── Cleave/                     # app target: @main App shell + push app-delegate + entitlements
├── CleaveAPI/                  # the Swift package where ~all the code lives
│   └── Sources/CleaveAPI/
│       ├── Views/              # 94 SwiftUI files - every screen (+ Views/Capture/ for scanning)
│       ├── Logic/              # 57 files - pure on-device computation (analytics, categorization,
│       │                       #   split math, subscriptions, receipt extraction, matching)
│       ├── Repositories/       # 31 files - fetch + reconcile into SwiftData; sync; offline
│       ├── Networking/         # 18 files - generated client, auth, push crypto, extension bridges
│       └── Models/             # 20 files - SwiftData cache schema
├── CleaveNotificationService/  # extension: decrypts E2E push on-device
├── CleaveShareExtension/       # extension: OFX statement import from the share sheet
├── CleaveTests/                # 34 test files - logic-layer unit tests (no app host)
└── scripts/                    # OpenAPI prep, app-icon generation
```

## Testing

The test suite covers the **Logic layer** - the on-device intelligence that most needs to be
correct - plus networking middleware and mapping. It depends only on the `CleaveAPI` library
(no app host), so it runs fast.

```bash
# From Xcode: the "Cleave" scheme's Test action (⌘U), or:
xcodebuild test -scheme Cleave -destination 'platform=iOS Simulator,name=iPhone 16'
```

The ~34 test files include split math, category mapping & provenance, Plaid/Splitwise category
parity, subscription detection, transaction matching, itemized & household spend, goals
analytics, push crypto (with a pinned interop vector against the backend), idempotency, and
join-link parsing - i.e. the pieces where the app must agree with itself across screens and
with the backend across the wire.

For a faster inner loop than on-device rebuilds, see [XCODE_TIPS.md](XCODE_TIPS.md): diagnosing with
SwiftUI Previews, simulator tricks, and the scheme's runtime diagnostics.

## Contributing

Issues and pull requests are welcome. Because Cleave handles financial data and mirrors backend
logic, changes to the spend engine, categorization, or split math should come with tests - the
parity tests exist precisely so the app and server can't silently diverge. Re-run `xcodegen
generate` after adding files, and keep the on-device AND deterministic paths working (AI is
always optional).

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full workflow (including DCO sign-off) and the
[Code of Conduct](../CODE_OF_CONDUCT.md).

## License

[GNU Affero General Public License v3.0](../LICENSE) - same as the backend.

---

