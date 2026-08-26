# #89 About Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Release-visible About screen showing app version+build, the CloudKit environment tag, and read-only sync status — closing the TestFlight diagnostic blind spot (#89).

**Architecture:** New `Place.about` sidebar destination (all builds) routing to a new `AboutView`. The Debug screen's Sync section is extracted verbatim into a shared, non-DEBUG `SyncStatusSectionView` used by both screens. A pure `AppVersion` helper formats Info.plist version keys. No sync machinery is touched.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency, XcodeGen project, XCTest + XCUITest.

**Spec:** `docs/plans/2026-08-26-89-about-page-design.md` (read it first; it carries the rationale for every decision below).

## Global Constraints

- Xcode project is GENERATED: after clone or any `project.yml` change run `xcodegen generate`. New Swift files under `Raconte/`, `RaconteTests/`, `RaconteUITests/` are picked up by re-running `xcodegen generate` (targets glob whole directories).
- Unit test command (macOS, sandbox REQUIRED — never `CODE_SIGNING_ALLOWED=NO`):
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test`
- iOS compile check:
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- UI tests (simulator only), one class per invocation (the full suite exceeds the Bash 10-minute cap; NEVER background an xcodebuild run):
  `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/<ClassName> test`
- Exhaustive switches over `Place` take a new explicit case, never a `default:` (repo convention — see `Place.swift`'s doc comments).
- UI tests reach places ONLY through `openPlace(app, "sidebar.…")` from `RaconteUITests/UITestNavigation.swift` — never a hard-coded navigation tap.
- Accessibility identifiers go on rows/controls, never on a `ForEach`/container that would flatten or overwrite descendants (see `SidebarRowView`'s doc comments). A `List`'s own identifier is fine (`debug.list` precedent).
- Never attach `.sheet`/presentation modifiers to a `Form`/`List` `Section` (repo trap). This plan also avoids `.task` on a `Section` — the initial-fetch `.task` is attached to a row view instead (Task 2).
- Commit after each task with a conventional-commits message ending in the Claude trailer.

---

### Task 1: AppVersion pure helper

**Files:**
- Create: `Raconte/App/AppVersion.swift`
- Test: `RaconteTests/AppVersionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppVersion.displayString(short: String?, build: String?) -> String` and `AppVersion.current(bundle: Bundle = .main) -> String` — Task 2's `AboutView` renders `AppVersion.current()`.

- [ ] **Step 1: Write the failing tests**

`RaconteTests/AppVersionTests.swift`:

```swift
import XCTest
@testable import Raconte

/// #89: the About page's version row. Pure-core matrix — the shell (`current(bundle:)`)
/// is two dictionary reads and is exercised implicitly by the About UI test.
final class AppVersionTests: XCTestCase {

    func testBothComponentsRenderAsMarketingVersionThenBuildInParens() {
        XCTAssertEqual(AppVersion.displayString(short: "1.0", build: "7"), "1.0 (7)")
    }

    func testMissingBuildFallsBackToShortAlone() {
        XCTAssertEqual(AppVersion.displayString(short: "1.0", build: nil), "1.0")
        XCTAssertEqual(AppVersion.displayString(short: "1.0", build: ""), "1.0",
                       "empty string is as absent as nil — never render '1.0 ()'")
    }

    func testMissingShortFallsBackToBuildAlone() {
        XCTAssertEqual(AppVersion.displayString(short: nil, build: "7"), "7")
        XCTAssertEqual(AppVersion.displayString(short: "", build: "7"), "7")
    }

    func testNeitherComponentSaysUnknownRatherThanRenderingEmpty() {
        XCTAssertEqual(AppVersion.displayString(short: nil, build: nil), "unknown")
        XCTAssertEqual(AppVersion.displayString(short: "", build: ""), "unknown")
    }

    func testCurrentReadsTheHostBundlesRealKeys() {
        // The unit suite runs hosted in the real Raconte.app, whose Info.plist
        // carries both keys — so this pins the shell's key names against a live
        // bundle rather than a fixture.
        let result = AppVersion.current()
        XCTAssertNotEqual(result, "unknown")
        XCTAssertTrue(result.contains("("), "expected 'short (build)' from the app bundle, got \(result)")
    }
}
```

- [ ] **Step 2: Run the new test class to verify it fails to compile (AppVersion undefined)**

Run: the unit test command from Global Constraints with `-only-testing:RaconteTests/AppVersionTests` appended.
Expected: build FAILS with "cannot find 'AppVersion' in scope".

- [ ] **Step 3: Write the implementation**

`Raconte/App/AppVersion.swift`:

```swift
import Foundation

