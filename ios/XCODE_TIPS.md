# Xcode tips - diagnose without rebuilding on device

A running list of ways to inspect/iterate on the Cleave iOS app **without** the slow loop of "build →
install on phone → tap around." Add to it as we find more.

## SwiftUI Previews (the fastest loop)

The project has preview scaffolding (`Views/PreviewSupport.swift`, all `#if DEBUG`). Open a view file and show
the canvas: **⌥⌘↩** (or the top-right editor toggle). Two patterns:

- **Presentational views** (take their data as parameters - `DetailHeader`, `ItemListRow`, rows, badges): just
  pass inline sample data. No environment needed. See the examples at the bottom of `Views/DetailComponents.swift`.
  ```swift
  #Preview("ItemListRow") {
      List { ItemListRow(name: "House Wine", category: "Alcohol", owner: "Bob", price: "$12.00") }
  }
  ```
- **Environment / `@Query`-backed screens**: inject an offline `AppEnvironment` + an in-memory SwiftData store
  with `.previewEnvironment()` (see `ServerSettingsView.swift`'s preview):
  ```swift
  #Preview { NavigationStack { SomeView() }.previewEnvironment() }
  ```
  Caveat: it's offline, so network/`@Query` screens render their **empty/loading** state. For populated data,
  seed the in-memory store from a **non-SwiftUI file** (the `@Model` types `Group`/`Transaction` collide with
  SwiftUI's same-named types, so you can't construct them in a file that `import SwiftUI`).

### Preview power-tools
- **`@Previewable @State`** - put `@State` directly in a `#Preview` to preview binding/stateful views
  *interactively* (a real working toggle instead of `.constant(true)`):
  ```swift
  #Preview { @Previewable @State var on = true
      Form { BudgetFlagsSection(includeInSpending: $on, includeInCashFlow: .constant(false), footer: "...") } }
  ```
- **Variants button** (bottom of the canvas) - auto-renders across **color schemes, Dynamic Type sizes,
  orientations** in a grid. Instant dark-mode + large-text QA.
- **Multiple `#Preview("name") {}`** per file → tabbed previews in the canvas.
- **Live vs Selectable** (canvas toolbar) - Live = tap/scroll the preview; Selectable = click a rendered
  element to jump to its code.

## When previews aren't enough

- **`#Playground` (Xcode 26)** - inline-evaluate a snippet with live results, no test target. Perfect for pure
  logic: `TransactionMatcher` scoring, `CategoryMapping.canonical(...)`, formatting helpers - poke values
  without a full build/run.
- **View Hierarchy Debugger** - run the app (sim), then Debug ▸ View Debugging ▸ Capture View Hierarchy. A 3D
  exploded view of the *live* UI: the fast way to find overlap / clipping / wrong-frame issues (e.g. the
  header-text-wrap bug).
- **Instruments ▸ SwiftUI template** - view-body **re-render counts** + "cause of update." The tool that pins
  down "why is this list janky" (cf. the `@Query`-derived-dict-per-row freeze). Also: **Time Profiler**
  (CPU hotspots), **Allocations/Leaks** (memory).

## Simulator tricks (no device needed)
- **Drag a photo onto the Simulator** → lands in Photos. Exercises the receipt-scan / PhotosPicker flow.
- Features ▸ **Slow Animations** (⌘T); Debug ▸ **Color Blended Layers** / **Color Misaligned Images** for
  overdraw/perf; Device ▸ Erase All Content and Settings for a clean-slate onboarding test.
- Point the app at a local backend: sim reaches the host at `http://localhost:8000` (a physical device needs
  the tunnel host or the Mac's LAN IP).

## Correctness diagnostics (turn on in the scheme ▸ Diagnostics)
- **Main Thread Checker** - flags UI/SwiftData mutations off the main thread.
- **Thread Sanitizer** - data races (relevant with the `@MainActor` repos + SwiftData).
- **Address/Undefined-Behavior Sanitizer** - memory bugs.

## Misc
- **SF Symbols app** - browse/validate `systemImage` names before typing them (avoids the "that symbol
  doesn't exist" class of bug, e.g. `camera.badge.plus`).
- Debugger: `po <expr>` / `expression` to inspect state live; conditional + symbolic breakpoints.

## Quick reference - symptom → tool
| Symptom | Reach for |
|---|---|
| Tweak a view's look/layout | SwiftUI Preview (+ Variants for dark/large-text) |
| Check a binding/stateful view interactively | `@Previewable @State` in a `#Preview` |
| "Is my pure function right?" | `#Playground` (or a unit test) |
| Views overlap / clip / wrong size | View Hierarchy Debugger |
| List/scroll is janky, too many redraws | Instruments ▸ SwiftUI (re-render counts) |
| Crash "on background thread" / weird races | Main Thread Checker / Thread Sanitizer |
| Receipt/photo flow | Drag a photo onto the Simulator |
