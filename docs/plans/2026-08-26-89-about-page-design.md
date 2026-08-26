# #89 — About page: Release-visible version + sync status (design)

2026-08-26. Issue: https://github.com/nicolovejoy/raconte/issues/89

Designed autonomously (owner away, pre-approved "carry on SDD"); decisions below are
recorded with reasoning so any of them can be cheaply reversed.

## Problem

Release/TestFlight builds have zero on-device sync visibility: the Debug screen — the
only UI showing account state, pending counts, last push/fetch, last error — is
`#if DEBUG`-gated in four places. Five sessions have paid for the absence; on 2026-08-26
it blocked diagnosis of a live bug (images not propagating — cannot tell from the phone
whether sync is even running, or against which CloudKit environment). Scope additions
from the issue comment and the 2026-08-26 session:

- app **version + build** (CFBundleShortVersionString / CFBundleVersion)
- the **CloudKit environment tag** (Development/Production), which #90 already detects
  via `CloudKitEnvironment.detectFromBundle` — would have made the current
  environment-split question a 5-second glance.

## Decision summary

A new **About** place: a read-only screen visible in every build configuration,
reachable from the sidebar on all platforms. Everything it shows already exists in the
app (`SyncStatus` via `SyncCoordinator.status()`, Info.plist, `detectFromBundle`) — this
is surfacing, not new machinery.

### Navigation

- `Place.about` — a new case, **not** `#if`-gated (matches the `.debug` precedent: the
  case is always a member so `PlaceRouting`'s switches stay exhaustive with no
  `default:`; only listing is configuration-dependent — and About is listed always).
- Sidebar row in ALL builds: title "About", `systemImage: "info.circle"`,
  accessibility identifier `sidebar.about`, positioned **after Trash, before Debug**.
  Rationale: Capture and the journals are the daily surfaces; About is bottom-of-list
  utility, and keeping Debug last preserves the owner's muscle memory.
- macOS Go menu: an "About" item below Trash, **no digit shortcut** — the nav plan
  locked "fixed-place digits ⌘1-4" and Debug already owns ⌘4 in DEBUG builds; About is
  not a frequent-enough destination to justify renumbering. The system app-menu "About
  Raconte" box is left untouched.
- Exhaustive-switch updates, each explicit (repo no-`default:` convention):
  `PlaceRouting.resolve` (returns itself), `PlaceRouting.journalScope` (nil),
  `ContentView.detailRoot` (routes to `AboutView`), `ContentView.libraryTitle`
  (falls in the non-library group).

### AboutView (new, `Raconte/App/AboutView.swift`, NOT `#if DEBUG`)

A `List` with two sections, `.navigationTitle("About")`, identifier `about.list`:

**Section "App"**
- Version row: `LabeledContent("Version", value:)` → e.g. `1.0 (7)`, from a new pure
  helper (below). Identifier `about.version`.
- Environment row: `LabeledContent("CloudKit", value:)` → `Production` /
  `Development`, from `CloudKitEnvironment.detectFromBundle()`. Identifier
  `about.environment`. Computed **once in `.task`**, never inline in `body` — the
  detection reads the embedded provisioning profile off disk (same
  compute-once-in-`.task` idiom as `DebugMenuView.buildInfo`). Display via
  `rawValue.capitalized` — no new mapping table.
- The environment is detected by the view itself rather than plumbed out of
  `SyncCoordinator` so the row still renders when sync is unavailable (nil
  coordinator), and it is byte-for-byte the same detection the environment gate uses.

**Section "Sync"** — the shared component below, with `idPrefix: "about"`.

### SyncStatusSectionView (new, shared, NOT `#if DEBUG`)

The Sync section currently inside `DebugMenuView` (account / last push / last fetch /
pending saves / pending deletes / last error rows, Refresh button, `Loading…` state,
"Sync unavailable in this build" when the coordinator is nil) moves verbatim into
`Raconte/App/SyncStatusSectionView.swift`, used by **both** `AboutView` and
`DebugMenuView`. One rendering of sync status, no duplication to drift.

- Inputs: `sync: SyncCoordinator?`, `idPrefix: String` (identifiers become
  `about.sync.refresh` / `debug.sync.refresh`; the existing `debug.sync.refresh`
  identifier keeps working unchanged).
- Owns its `@State private var syncStatus: SyncStatus?` and its `.task` initial fetch
  plus the Refresh action — exactly the behavior DebugMenuView has today, relocated.
- Timestamp display: the same local `formatted(date: .abbreviated, time: .standard)`
  the debug screen uses today. Deliberate deviation from the Pacific-display
  convention, recorded: "when did *this device* last push/fetch" is a device-local
  question (and will be for Lori's devices too); the Pacific rule exists for
  cross-machine build comparison and date bucketing, neither of which applies. Cheap
  to revisit.

`DebugMenuView` keeps its Build section (BuildStamp — stays DEBUG-only; the Mach-O/dylib
forensics are developer tooling, and version+build on About answers the Release-side
"which build is this" question) and the breakpoint harness; its Sync section body is
replaced by the shared component.

### AppVersion (new pure helper, `Raconte/App/AppVersion.swift`)

```swift
enum AppVersion {
    static func displayString(short: String?, build: String?) -> String  // pure core
    static func current(bundle: Bundle = .main) -> String                // thin shell
}
```

- `("1.0", "7")` → `"1.0 (7)"`; either component nil/empty → the other alone; both
  absent → `"unknown"`. Never crashes on a malformed Info.plist.
- Pure core is unit-tested directly; the shell just reads
  `CFBundleShortVersionString` / `CFBundleVersion` from the bundle's info dictionary.

## What this deliberately does NOT do

- No last-error history, no log excerpts, no actions beyond Refresh — read-only
  surface, smallest thing that unblocks remote diagnosis (issue asks for exactly this).
- No settings; the screen is "About", not "Settings", until something needs a setting.
- No BuildStamp on the About page (see above).
- Does not touch `SyncCoordinator`, the engine, or any sync behavior.

## Testing

- Unit (TDD for the pure layer):
  - `SidebarModel.rows` includes the About row in both `includesDebug` configurations,
    in the locked position; existing ordering pins updated.
  - `PlaceRouting.resolve(.about)` returns `.about`; `journalScope(.about)` is nil.
  - `AppVersion.displayString` matrix (both present / short only / build only /
    neither).
  - `AppRouterCommandTests` gains the About route (pure half of the Go-menu item).
- UI (simulator): new `AboutUITests` class reaching the screen via
  `openPlace(app, "sidebar.about")` — never a hard-coded tap. Asserts the version row
  exists and is non-empty, the environment row exists, and — since
  `SyncCoordinator.live()` refuses the UI-test harness — the "Sync unavailable in this
  build" degradation row renders. Re-run `NavigationUITests` (sidebar row-set changed).
- The Release-build visibility itself (the actual point) is not machine-testable here:
  it rides to the owner in the next TestFlight build; smoke instructions in the plan's
  final step.
