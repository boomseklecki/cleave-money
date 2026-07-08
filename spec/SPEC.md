# Cleave Client Behavior Spec

Prose companion to `fixtures/`: the rules, constants, thresholds, lookup tables, and precedence
chains a conforming client must implement. The **code is the source of truth**; this document
restates it so a reimplementation has an unambiguous target, and every rule with a correctness
surface is also pinned by a fixture. Where a rule and a fixture disagree, the iOS oracle test
(`ParityConformanceTests`) decides.

Reference implementations live under `ios/CleaveAPI/Sources/CleaveAPI/Logic/`. Interaction
boundary behaviors (sync, capabilities, crypto/push, deep links, extensions, out-of-cache state)
are in `contracts/`, not here.

## Capture status

| Module | Source | Fixtures | Spec | Oracle test |
|---|---|---|---|---|
| Split math | `Logic/SplitMath.swift` | done (`fixtures/split-math/`) | done (below) | `ParityConformanceTests.testSplitMathConformance` |
| Category taxonomy + precedence | `Logic/CategoryMapping.swift`, `PlaidCategory.swift`, `SplitwiseCategory.swift` | done (`fixtures/category/`) | done (below) | `ParityConformanceTests.testCategoryConformance` |
| Itemized spend attribution | `Logic/ItemizedSpend.swift` | done (`fixtures/itemized-spend/`) | done (below) | `ParityConformanceTests.testItemizedSpendConformance` |
| Spend / dedup engine | `Logic/SpendingAnalytics.swift` | done (`fixtures/spend-engine/`) | done (below) | `ParityConformanceTests.testSpendEngineConformance` |
| Subscriptions | `Logic/SubscriptionDetector.swift` | done (`fixtures/subscriptions/`) | done (below) | `ParityConformanceTests.testSubscriptionConformance` |
| Matching | `Logic/TransactionMatcher.swift` | done (`fixtures/matching/`) | done (below) | `ParityConformanceTests.testMatchingConformance` |
| Merchant / brand | `Logic/MerchantText.swift`, `Brand.swift`, `RelatedTransactions.swift` | done (`fixtures/merchant-brand/`) | done (below) | `ParityConformanceTests.testMerchantBrandConformance` |
| Household budget | `Logic/HouseholdBudget.swift` | done (`fixtures/household-budget/`) | done (below) | `ParityConformanceTests.testHouseholdBudgetConformance` |
| Goals / periods | `Logic/GoalProgress.swift`, `SpendPeriod.swift`, `SpendingAnalytics.swift` | done (`fixtures/goals/`) | done (below) | `ParityConformanceTests.testGoalsConformance` |
| Account classification | `Logic/AccountClassification.swift` | done (`fixtures/account-classification/`) | done (below) | `ParityConformanceTests.testAccountClassificationConformance` |
| Suggestions + ranking | `Logic/SuggestionRanking.swift`, `SplitTemplateLearning.swift` | done (`fixtures/suggestions/`) | done (below) | `ParityConformanceTests.testSuggestionsConformance` |
| Deep-link parsing | `Logic/JoinLink.swift`, `NotificationTarget.swift` | done (`fixtures/deep-links/`) | see `contracts/deep-links.md` | `ParityConformanceTests.testDeepLinksConformance` |

**Interaction contracts** (boundary behaviors) are documented in `contracts/*.md`: sync, capabilities,
crypto-push, deep-links, extensions, out-of-cache-state. The deep-link parsers additionally have
fixtures (above); the crypto-push ECIES vector is pinned by the existing `PushCryptoTests`.
| Receipt heuristics | `Logic/ReceiptHeuristics.swift`, `ExpensePrefill.swift` | done (`fixtures/receipts/`) | done (below) | `ParityConformanceTests.testReceiptsConformance` |

---

## Split math

Reference: `Logic/SplitMath.swift`. Fixtures: `fixtures/split-math/`.

Produces per-participant `{ userIdentifier, paidShare, owedShare }` for an expense. All splits are
returned **in `participants` order** (assert positionally). If `participants` is empty it falls
back to `[payer]`.

### Money representation and rounding (load-bearing)

- Money is **decimal** end to end; storage/compare is exact (Swift `Decimal`; a port should use
  integer cents or an exact-decimal type, never binary float).
