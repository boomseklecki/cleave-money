# Cleave Client Parity Contract

This directory is the **framework-neutral capture of what the Cleave iOS app does**, so the web
and Android clients can be built against a single source of truth instead of re-deriving the
correctness-critical logic (split math, balances, category resolution, subscription detection,
ECIES push) and silently diverging.

It exists because Cleave's clients are disposable caches over one server contract, but a large
body of behavior lives *on the client* (see [`../docs/PORTING_ARCHITECTURE_SPEC.md`](../docs/PORTING_ARCHITECTURE_SPEC.md),
Track 1). Capturing that behavior once, as fixtures + spec, is the prerequisite for a shared
logic core and for any second client.

## What's here

```
spec/
  README.md      <- you are here: the conformance model + how to consume
  SPEC.md        <- prose: every rule, constant, threshold, lookup table, precedence chain
  fixtures/      <- language-neutral JSON: {input, expected} cases per module
  contracts/     <- boundary behaviors (sync, capabilities, crypto/push, deep links, ...)
  replay/        <- run-here reference replayer (self-consistency check)
```

## The conformance model (why this is trustworthy)

The fixtures are **not** hand-authored guesses that drift from the app. They are anchored to the
shipping iOS implementation as the reference oracle, and replayed by every client:

```
                 spec/fixtures/**  (the shared contract: {input, expected})
                        |
        +---------------+----------------+-------------------+
        v               v                v                   v
   iOS (oracle)    web client       Android client     replay.mjs (here)
   Swift XCTest    reimpl. asserts  reimpl. asserts    independent JS reimpl.
   asserts vs      vs expected      vs expected        asserts vs expected
   real Logic
```

- **iOS is the oracle.** `ios/CleaveTests/ParityConformanceTests.swift` loads these fixtures and
  asserts the *real, shipping* `Logic/` code produces each `expected`. If someone changes
  `SplitMath` in a way that diverges from a fixture, that test goes red until the fixture is
  regenerated on purpose. So the fixtures can never quietly fall out of sync with the app.
- **Web and Android** load the *same JSON* and assert their reimplementations match `expected`.
  Passing means "provably behaves like iOS" for every captured case.
- **`replay/replay.mjs`** is an independent Node reimplementation that recomputes every case and
  checks it against `expected`. It is a cheap self-consistency guard (catches authoring/rounding
  mistakes before the Mac handoff). **It is not the oracle** - the iOS test is.

This generalizes what `ios/CleaveTests/PushCryptoTests.swift` already does for the ECIES vector
(one fixture pinned across Swift <-> Python) to every portable module.

## How to run

- **Run-here self-check (this environment):**
  ```
  node spec/replay/replay.mjs
  ```
  Validates fixture structure and reproduces every case with the reference implementation.

- **Oracle gate (Matt's Mac - iOS build environment):** run the `Cleave` scheme's Test action;
  `ParityConformanceTests` replays `spec/fixtures/**` against the shipping Logic layer and must be
  green. Because the Xcode project is generated, re-run `xcodegen generate` after this file is
  first added so the new test file is picked up.

- **A new client (web/Android):** vendor or symlink `spec/`, write a loader that reads each
  `fixtures/<module>/*.json`, run your implementation per `fn`, and assert against `expected`.

## Fixture format

Each file is one module's cases:

```jsonc
{
  "module": "split-math",                 // must match the directory name
  "reference": "ios/.../SplitMath.swift", // the iOS source of truth
  "note": "...",                          // human context
  "cases": [
    {
      "name": "equal-evenly-divisible",   // unique within the module
      "fn": "equalSplit",                 // which function/behavior this exercises
      "input":    { /* fn-specific */ },
      "expected": { /* fn-specific */ }
    }
  ]
}
```

Conventions:
- **Money is decimal strings** (`"10.01"`), never floats - clients parse to their exact-decimal
  type (Swift `Decimal`, integer cents, BigDecimal). This keeps the contract free of float error.
- **Order matters**: split arrays are returned in `participants` order; assert positionally.
- `fn` names match the iOS function names so the mapping to `SPEC.md` and source is 1:1.

## Status

All 12 pure-logic modules are captured as fixtures + oracle tests + reference replay, plus the
deep-link parsers - **~400 cases**, all reproduced by `replay.mjs` and verified green against the iOS
oracle on the Mac. The six boundary behaviors are documented in `contracts/*.md`. `SPEC.md` tracks
per-module capture status; a few pieces are deliberately out of scope (see the notes there and in each
contract): `NSDataDetector` receipt dates, the runtime AI/OCR/keystore paths (their deterministic
floors are fixtured), the server-managed brand catalog table, and the full `SuggestionEngine`
orchestration (its building blocks are each captured).