/// #89: the About page's version+build string, e.g. "1.0 (7)". Pure core + thin
/// bundle shell, per the repo's testable-core convention (`CloudKitEnvironment.parse`
/// / `detectFromBundle` is the adjacent precedent).
enum AppVersion {

    /// Pure core. Empty is as absent as nil: a malformed Info.plist must degrade to
    /// a readable string, never crash and never render "1.0 ()".
    static func displayString(short: String?, build: String?) -> String {
        let short = short.flatMap { $0.isEmpty ? nil : $0 }
        let build = build.flatMap { $0.isEmpty ? nil : $0 }
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil):    return short
        case let (nil, build?):    return build
        case (nil, nil):           return "unknown"
        }
    }

    /// Thin shell: CFBundleShortVersionString is the marketing version ("1.0"),
    /// CFBundleVersion the build number ("7") — the pair TestFlight shows as 1.0 (7).
    static func current(bundle: Bundle = .main) -> String {
        displayString(short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
}
```

- [ ] **Step 4: Run `xcodegen generate`, then the test class again**

Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Raconte/App/AppVersion.swift RaconteTests/AppVersionTests.swift
git commit -m "feat(about): AppVersion pure helper for the version+build row (#89)"
```

---

### Task 2: SyncStatusSectionView extraction + AboutView

**Files:**
- Create: `Raconte/App/SyncStatusSectionView.swift`
- Create: `Raconte/App/AboutView.swift`
- Modify: `Raconte/Capture/Debug/DebugMenuView.swift` (Sync section body → shared component; drop its `syncStatus` state and the sync half of its `.task`)

**Interfaces:**
- Consumes: `AppVersion.current()` (Task 1); existing `SyncCoordinator.status() async -> SyncStatus` (fields: `accountState: String`, `lastPushAt: Date?`, `lastFetchAt: Date?`, `pendingSaveCount: Int`, `pendingDeleteCount: Int`, `lastError: String?`); existing `CloudKitEnvironment.detectFromBundle() -> CloudKitEnvironment`.
- Produces: `SyncStatusSectionView(sync: SyncCoordinator?, idPrefix: String)` and `AboutView(sync: SyncCoordinator?)` — Task 3 routes `Place.about` to `AboutView(sync: services.sync)`.

- [ ] **Step 1: Create the shared section**

`Raconte/App/SyncStatusSectionView.swift`:

```swift
import SwiftUI

/// The read-only sync status rows, shared verbatim between the Debug screen (where
/// they lived since M4 T12) and the About page (#89) — one rendering, no drift.
///
/// `idPrefix` keeps each host's accessibility namespace: "debug" preserves the
/// pre-existing `debug.sync.refresh`; "about" yields `about.sync.*`.
///
/// The initial fetch rides a `.task` on the Loading row, NOT on the `Section`: this
/// repo has already been bitten by a modifier on a `Form`/`List` `Section` silently
/// doing nothing (`.sheet`, 2026-08 — mechanism unconfirmed), so no Section-level
/// modifiers here on principle. The Loading row exists exactly until the first
/// status arrives, so its `.task` fires exactly once per appearance of this section.
struct SyncStatusSectionView: View {
    let sync: SyncCoordinator?
    let idPrefix: String

    /// M4 T12 semantics unchanged: fetched on appear and on demand (Refresh) —
    /// this can genuinely change while the screen is open.
    @State private var syncStatus: SyncStatus?

    var body: some View {
        Section("Sync") {
            if let sync {
                if let syncStatus {
                    LabeledContent("Account", value: syncStatus.accountState)
                    LabeledContent("Last push",
                                  value: syncStatus.lastPushAt.map(Self.timestamp(_:)) ?? "never")
                    LabeledContent("Last fetch",
                                  value: syncStatus.lastFetchAt.map(Self.timestamp(_:)) ?? "never")
                    LabeledContent("Pending saves", value: "\(syncStatus.pendingSaveCount)")
                    LabeledContent("Pending deletes", value: "\(syncStatus.pendingDeleteCount)")
                    LabeledContent("Last error", value: syncStatus.lastError ?? "none")
                } else {
                    Text("Loading…")
                        .task { syncStatus = await sync.status() }
                }
                Button("Refresh") { Task { syncStatus = await sync.status() } }
                    .accessibilityIdentifier("\(idPrefix).sync.refresh")
            } else {
                Text("Sync unavailable in this build")
                    .accessibilityIdentifier("\(idPrefix).sync.unavailable")
            }
        }
    }

    /// Device-local time, deliberately NOT the Pacific-display convention: "when did
    /// THIS device last push/fetch" is a device-local question (design doc records
    /// the deviation). Same formatter the Debug screen has used since M4 T12.
    private static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
```

- [ ] **Step 2: Create AboutView**

`Raconte/App/AboutView.swift`:

```swift
import SwiftUI

/// #89: the Release-visible diagnostic surface — version+build, CloudKit environment,
/// and read-only sync status. Exists because five sessions paid for TestFlight builds
/// having zero on-device sync visibility (the Debug screen is `#if DEBUG`-gated).
/// Read-only by design: no actions beyond Refresh, no settings.
struct AboutView: View {
    /// Nil in every build `SyncCoordinator.live()` refuses (XCTest host, UI-test
    /// harness, preview, nocloud-signed) — the Sync section degrades to an
    /// explanatory row rather than hiding, same contract as the Debug screen.
    let sync: SyncCoordinator?

    /// Detected here rather than plumbed from `SyncCoordinator` so the row still
    /// renders when sync is unavailable — and it is byte-for-byte the same detection
    /// the environment gate uses (`CloudKitEnvironment.detectFromBundle`). Reading
    /// the embedded provisioning profile is file I/O: compute once in `.task`, never
    /// inline in `body` (same idiom as `DebugMenuView.buildInfo`).
    @State private var environment: CloudKitEnvironment?

    var body: some View {
        List {
            Section("App") {
                LabeledContent("Version", value: AppVersion.current())
                    .accessibilityIdentifier("about.version")
                LabeledContent("CloudKit", value: environment.map { $0.rawValue.capitalized } ?? "…")
                    .accessibilityIdentifier("about.environment")
            }
            SyncStatusSectionView(sync: sync, idPrefix: "about")
        }
        .navigationTitle("About")
        .accessibilityIdentifier("about.list")
        .task {
            if environment == nil {
                environment = await Task.detached(priority: .utility) {
                    CloudKitEnvironment.detectFromBundle()
                }.value
            }
        }
    }
}

#Preview {
    NavigationStack { AboutView(sync: nil) }
}
```

- [ ] **Step 3: Refactor DebugMenuView to use the shared section**

In `Raconte/Capture/Debug/DebugMenuView.swift`:
1. Delete the `@State private var syncStatus: SyncStatus?` property (and its doc comment).
2. Replace the entire `Section("Sync") { … }` block (the `if let sync` / rows / Refresh / else branch) with:

```swift
            // M4 T12 (design §8) — rows extracted to `SyncStatusSectionView` when #89
            // gave them a second, Release-visible host (the About page).
            SyncStatusSectionView(sync: sync, idPrefix: "debug")