- Rounding to cents is **round half up** (away from zero), matching `NSDecimalNumber` `.plain`:
  `cents(x) = round_half_up(x * 100)`, then `money(c) = c / 100`. The reference replay implements
  this with `roundHalfUpDiv` over BigInt; a client must match it exactly or penny cases diverge.

### Balance check

- `tolerance = 0.01`.
- `isBalanced(amount, splits)` is true iff **both** `sum(paidShare)` and `sum(owedShare)` are
  within `±0.01` of `amount`. (`9.995` owed against `10.00` is balanced; `9.00` is not.)

### equalSplit(amount, payer, participants)

- Everyone (including the payer) owes an equal share; the payer's `paidShare = amount`, everyone
  else `0`.
- `base = cents(amount) / n` (integer division). The `remainder = cents(amount) - base*n` extra
  pennies go **one each to the earliest participants** (`index < remainder`), so `owedShare` sums
  to `amount` exactly. Example: `10.01` across 3 -> `3.34, 3.34, 3.33`.

### weightedSplit(amount, payer, participants, weights)

- For percentages or share counts. Negative weights are clamped to `0`. If total weight `<= 0`,
  falls back to `equalSplit`.
- `owed_i = cents(amount * weight_i / totalWeight)`. Residual **drift** (`cents(amount) -
  sum(owed)`) is spread `±1` cent **round-robin from index 0** until zero. Example: `10` at `1:2`
  -> `3.33, 6.67`; `10` at `1:1:1` -> `3.34, 3.33, 3.33`.

### adjustmentSplit(amount, payer, participants, adjustments)

- Equal-split `(amount - sum(adjustments))`, then add each person's adjustment to their owed.
  Example: `20`, `+4` for b -> base on `16` (`8` each), b owes `12`, a owes `8`.

### itemizedSplit(amount, payer, participants, assigned)

- Each person owes their assigned item total; the **unassigned remainder** (tax/tip =
  `amount - sum(assigned)`) is equal-split. Example: `10`, b assigned `4` -> remainder `6` split
  `3/3`, so a owes `3`, b owes `7`.

### reimbursementSplit(amount, payer, participants)

- A windfall the payer received and splits back. Encoded as `equalSplit` with each person's
  `paidShare`/`owedShare` **swapped**, which flips every balance while still summing to `amount`.
  Example: `30` across `[a,b,c]` -> a `paid 10 / owed 30` (nets `-20`), b and c `paid 10 / owed 0`
  (each "gets back" `10`).

### Sentinel categories

- `Reimbursement.category = "Reimbursement"` and `SettleUp.category = "Settle-up"` flag expenses
  for "gets back" / settle-up presentation. These exact strings are part of the category exclusion
  sets (see the category module) - a port must use them verbatim.

### collapseOlder(expenses)  (Splitwise-style history collapse)

- `expenses` are **newest-first**. Returns the visible prefix **through the most recent settle-up
  (inclusive)** and the count of older expenses collapsed. Settle-up is detected by
  `category == "Settle-up"`. No settle-up present -> everything visible, `collapsed = 0`.

---

## Category taxonomy + precedence

Reference: `Logic/CategoryMapping.swift`, `PlaidCategory.swift`, `SplitwiseCategory.swift`.
Fixtures: `fixtures/category/`.

### Canonical taxonomy (data - pin verbatim)

- `CanonicalCategory.all` is the **ordered** 25-item list (`fixtures/category/canonical-sets.json`).
  Kept in lockstep with `backend/app/categories.py`; the on-device AI is constrained to this list.
- Three exclusion sets (unordered) drive spend/cash-flow filtering everywhere:
  - `excludedFromSpend = {Transfer, Income, Settle-up, Reimbursement}` - never counted toward spend.
  - `neutral = {Transfer, Settle-up}` - no economic event; excluded from spend **and** net income.
  - `incomeLike = {Income, Reimbursement}` - inflow (your share), excluded from spend.
- Note `Reimbursement` and `Settle-up` are the sentinel strings from the split-math module; they must
  match verbatim across both.

### Plaid taxonomy -> canonical (`PlaidCategory`)

- `canonical(raw)`: check `detailedOverrides` first (exact match, 10 entries), then `primaryMap`
  (16 entries) by **exact match or `raw.hasPrefix(primary + "_")`**. Unrecognized -> `null`.
  Full table pinned in `plaid-canonical.json` so a single-entry drift fails. The detailed overrides
  exist so budget categories that split within a primary are reachable (Groceries vs Dining, Fuel vs
  Transport, Rent vs Utilities, Mortgage, Insurance, Education, Pets, Gifts).
