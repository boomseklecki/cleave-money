# Coverage audit (Phase 4)

The four completeness checklists from the capture plan. Confirms every `Logic/` file and every
`CleaveTests` file is accounted for as **captured** (fixtures + oracle), **capability/contract**
(documented in `contracts/*.md`, its deterministic floor fixtured), or **reference-only** (presentation
/ UI-state / stateful cache with no portable correctness surface).

## (a) `Logic/` files (57) - classification

### Captured - fixtures + oracle (21)
`SplitMath`, `CategoryMapping`, `PlaidCategory`, `SplitwiseCategory`, `ItemizedSpend`,
`AccountClassification`, `SpendingAnalytics`, `SubscriptionDetector`, `TransactionMatcher`,
`MerchantText`, `Brand` (BrandMatcher + MerchantParse), `RelatedTransactions`, `HouseholdBudget`,
`GoalProgress`, `SpendPeriod`, `SplitTemplateLearning`, `SuggestionRanking`, `ReceiptHeuristics`,
`ExpensePrefill` (recentReceiptDate), `JoinLink`, `NotificationTarget`.

### Capability adapters - `contracts/capabilities.md`; deterministic floor is captured (8)
`CategoryMapper` (FM refine/suggest → floor `CategoryMapping`), `Brand`'s `BrandModel` (FM guess →
floor catalog/embedded), `ReceiptExtractor` + `ReceiptExtraction` (FM → floor `ReceiptHeuristics`),
`ReceiptOCR` (Vision), `ReceiptScanModel` (OCR+extractor orchestration), `TransactionMatchModel`
(FM re-rank → floor `TransactionMatcher`), `AppLock` (LocalAuthentication).

### Contract / stateful - documented, not fixtured (7)
`SmartRefresh` (cost-aware refresh → `contracts/sync.md`), `SuggestionEngine` +
`SuggestionAnalysisCache` (pass orchestration → `suggestions` SPEC note; building blocks captured),
`SuggestionPreferences` (LinkSensitivity thresholds - documented in the suggestions section),
`MerchantPreferences` + `BrandGuessCache` (stateful UserDefaults caches → `out-of-cache-state.md`;
their matching uses the captured `BrandMatcher`), `NotificationPrefs` (mute tokens → out-of-cache).

### Reference-only - presentation / UI-state / thin enums, no portable correctness surface (21)
`AppearanceMode`, `BalanceDisplay`, `CategoryCatalog`, `CategoryColor`, `CategoryDependents`,
`CategoryIcon`, `CategoryProvenance` (badge/inspector - its provenance strings are exercised by the
`category` fixtures), `CategorySeed`, `DeepLinkRouter`, `DisplayName`, `ExpenseGrouping`, `Formatting`,
`GoalSection`, `GroupIcon`, `GroupSummary` (SwiftData fetch), `InstitutionBrand` (logo mapping),
`MainTab`, `MonthSwipe`, `ReorderableSection`, `SpendContributors` (drill-through projection),
`UserDirectory`, `Suggestion` (value type).

**Total: 21 + 8 + 7 + 21 = 57. No unclassified file.**

## (b) `CleaveTests` files (35) - mapping

- **Seeded a fixture family (18):** SplitMathTests → split-math; PlaidCategoryTests /
  SplitwiseCategoryTests / CategoryProvenanceTests → category; ItemizedSpendTests → itemized-spend;
  AccountClassificationTests → account-classification; SubscriptionDetectorTests → subscriptions;
  TransactionMatcherTests / RelatedTransactionsTests / MerchantAvatarTests → matching + merchant-brand;
  HouseholdBudgetTests → household-budget; GoalsAnalyticsTests / SpendPeriodTests → goals;
  SplitTemplateLearningTests / SuggestionRankingTests → suggestions; ReceiptScanTests → receipts;
  JoinLinkTests / NotificationTargetTests → deep-links.
- **Contract-documented, not fixtured (6):** DateTranscoderTests, IdempotencyMiddlewareTests,
  ResponseErrorMiddlewareTests → `contracts/sync.md`; CategorySyncTests, SuggestionSyncTests →
  `contracts/out-of-cache-state.md`; PushCryptoTests → `contracts/crypto-push.md` (the pinned vector).
- **Runtime / wire-mapping, no portable pure surface (7):** MappingTests, MappingPhase2Tests,
  TransactionMappingTests (transport→SwiftData mapping), ErrorAlertTests, FriendCacheTests,
  PlaidLinkDiagnosticsTests, ReceiptImageTests.
- **Capability-adjacent, not fixtured (2):** CategoryMapperTests (the AI *prompt string* - pure but
  AI-path; the deterministic resolution it guards is captured), SuggestionEngineTests /
  SuggestionNudgeTests (engine orchestration - building blocks captured). *(SuggestionEngineTests and
  SuggestionNudgeTests count as 2, giving the +1 over the seeded set.)*
- **The oracle itself (1):** ParityConformanceTests.

Every test file is either seeded into a fixture family, mapped to a contract, or explicitly marked
runtime-only. Nothing unaccounted.

## (c) OpenAPI operations - behavioral semantics

The plan captures the **behavior** around the wire contract, not the schema bytes (the committed
`ios/openapi.json` never byte-matches live FastAPI). `contracts/sync.md` documents the load-bearing
semantics: `updated_since` = creates/updates only (never deletes), upsert-in-place by id, periodic
full reconcile for deletes, cost-aware refresh thresholds, the `Idempotency-Key` on creates, the
microsecond date-transcoding tolerance, and bearer-token auth. These are the behaviors a client must
honor beyond the generated types; the per-endpoint request/response shapes come from the generated
OpenAPI client on each platform.

## (d) Apple capabilities - adapter coverage

Every Apple-only capability from the exploration map has a home:

- Foundation Models (5 call sites), Vision/VisionKit OCR, LocalAuthentication, secure key storage →
  `contracts/capabilities.md`.
- CryptoKit ECIES + APNs/App-Group keychain → `contracts/crypto-push.md` + `contracts/extensions.md`.
- Sign in with Apple / GoogleSignIn / Plaid LinkKit / ASWebAuthenticationSession → `contracts/deep-links.md`
  (SDK flows with cross-platform analogues; the portable part is the URL shapes).
- Share extension (OFX) / Notification Service Extension → `contracts/extensions.md`.

## Deliberately deferred (candidate follow-ups)

- A Node ECIES verifier for the crypto-push vector (currently the existing `PushCryptoTests` is its
  Swift↔Python oracle).
- Fixtures for the `NSDataDetector` receipt-date path (no portable equivalent).
- The full `SuggestionEngine` pass orchestration end-to-end (thresholds documented; building blocks
  captured).
- The ~60-entry server-managed `BrandCatalog` table and the private `brandRelatesToMerchant` guard.
- Date-transcoder / reconcile / apply-if-newer fixture families (behaviors documented in contracts).