```

3. In the `.task`, delete the `if let sync, syncStatus == nil { syncStatus = await sync.status() }` lines, leaving only the `buildInfo` fetch.

Nothing else in the file changes — Build section, harness section, `timestamp` helper (delete `timestamp(_:)` too: its only caller was the removed section).

- [ ] **Step 4: Regenerate and run the full unit suite**

Run: `xcodegen generate`, then the unit test command from Global Constraints (full suite, no `-only-testing`).
Expected: PASS with 0 failures, same test count as baseline plus Task 1's 5 (record the number).

- [ ] **Step 5: Commit**

```bash
git add Raconte/App/SyncStatusSectionView.swift Raconte/App/AboutView.swift Raconte/Capture/Debug/DebugMenuView.swift
git commit -m "feat(about): AboutView + shared SyncStatusSectionView extracted from the Debug screen (#89)"
```

---

### Task 3: Place.about wiring — sidebar, routing, Mac menu

**Files:**
- Modify: `Raconte/App/Place.swift` (`Place` enum, `SidebarModel.rows`, `PlaceRouting.resolve`, `PlaceRouting.journalScope`)
- Modify: `Raconte/App/ContentView.swift` (`detailRoot` switch ~:163, `libraryTitle` switch ~:190)
- Modify: `Raconte/App/RaconteCommands.swift` (Go menu)
- Test: `RaconteTests/PlaceRoutingTests.swift`, `RaconteTests/AppRouterCommandTests.swift`

**Interfaces:**
- Consumes: `AboutView(sync:)` (Task 2).
- Produces: `Place.about` listed in the sidebar of every build at identifier `sidebar.about` — Task 4's UI test reaches it via `openPlace(app, "sidebar.about")`.

- [ ] **Step 1: Update the unit tests first (they will fail to compile / fail until Step 3)**

In `RaconteTests/PlaceRoutingTests.swift`:

1. `testRowsAreCaptureThenEveryJournalInDisplayOrderThenAllEntriesThenTrash` — the expected places array becomes:

```swift
        XCTAssertEqual(rows.map(\.place),
                       [.capture, .journal("j1"), .journal("j2"), .allEntries, .trash, .about],
                       "j1 (older) must render before j2 (newer) despite arriving second")