- `humanized(raw)`: `SCREAMING_SNAKE` -> Title Case (split on `_`, lowercase, capitalize each word).
- `displayLabel(raw)`: humanize **only** when the label is Plaid-format (every char is uppercase /
  digit / `_`, and at least one letter); otherwise pass through unchanged (so Splitwise labels like
  "Dining out", "Gas/fuel", "TV/Phone/Internet" are never mangled).

### Splitwise taxonomy -> canonical (`SplitwiseCategory`)

- `canonical(raw) = map[raw]`; Splitwise's list is closed so the whole ~44-entry map is pinned
  (`splitwise-canonical.json`). Unrecognized -> `null`. Used only for spend bucketing; the expense
  keeps its original label for display.

### Precedence with provenance

`CategoryOrigin` (the winning layer) is surfaced as a badge. Provenance strings used in fixtures:
`override`, `mappedByYou`, `mappedByAI`, `deterministic`, `aiRefined`, `explicit`, `raw`.

- **Transaction** - `resolve(for:lookup:sources:)` (`transaction-precedence.json`). Precedence:
  1. non-empty `categoryOverride` -> `override`
  2. if raw is null/empty: a non-empty `refinedCategory` -> `aiRefined`, else `{null, raw}`
  3. local `lookup[raw]` -> `mappedByYou` (source `"manual"`) or `mappedByAI` (source `"ondevice"`)
  4. non-empty `refinedCategory` -> `aiRefined` **(outranks the built-in map)** - it is only written
     when the on-device model judged the change *clearly* better (anchored `changeIsClear` gate)
  5. `PlaidCategory.canonical(raw)` -> `deterministic`
  6. passthrough: raw is already a canonical name -> `explicit`, else -> `raw`
- **Expense/label string** - `resolve(expenseCategory:lookup:sources:)` (`expense-precedence.json`):
  local `lookup` -> Plaid built-in -> **Splitwise map** -> passthrough (`explicit`/`raw`). (Plaid is
  tried before Splitwise; Splitwise folds imported labels like "Dining out" into canonical buckets.)
- `needsRefinement(transaction, lookup)` (`needs-refinement.json`): true iff **no override**,
  `source == .plaid`, raw non-empty, not in local `lookup`, and the Plaid built-in yields `null` or
  `"Other"` - i.e. the row is vague enough to benefit from a description-based AI pass.

---

## Itemized spend attribution

Reference: `Logic/ItemizedSpend.swift`. Fixtures: `fixtures/itemized-spend/`.

Breaks an expense (or a transaction) into per-category spend. **Amounts here come from `Decimal`
division, not integer-cents rounding** - a port must use an exact-decimal or rational type and match
the terminating results exactly (the fixtures are chosen to terminate).

### Expense: `categoryContributions(for:me:lookup:)` / `detailed(...)`

Your per-category spend on one expense. `detailed` keeps each contributing item's id (for
drill-through); `categoryContributions` sums it by category. Algorithm:

- Your `owed` = your split's `owedShare` (0 if you're not in the expense).
- **No items** -> a single contribution of `owed` under the expense's canonical category. If `owed <= 0`
  or the category is null/uncanonicalizable, **nothing** (empty).
- **With items**, `honorOwners = (splitwiseExpenseId == null)`. This is the load-bearing rule: a
  Splitwise expense **ignores item owners** (items don't sync there, only the split does), so your
  share is fully proportional; a self-hosted expense honors `ownerIdentifier`.
  1. Items you own -> counted at **full price** under each item's (canonicalized) category.
     `assignedToMe = sum(your item prices)`.
  2. `poolShare = max(owed - assignedToMe, 0)` is your share of the shared pool: the unowned items
     **plus** the non-item remainder (`max(amount - sum(all item prices), 0)`, i.e. tax/tip),
     spread **by price**. Each shared item gets `poolShare * itemPrice / poolTotal`; the remainder
     gets `poolShare * nonItemRemainder / poolTotal`, filed under the expense's own category.
     If `poolTotal == 0`, the whole `poolShare` falls under the expense category.
- Every contribution is dropped if its amount is `<= 0` or its category can't be canonicalized. An
  item's category resolves through the same expense-string resolver (so a raw Plaid label on an item
  is canonicalized); a null item category falls back to the expense's category.
- **Worked example** (honored): amount 100, you owe 60, items [Groceries 50 (yours), Dining 30
  (shared)], remainder 20. You get Groceries 50 + (10 * 20/50)=54 and Dining (10 * 30/50)=6; sums to
  your 60. The same shape as a Splitwise expense: Groceries 42, Dining 18.

### Transaction: `transactionDetailed(for:lookup:)`

A transaction is wholly the viewer's (no owners/splits). Each item counts at **full price** under its
own canonicalized category (null item category -> the transaction's effective category), and the
leftover (`amount - sum(item prices)`) falls under the effective category. The amounts sum to
`transaction.amount`. **No items -> empty** (the caller emits a single flat event instead). The
"effective category" is the transaction precedence result (`resolve(for:)`). Example: amount 100,
category `FOOD_AND_DRINK` (-> Dining), items [Groceries 30, (null) 20] -> Groceries 30, Dining 70.

---

## Account classification

Reference: `Logic/AccountClassification.swift` (+ the `Account` extension). Fixtures:
`fixtures/account-classification/`.

The backend exposes no explicit asset/liability flag, so an account's kind is derived from its Plaid
subtype string. Three kinds, with canonical persisted strings: `cashFlow` -> `"cash_flow"`,
`liability` -> `"liability"`, `holdings` -> `"savings"` (shown to the user as "Savings").

- `classify(type)`: lowercase the subtype, then it's `liability` if in `liabilitySubtypes` (13 entries,
  incl. the top-level `credit`/`loan` fallbacks), `holdings` if in `holdingsSubtypes` (27 entries),
  else `cashFlow`. Both sets are pinned in full (`classify.json`). Note `"savings"` is a **deposit**
  account -> `cashFlow`, not holdings; unknown/null/empty -> `cashFlow`.
- `AccountKind(canonical:)` accepts `cash_flow`/`liability`/`savings` and the **legacy alias
  `holdings`** (-> holdings); anything else -> null (`canonical.json`).
- Account computed flags (`account-flags.json`):
  - `kind` = a valid `kindOverride` wins, else `classify(type)`.
  - `countsInSpending` = `includeInSpending ?? (kind is cashFlow or liability)` - spend counts wherever
    it happens (incl. cards).
  - `countsInCashFlow` = `includeInCashFlow ?? (kind is cashFlow)` - so a card payment from checking
    isn't double-counted. A per-account include flag overrides the classification.
  - `isPlaid` = `plaidAccountId != null`; `isImported` = not Plaid but has a non-empty
    `institutionName` (OFX); `isManual` = neither.
  - `displayLabel` = non-blank `displayName` else `name`. `maskLabel` = non-blank `mask` rendered as
    `"•••• <mask>"`, else null.

These flags feed the spend/dedup engine's per-source inclusion (below).

---

## Spend / dedup engine

Reference: `Logic/SpendingAnalytics.swift`. Fixtures: `fixtures/spend-engine/`. Builds on
account-classification (per-source flags) and itemized-spend (attribution).

`spendEvents(transactions, accounts, lookup, expenses, groups, me)` builds one unified
`SpendEvent` stream. **Sign convention: `amount > 0` is outflow (spend), `< 0` is inflow.**
Order is transactions (input order) then, if `me != null`, expenses (input order); itemized rows
expand in place.

- **Transactions** (only `plaid`/`manual`/`simplefin`):
  - **Dedup (the headline):** a transaction whose id is any expense's `transactionId` is **dropped**
    - the linked expense's owed share represents that real payment, so a shared bill paid from your
    bank isn't double-counted.
  - `plaid`/`simplefin` with **no account are skipped**; `manual` cash (no account) counts.
  - Inclusion: `includeInSpending`/`includeInCashFlow` = the transaction's own flag, else the
    account's `countsInSpending`/`countsInCashFlow` (from account-classification), else true.
  - An itemized outflow (`amount > 0` with items) expands via `transactionDetailed`; otherwise a
    single event at the transaction's effective category and amount.