```

2. `testDebugRowIsLastAndOnlyWhenIncluded` — pin About's position in both configurations:

```swift
    func testDebugRowIsLastAndOnlyWhenIncluded() {
        let without = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: false)
        XCTAssertFalse(without.contains { $0.place == .debug })
        XCTAssertEqual(without.last?.place, .about, "#89: About is last when Debug is not listed")
        let with = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: true)
        XCTAssertEqual(with.last?.place, .debug)
        XCTAssertEqual(with.dropLast().last?.place, .about, "#89: About sits between Trash and Debug")
    }
```

3. `testFixedRowsMatchTheLockedTitlesSymbolsAndIdentifiers` — add one row to the `expected` table, between trash and debug:

```swift
            (.about, "About", "info.circle", "sidebar.about"),
```

4. `testJournalScopePerPlace` — add alongside the existing nil-scope assertions:

```swift
        XCTAssertNil(PlaceRouting.journalScope(for: .about))
```

5. Add a resolve pin next to `testAJournalPlaceForAMissingJournalFallsBackToCapture`:

```swift
    func testAboutResolvesToItself() {
        XCTAssertEqual(PlaceRouting.resolve(.about, journals: []), .about)
    }
```

In `RaconteTests/AppRouterCommandTests.swift`, extend `testCommandTargetsAreTheRouterFunctions` (the pure half of the new Go-menu item):

```swift
        router.select(.about)
        XCTAssertEqual(router.place, .about, "#89: the Go menu's About item routes here")
```

- [ ] **Step 2: Run PlaceRoutingTests to verify failure**

Run: the unit test command with `-only-testing:RaconteTests/PlaceRoutingTests`.
Expected: build FAILS ("type 'Place' has no member 'about'").

- [ ] **Step 3: Implement the wiring**

`Raconte/App/Place.swift`:

1. Add the case (the enum's doc comment already explains why cases are never `#if`-gated; About is additionally *listed* unconditionally):

```swift
enum Place: Hashable, Sendable {
    case capture
    case journal(String)      // journal id
    case allEntries
    case trash
    case about
    case debug
}
```

2. In `SidebarModel.rows`, between the `.trash` append and the `includesDebug` block:

```swift
        // #89: Release-visible diagnostics (version, environment, sync status). Listed
        // in EVERY build — bottom-of-list utility, but Debug stays last where the
        // owner's muscle memory expects it.
        rows.append(PlaceRow(place: .about,
                             title: "About",
                             subtitle: nil,
                             systemImage: "info.circle",
                             journalID: nil,
                             accessibilityIdentifier: "sidebar.about"))
```

3. `PlaceRouting.resolve` — add `.about` to the self-resolving case list:

```swift
        case .capture, .allEntries, .trash, .about, .debug:
            return place
```

4. `PlaceRouting.journalScope` — add `.about` to the nil group:

```swift
        case .capture, .trash, .about, .debug:
            return nil
```

`Raconte/App/ContentView.swift`:

5. In `detailRoot`, before `case .debug:`:

```swift
        case .about:
            AboutView(sync: services.sync)
```

6. In `libraryTitle`, extend the non-library group:

```swift
        case .capture, .trash, .about, .debug:
            return "Library"
```

`Raconte/App/RaconteCommands.swift`:

7. In `CommandMenu("Go")`, after the Trash button and before the `#if DEBUG` Debug button (no digit shortcut — the nav plan locked "fixed-place digits ⌘1-4" and Debug owns ⌘4 in DEBUG builds; design doc records the decision):

```swift
            Button("About")       { services.router.select(.about) }
```

- [ ] **Step 4: Run the full unit suite**

Run: `xcodegen generate` (files changed only — regeneration is a no-op but harmless), then the full unit test command.
Expected: PASS, 0 failures. If any test not listed in Step 1 fails, read it before touching it — it may be pinning sidebar shape on purpose; update it to the new locked order only when its own doc comment says that is its job.

- [ ] **Step 5: iOS compile check**

Run: the iOS compile check from Global Constraints.
Expected: BUILD SUCCEEDED (catches any iOS-only branch the macOS test build skipped).

- [ ] **Step 6: Commit**

```bash
git add Raconte/App/Place.swift Raconte/App/ContentView.swift Raconte/App/RaconteCommands.swift RaconteTests/PlaceRoutingTests.swift RaconteTests/AppRouterCommandTests.swift
git commit -m "feat(about): Place.about — sidebar row in all builds, routing, Go-menu item (#89)"
```

---

### Task 4: About UI tests

**Files:**
- Create: `RaconteUITests/AboutUITests.swift`

**Interfaces:**
- Consumes: `sidebar.about` (Task 3), `about.version` / `about.environment` / `about.sync.unavailable` (Task 2), `openPlace(_:_:)` from `RaconteUITests/UITestNavigation.swift`.
- Produces: nothing downstream.

- [ ] **Step 1: Write the UI test**

`RaconteUITests/AboutUITests.swift`:

```swift
import XCTest

/// #89: the About screen renders in the harness build and carries its three
/// diagnostic rows. The harness runs with `SyncCoordinator.live()` refused (nil
/// coordinator), so the Sync section's DEGRADED row is the assertible state here —
/// the live-coordinator rows are owner-smoked on a TestFlight build, where the
/// whole point of this screen (Release visibility) is the thing under test.
final class AboutUITests: XCTestCase {

    private var testID = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        testID = UUID().uuidString
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = testID
        app.launch()
        return app
    }

    func testAboutScreenShowsVersionEnvironmentAndSyncRows() {
        let app = launchApp()
        openPlace(app, "sidebar.about")

        let version = app.descendants(matching: .any)
            .matching(identifier: "about.version").firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10), "version row missing")

        let environment = app.descendants(matching: .any)
            .matching(identifier: "about.environment").firstMatch
        XCTAssertTrue(environment.waitForExistence(timeout: 10), "environment row missing")

        let syncDegraded = app.descendants(matching: .any)
            .matching(identifier: "about.sync.unavailable").firstMatch
        XCTAssertTrue(syncDegraded.waitForExistence(timeout: 10),
                      "harness builds have no sync coordinator — the Sync section must "
                      + "degrade to its explanatory row, never hide")
    }
}
```

- [ ] **Step 2: Run the new class**

Run: `xcodegen generate`, then the UI test command from Global Constraints with `-only-testing:RaconteUITests/AboutUITests`.
Expected: 1 test, PASS. (FOREGROUND run; it fits the cap as a single class.)

- [ ] **Step 3: Re-run NavigationUITests (the sidebar row-set changed under it)**

Run: the UI test command with `-only-testing:RaconteUITests/NavigationUITests`.
Expected: same pass count as baseline, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add RaconteUITests/AboutUITests.swift
git commit -m "test(about): AboutUITests — version, environment, and degraded-sync rows (#89)"
```

---

### Final gate (controller, not a task)

- Full unit suite (macOS nocloud recipe): 0 failures.
- iOS compile check: BUILD SUCCEEDED.
- Whole-branch review subagent, then PR to `main` — merges are the owner's; the branch ends at an open PR. PR body must NOT contain close-verb + #89 (the owner closes after the TestFlight smoke); write "addresses #89".
- The actual Release-visibility claim rides to the owner in the next TestFlight build; the handoff must include self-contained smoke instructions (open the app → sidebar → About → read Version / CloudKit / Sync rows).