- **Expenses** (only when `me != null`): counted at your owed share.
  - Category is canonicalized; **neutral** (`Transfer`/`Settle-up`) is dropped.
  - **incomeLike** is a negative inflow: `Reimbursement` uses your `paidShare`, `Income` uses your
    `owedShare`; skipped if that inflow `<= 0`.
  - Itemized outflow expands via `ItemizedSpend.detailed`; otherwise a single event at your
    `owedShare` (skipped if `<= 0`, i.e. you're not in the expense).
  - Inclusion: the expense's own flag, else its group's, else true.
- `isSpend(event)` = `countsInSpending && amount > 0 && category != null && category not in
  excludedFromSpend`.
- `byCategory(in month)` sums `isSpend` events whose `monthStart` equals the target month, by
  category. **Month bucketing uses the device-local calendar** - fixtures use mid-month noon-UTC
  dates so the bucket is timezone-stable. (`monthlySpending`/`monthlyNetIncome`/`monthRange` are
  captured with the goals/periods module, where `SpendPeriod` lives.)

---

## Subscription detection

Reference: `Logic/SubscriptionDetector.swift`. Fixtures: `fixtures/subscriptions/`. Groups charges by
`MerchantText.key` (below).

- **Cadence bands** `SubscriptionCadence.classify(medianDays)` (inclusive): weekly `5...9`, biweekly
  `11...17`, monthly `24...37`, quarterly `80...100`, yearly `330...400`; anything else -> none.
- **Cadence table**: periodsPerYear / days / unit / label - weekly 52/7/wk, biweekly 26/14/2wk,
  monthly 12/30/mo, quarterly 4/91/qtr, yearly 1/365/yr.
- **Computed**: `annualCost = latestAmount * periodsPerYear`; `monthlyEquivalent = annualCost/12`;
  `increased = priorAmount != null && latestAmount > priorAmount`.
- **Rule match** `matches(amount, rule)`: both `> 0` and `max/min <= 2.0` (a ~2x band, so a price
  increase keeps matching).
- **Pipeline** `analyze/detect`: build an event stream (transactions: plaid/manual/simplefin,
  `amount > 0`, not linked to an expense, category not excludedFromSpend; expenses when `me != null`:
  owed share, category not neutral/incomeLike), grouped by merchant key. Per group, sorted by date:
  - `intervals` = day gaps between consecutive events (same-day dropped). `median(intervals)` ->
    cadence, else none. `band = cadence.days`.
  - `regularity` = fraction of intervals within `±40%` of the band.
  - `amountClusters` = median amount `> 0` and every amount's ratio to it in `[0.5, 1.8]`.
  - `enough` = count `>= (yearly ? 2 : 3)`.
  - **subscription** if `enough && regularity >= 0.6 && amountClusters`; else **candidate** if
    `count >= 3 && regularity >= 0.5`; else none. latest/prior are the last two events; `isShared` if
    any event came from an expense. Subscriptions sort by annualCost desc, candidates by amount desc.

### MerchantText (shared grouping helper)

`MerchantText.key(details)` (used here and by matching/brand/templates): lowercase, replace every
non-letter with a space, split on whitespace, drop words `< 3` chars or in the noise set (payment
plumbing / geography / suffixes), then join the **first 3** remaining words with a space.
`tokens` is the unordered set of those words. (Full MerchantText fixtures land with the merchant/brand
module; the reference replayer already implements it here.)

---

## Transaction matching

Reference: `Logic/TransactionMatcher.swift`. Fixtures: `fixtures/matching/`.

Ranks which transactions best match an expense (basis for the "link a transaction" suggestions).
**Scores use `Double`/`exp`, so fixtures assert ranked order + inclusion, not raw scores** - a port
should reproduce the ranking and the pre-gate/window inclusion, and may differ in the last ULP of a
score. Constants:

- Pre-gate `minAmountScore = 0.6`; decays `kAmount` 60 strict / 12 recurring, `kDate` 0.12 strict /
  0.05 recurring; `recurringBonus = 0.05`; weights `wAmount 0.55`, `wDate 0.35`, `wName 0.10`;
  `limit 8`, `windowDays 21`.
- `confidenceLabel(score)`: `>= 0.8` Strong, `0.5..<0.8` Likely, else Possible.
- `tokens(text)`: lowercase, split on any non-alphanumeric, keep tokens length `>= 2` not in the
  matcher stop-word set. (This stop set is **distinct** from MerchantText's noise set.)
- Score: `relAmount = min(relDiff(amount, fullBill), relDiff(amount, myPaidShare))` where
  `relDiff(a,b) = |a-b|/b` (inf if `b <= 0`) - so a match against either the full bill or the
  caller's paid share counts. `amountScore = exp(-kAmount * relAmount)`; **gated `>= 0.6`** or the
  candidate is dropped. `dateScore = exp(-kDate * days)`. `nameScore = overlap coefficient
  |A n B| / min(|A|,|B|)` over tokens. `score = 0.55*amount + 0.35*date + 0.10*name`, plus the
  recurring bonus (capped at 1). Recurring (`expense.repeats == true`) uses the gentler decays.
- `transactionCandidates`: excludes transactions already linked to another expense, applies the
  `±windowDays` window, scores, sorts desc, takes `limit`. `expenseCandidates` is the symmetric
  reverse flow (excludes neutral expenses).

---

## Merchant / brand normalization

Reference: `Logic/MerchantText.swift`, `Brand.swift`, `RelatedTransactions.swift`. Fixtures:
`fixtures/merchant-brand/`.

- **MerchantText** (also used by subscriptions/matching): `words` = lowercase, every non-letter ->
  space, split, drop words `< 3` chars or in the noise set; `key` = first 3 words joined; `tokens` =
  the set.
- **BrandMatcher.compile(pattern)** over an already-lowercased haystack, three syntaxes checked in
  order: `/.../ ` slash-wrapped -> regex (case-insensitive); contains `*`/`?` -> glob (`*`=`.*`,
  `?`=`.`, other chars escaped); else plain substring. All unanchored; a malformed `/regex/` never
  matches.
- **MerchantParse**:
  - `cleaned` - strip a leading processor prefix (`<= 8`-char alnum/space token ending in `*`), drop
    interior store-ref tokens (`>= 3` digits, or pure punctuation), drop trailing store-number /
    2-letter-state / USA noise. Short brand numbers (`5 Guys`) are kept. Empty result -> the trimmed
    original.
  - `embeddedDomain` - first domain whose suffix is a known TLD (allowlist), leading `www.` dropped;
    else null.
- **RelatedTransactions**:
  - `amountsClose(a,b)` = `hi-lo <= 1 || hi*4 <= lo*5` (within $1 or 25%) - a shared constant also
    used by MerchantPreferences.
  - `group(seed, strictness, amount)` - filter by merchant strictness (`fuzzy` any shared token /
    `balanced` overlap `> 0.5` / `strict` one token set contains the other / `exact` same key) and an
    amount constraint (`any`/`close`/`equal`), sorted date-desc.
  - `commonTokens` = sorted intersection of every item's tokens; `displayName` = title-cased first 3
    `cleaned` words.

> Not fixtured here: the ~60-entry `BrandCatalog.builtins` table (server-managed at runtime via
> `BrandCatalogStore`) and the private `brandRelatesToMerchant` precision guard (no public entry
> point). Both are documented in the source; the guard's behavior is described in `Brand.swift`.

---

## Household budget

Reference: `Logic/HouseholdBudget.swift`. Fixtures: `fixtures/household-budget/`. Builds on
itemized-spend.

Combined budgeting where **both partners' spend counts toward one limit**, computed on-device so both
phones independently arrive at the same number.

- `membership(members)` -> `[groupId: {memberIdentifier}]`; `sharedGroupIds(viewer, partners,
  membersByGroup)` = groups whose members contain the viewer **and** at least one partner.
- `combinedByCategory(month, expenses, sharedGroupIds, viewer, partners)`: over shared-group expenses
  in the target month only, each member's per-category owed share via
  `ItemizedSpend.categoryContributions(me:, lookup:)` with a **deterministic empty lookup** - the load-
  bearing detail: skipping per-user category overrides is how both partners' devices resolve the same
  canonical category for the same expense. `mine` = viewer's share, `partnerTotal` = sum of partners'
  shares, `combined = mine + partnerTotal`. Solo/unshared expenses and other months never enter.
- Month bucketing uses the shared device-local calendar (fixtures use noon-UTC dates).

> Not fixtured: `contributors(...)` (the drill-through row projection - presentation), captured by
> reference in the source.

---

## Goals / periods

Reference: `Logic/GoalProgress.swift`, `SpendPeriod.swift`, plus the monthly aggregations in
`SpendingAnalytics.swift`. Fixtures: `fixtures/goals/`.

- **GoalProgress** (fractions are `Double`):
  - `budgetStatus(spent, target)`: `target <= 0` -> `over` if `spent > 0` else `under`; `spent >
    target` -> `over`; `fraction >= 0.85` -> `nearing` else `under`. (Exactly at target -> `nearing`.)
  - `budgetFraction` = `spent/target` clamped `0...1` (`target <= 0` -> 1 if spent else 0).
  - `saveFraction`: `balance` = `(current-starting)/(target-starting)` clamped, with a
    `needed <= 0` shortcut (met iff `current >= target`); `amount` = `(current-starting)/target`
    clamped (`target <= 0` -> 0).
- **SpendPeriod.resolve(anchor, now)** -> inclusive first-of-month `[start, end]` + `months` count.
  `.month` uses the anchor; `last3/6/12` are rolling from `now`'s month; `yearToDate` is Jan-of-now ->
  now; `previousYear` is the full prior calendar year. Labels are locale-formatted (not asserted).
- **Monthly aggregations** (device-local calendar; fixtures use noon-UTC dates): `monthRange(months,
  ending)` = first-of-month dates oldest->newest; `monthlySpending` = zero-filled per-month isSpend
  totals; `monthlyNetIncome` = per-month `inflow - outflow` over cash-flow events, income/reimbursement
  as inflow, neutral excluded.

---

## Receipt heuristics

Reference: `Logic/ReceiptHeuristics.swift`, `ExpensePrefill.swift`. Fixtures: `fixtures/receipts/`.

The model-free fallback when Apple Intelligence isn't available (the on-device AI extraction path is a
capability adapter, not fixtured).

- `parse(text).merchant` = first non-empty trimmed line.
- `parse(text).total` = the max amount on a line containing `total` (but **not** `subtotal`); if no
  such line, the max amount anywhere; null if no amounts. Amounts match `\d[\d,]*\.\d{2}` with commas
  stripped.
- `parse(text).date` uses `NSDataDetector` - **not captured** (platform-specific; no portable
  equivalent).
- `recentReceiptDate(date, now, window=60)` clamps a scanned date to `[today-window, today]` (start of
  day); a future or too-old date, or nil, -> today. Guards a wrong-year OCR extraction.

---

## Suggestions + ranking

Reference: `Logic/SuggestionRanking.swift`, `SplitTemplateLearning.swift`. Fixtures:
`fixtures/suggestions/`.

- **SuggestionRanking** (`score` uses `Double`/`exp`, so `ranked` asserts order):
  - `typeWeight`: link/recurringSplit `4`, categorize `3`, nudges (overspend/nearingBudget/settleUp/
    sharedBudgetCandidate) `2`, subscription `1`.
  - `recency(date, now)` = `exp(-ageDays / 30)` (30-day half-life); dateless -> `0.5`.
  - `confidence`: link = `matchScore ?? 0.85`; recurringSplit `1.0`; categorize
    `min(max(count,1)/10, 1)`; subscription `0.5`; nudges `0.6`.
  - `score = typeWeight + 1.0*recency + 0.5*confidence`. `ranked` sorts by score desc, ties by `id`
    asc, caps at `maxCards = 28`.
- **SplitTemplateLearning.derive(expenses, minOccurrences=2)**: a merchant qualifies with
  `>= minOccurrences` shared (`>= 2` owed-positive splits), transaction-linked, non-neutral expenses in
  a **single** group; the template stores the averaged owed-split fractions (`Double`).

> Not fixtured: the full `SuggestionEngine` pass orchestration (link/categorize/subscription/recurring
> passes + nudges) - a large integration over the matcher, subscription detector, household budget, and
> category resolver, all of which are captured individually above. Its thresholds are documented in the
> source (`defaultLinkThreshold 0.85`, `recurringWindowDays 60`, `maxSubscriptionCards 8`,
> `linkScanCap 200`, `sharedBudgetFloor $50`, `settleUpThreshold $5`) and its building blocks are pinned;
> capturing the orchestration end-to-end is a candidate follow-up.

---

## (Remaining modules)

Captured per the plan; see the status table above. Each module section follows the same shape:
representation notes, then one subsection per function/rule with its constants and a worked example
that corresponds to a fixture case.
