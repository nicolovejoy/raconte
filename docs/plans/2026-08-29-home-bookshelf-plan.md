# Home Bookshelf Landing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace capture-first launch with a Home landing place — 3 face-out journal
covers ranked by capture activity, remaining journals as a quiet serif spine list, one
New entry button — with crash recovery surfacing on Home.

**Architecture:** A new `Place.home` becomes `PlaceRouting.launchPlace`. A pure
`HomeShelf` ranking model feeds a new `HomeView` mounted from `ContentView.detailRoot`.
The capture model's launch bootstrap (recovery scan) gets a second, root-level kick so
it no longer depends on visiting capture; Home renders the same pending recovery
banners capture does.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency,
XcodeGen project, XCTest + XCUITest.

**Spec:** `docs/plans/2026-08-29-home-bookshelf-design.md` (owner-approved, including
the mock choice: quiet list spines, squared corners — covers 8pt, button 12pt).
Approved mock: https://claude.ai/code/artifact/e7f3285c-e0dd-4d39-949a-c49956c486f6

## Global Constraints

- Xcode project is GENERATED: after adding files or editing project.yml, run
  `xcodegen generate`. New Swift files under `Raconte/` and `RaconteTests/`/
  `RaconteUITests/` are picked up by the existing globs — no project.yml edit needed.
- macOS unit-test command (sandbox is NOT optional — never `CODE_SIGNING_ALLOWED=NO`):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test
```

- iOS compile check: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- UI tests (simulator only): `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test` — **the whole RaconteUI
  suite exceeds the Bash tool's 10-minute cap**: run it as several FOREGROUND
  `-only-testing:RaconteUITests/<Class>` invocations and reconcile counts. Never
  background a test run.
- Switch convention: no `default:` in switches over `Place`/`CaptureState` — a new
  case must fail to build where unhandled.
- Colors come from `InkTone` (`Raconte/Library/UI/InkSurface.swift`); paper `#F7F4EE`,
  accent `#916438`. Never `Color(white:)` on unpinned backgrounds.
- UI tests navigate via `openPlace(app, "sidebar.…")` from
  `RaconteUITests/UITestNavigation.swift` — never hard-code navigation taps.
- Test fixtures that carry capture ids must use real ULIDs (`ULID.make()`), never
  literals like "R0" — bad ids parse to nil and silently skip the code under test.
- Commit after each task; do NOT push or merge (merges are Nico's).

---

### Task 1: HomeShelf ranking model (pure)

**Files:**
- Create: `Raconte/Home/HomeShelfModel.swift`
- Test: `RaconteTests/HomeShelfModelTests.swift`

**Interfaces:**
- Consumes: `Journal` (fields `id: String`, `name: String`; ordering helper
  `Array<Journal>.displayOrdered` — createdAt ascending, id tie-break),
  `EntryListItem` (fields `captureID: String`, `journalID: String?`,
  `capturedAt: Date`).
- Produces: `struct HomeShelf: Equatable, Sendable { var faceOut: [Journal]; var
  spines: [Journal]; var lastActivity: [String: Date] }` and
  `static func make(journals: [Journal], entries: [EntryListItem], faceOutLimit: Int)
  -> HomeShelf`. Task 2's `HomeView` calls
  `HomeShelf.make(journals: library.journals, entries: library.allEntries,
  faceOutLimit: 3)`.

Ranking rule (from the spec): journals ordered by newest `capturedAt` among their
entries, descending — capture time, NOT `effectiveDate`, so backdating an old entry
never reorders the shelf. Journals with no entries rank last. All ties broken by the
existing sidebar display order (`displayOrdered`). First `faceOutLimit` of the ranking
are `faceOut`; the rest are `spines`. `lastActivity` maps journal id → its newest
`capturedAt` (absent for empty journals) — the view's recency caption reads it.

- [ ] **Step 1: Write the failing tests**

Look at an existing `RaconteTests` file that builds `EntryListItem` fixtures (e.g.
whatever `LibraryScreenModel`'s tests use) and mirror its construction helper. The
tests, with a local helper `makeItem(journalID: String?, capturedAt: Date) ->
EntryListItem` (mint `captureID` with `ULID.make()`; leave `originalDate` nil unless
stated):

```swift
import XCTest
@testable import Raconte

final class HomeShelfModelTests: XCTestCase {
    // Journals created in display order A, B, C (strictly increasing createdAt so
    // displayOrdered is deterministic — advance the date between mints, never reuse
    // one Date; ULID ties at equal ms are a coin flip).

    func testRanksJournalsByNewestCaptureActivity() {
        // A's newest entry: t+1. B's newest: t+30 (B also has an OLDER t+2 entry —
        // proves "newest per journal", not "any entry"). C's newest: t+10.
        // Expect faceOut order (limit 3): [B, C, A].
    }

    func testFaceOutLimitSplitsIntoSpines() {
        // 5 journals with strictly descending activity; limit 3 →
        // faceOut == first 3 by activity, spines == remaining 2, still
        // activity-ordered.
    }

    func testJournalsWithNoEntriesRankLastInDisplayOrder() {
        // A (no entries), B (one entry), C (no entries) → [B, A, C]:
        // B first, then the empty ones in display order. lastActivity has no
        // key for A or C.
    }

    func testBackdatingDoesNotReorder() {
        // A's entry captured t+20 but with originalDate set to a year ago;
        // B's entry captured t+10, no backdate. A still outranks B.
    }

    func testFewerJournalsThanLimitMeansNoSpines() {
        // 2 journals, limit 3 → both faceOut, spines empty.
    }

    func testEntriesWithDanglingOrNilJournalIDCountForNoJournal() {
        // One entry with journalID nil, one with a ULID matching no journal;
        // both journals A and B are otherwise empty → ranking falls back to
        // display order [A, B], lastActivity empty.
    }

    func testActivityTieBreaksByDisplayOrder() {
        // A and B each newest-active at the SAME Date instance → [A, B]
        // (display order), deterministically.
    }
}
```

Fill each test body with real fixtures per its comment — the comments above are the
specification of each body, not placeholders to skip.

- [ ] **Step 2: Run tests to verify they fail**

Run (macOS unit recipe from Global Constraints, plus):
`-only-testing:RaconteTests/HomeShelfModelTests`
Expected: FAIL — `HomeShelf` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The Home landing's shelf split (#108 design): which journals show face-out covers
/// and which show as spines, ranked by capture activity. Pure — the view supplies
/// `LibraryScreenModel.journals` / `.allEntries` and renders the result.
struct HomeShelf: Equatable, Sendable {
    var faceOut: [Journal]
    var spines: [Journal]
    /// Journal id → newest `capturedAt` among its entries. Absent = no entries.
    var lastActivity: [String: Date]

    /// Ranking is by `capturedAt`, never `effectiveDate` — a backdate must not
    /// reorder the shelf (spec). Empty journals rank last; every tie falls back to
    /// the sidebar's display order so the two surfaces never disagree arbitrarily.
    static func make(journals: [Journal],
                     entries: [EntryListItem],
                     faceOutLimit: Int) -> HomeShelf {
        var lastActivity: [String: Date] = [:]
        let known = Set(journals.map(\.id))
        for entry in entries {
            guard let id = entry.journalID, known.contains(id) else { continue }
            if let existing = lastActivity[id] {
                if entry.capturedAt > existing { lastActivity[id] = entry.capturedAt }
            } else {
                lastActivity[id] = entry.capturedAt
            }
        }
        let display = journals.displayOrdered
        let displayIndex = Dictionary(uniqueKeysWithValues:
            display.enumerated().map { ($0.element.id, $0.offset) })
        let ranked = display.sorted { a, b in
            switch (lastActivity[a.id], lastActivity[b.id]) {
            case let (da?, db?):
                if da != db { return da > db }
                return displayIndex[a.id]! < displayIndex[b.id]!
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return displayIndex[a.id]! < displayIndex[b.id]!
            }
        }
        return HomeShelf(faceOut: Array(ranked.prefix(faceOutLimit)),
                         spines: Array(ranked.dropFirst(faceOutLimit)),
                         lastActivity: lastActivity)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: all HomeShelfModelTests PASS.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Home/HomeShelfModel.swift RaconteTests/HomeShelfModelTests.swift
git commit -m "feat(home): HomeShelf ranking — covers by capture activity (#108)"
```

---

### Task 2: Place.home, sidebar row, HomeView, navigation wiring

Launch place does NOT change in this task — Home is reachable via the sidebar, which
lets every existing launch-dependent test keep passing while the screen is built and
reviewed. The flip is Task 3.

**Files:**
- Modify: `Raconte/App/Place.swift` (enum, `SidebarModel.rows`, `PlaceRouting.resolve`,
  `PlaceRouting.journalScope`)
- Modify: `Raconte/App/ContentView.swift:173-205` (`detailRoot` switch, `libraryTitle`)
- Create: `Raconte/Home/UI/HomeView.swift`
- Test: `RaconteTests/PlaceTests.swift` (or the existing file that tests
  `SidebarModel.rows` / `PlaceRouting` — extend it, don't duplicate), new
  `RaconteUITests/HomeUITests.swift`

**Interfaces:**
- Consumes: `HomeShelf.make(journals:entries:faceOutLimit:)` (Task 1),
  `LibraryScreenModel` (`journals`, `allEntries`, `journalCovers: [String: Data]`),
  `AppRouter.select(_:)`, `InkTone` colors, `JournalCoverThumbnail(data:size:)`
  (existing placeholder treatment reference — see step 3 note).
- Produces: `HomeView(library:onOpenJournal:onNewEntry:)`; `Place.home`; sidebar
  row id `"sidebar.home"`; accessibility ids `"home.newEntry"`,
  `"home.cover.<journalID>"`, `"home.spine.<journalID>"`. Task 3 relies on all of
  these names exactly.

- [ ] **Step 1: Write the failing unit tests**

In the existing test file covering `SidebarModel.rows` (find it:
`grep -rln "SidebarModel" RaconteTests/`), add:

```swift
func testSidebarRowsListHomeFirst() {
    let rows = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: false)
    XCTAssertEqual(rows.first?.place, .home)
    XCTAssertEqual(rows.first?.accessibilityIdentifier, "sidebar.home")
    XCTAssertEqual(rows.map(\.place).prefix(2), [.home, .capture])
}

func testResolveHomeIsIdentity() {
    XCTAssertEqual(PlaceRouting.resolve(.home, journals: []), .home)
}

func testHomeHasNoJournalScope() {
    XCTAssertNil(PlaceRouting.journalScope(for: .home))
}
```

- [ ] **Step 2: Run to verify failure**

`-only-testing:RaconteTests/<that class>` — Expected: FAIL, `Place.home` not defined.

- [ ] **Step 3: Implement Place.home and the sidebar row**

In `Place.swift`:
- Add `case home` FIRST in the `Place` enum.
- In `SidebarModel.rows`, insert before the Capture row (and update the doc comment's
  locked order to "Home, Capture, journals, All Entries, Trash, About, Debug"):

```swift
PlaceRow(place: .home,
         title: "Home",
         subtitle: nil,
         systemImage: "books.vertical.fill",
         journalID: nil,
         accessibilityIdentifier: "sidebar.home"),
```

  (All Entries already uses `"books.vertical"`; the filled variant here keeps them
  distinct. If that reads confusable in review, `"house"` is the fallback — pick one
  and leave a comment.)
- `PlaceRouting.resolve`: add `.home` to the identity list
  (`case .capture, .home, .allEntries, .trash, .about, .debug: return place` — and the
  journal-fallback for a deleted journal stays `.capture`).
- `PlaceRouting.journalScope`: add `.home` to the `nil` list.
- `ContentView.libraryTitle`: add `.home` to the `"Library"` fallback list.

The compiler now forces the `detailRoot` switch — proceed to Step 4 before building.

- [ ] **Step 4: Implement HomeView**

`Raconte/Home/UI/HomeView.swift`. Visual spec is the approved mock (canvas above):
paper background, top-aligned; 3 face-out covers (104×132pt, 8pt continuous radius,
name at 13pt medium below, recency caption 11pt secondary); spine rows (52pt tall,
17pt serif name, a 3×20pt rounded per-journal tick, hairline separators, chevron);
bottom-pinned New entry button (52pt tall, 12pt continuous radius, accent fill, white
label 17pt semibold, `mic.fill` glyph). Empty state (no journals): centered serif
"Speak your first entry." over caption "Your journals will appear here.", same button.

```swift
import SwiftUI

/// The launch landing (#108): journals as a bookshelf — face-out covers ranked by
/// capture activity, the rest as quiet serif spines — and one New entry action.
/// Design doc: docs/plans/2026-08-29-home-bookshelf-design.md.
struct HomeView: View {
    let library: LibraryScreenModel
    let onOpenJournal: (String) -> Void
    let onNewEntry: () -> Void

    private var shelf: HomeShelf {
        HomeShelf.make(journals: library.journals,
                       entries: library.allEntries,
                       faceOutLimit: 3)
    }

    var body: some View {
        VStack(spacing: 0) {
            if library.journals.isEmpty {
                emptyInvitation
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        faceOutRow
                        spineList
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
            newEntryButton
        }
        .background(InkTone.paper.color)
        .navigationTitle("Raconte")
    }
    // … subviews per the visual spec above …
}
```

Concrete requirements for the subviews (each is a `private var`/`func` in this file):

- `faceOutRow`: `HStack(spacing: 14)` of `shelf.faceOut` cards. Each card is a
  `Button` (action `onOpenJournal(journal.id)`) whose label is a `VStack`: the cover
  — render `library.journalCovers[journal.id]` as a resizable
  `Image` (`.scaledToFill()`, `.frame(width: 104, height: 132)`,
  `.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))`); when no cover
  data, reuse the placeholder treatment `JournalCoverThumbnail` uses (read that file
  and lift its no-data branch at this size — do not invent a new one) — then the name
  (`.font(.system(size: 13, weight: .medium))`, `InkTone.ink.color`, `lineLimit(2)`)
  and the recency caption (`shelf.lastActivity[journal.id]` formatted
  `.relative(presentation: .named)`, `.font(.system(size: 11))`,
  `InkTone.inkSecondary.color`; omit the caption when absent).
  `.accessibilityIdentifier("home.cover.\(journal.id)")` goes ON THE BUTTON — the
  container-identifier trap: an identifier on a wrapping container merges/overwrites
  children (see `SidebarRowView`'s comment).
- `spineList`: `ForEach(shelf.spines)` of `Button`s (action `onOpenJournal`), row
  content: `HStack(spacing: 12)`: tick (`RoundedRectangle(cornerRadius: 2)` 3×20pt,
  fill `InkTone.accent.color.opacity(0.55)`), name
  (`.font(.system(size: 17, design: .serif))`, `InkTone.ink.color`), `Spacer()`,
  `Image(systemName: "chevron.right")` (`InkTone.inkSecondary.color`, 13pt). Row
  height 52pt, hairline `Divider` overlay `InkTone.hairline.color` between rows.
  Identifier `"home.spine.\(journal.id)"` on the Button. Render nothing when
  `shelf.spines.isEmpty` (≤3 journals: no spines section, no stray divider).
- `newEntryButton`: `Button`(action `onNewEntry`), label `HStack(spacing: 10)`:
  `Image(systemName: "mic.fill")` + `Text("New entry")`
  (`.font(.system(size: 17, weight: .semibold))`), `.foregroundStyle(.white)`,
  `.frame(maxWidth: .infinity).frame(height: 52)`,
  `.background(InkTone.accent.color, in: RoundedRectangle(cornerRadius: 12,
  style: .continuous))`, horizontal padding 24, bottom padding 16.
  `.accessibilityIdentifier("home.newEntry")`.
- `emptyInvitation`: centered `VStack(spacing: 14)`: `Text("Speak your first entry.")`
  (`.font(.system(size: 24, design: .serif))`) and
  `Text("Your journals will appear here.")` (15pt, `InkTone.inkSecondary.color`),
  `frame(maxHeight: .infinity)`. Note: `CaptureScreenModel.bootstrap()` mints a
  default "Journal" on a truly fresh install, so this state is transient/defensive —
  implement it anyway (spec) but don't fight to make it reachable in tests beyond the
  unit level.

In `ContentView.detailRoot` add (styled like the other paper places):

```swift
case .home:
    HomeView(library: services.library,
             onOpenJournal: { services.router.select(.journal($0)) },
             onNewEntry: { services.router.select(.capture) })
        .tint(InkTone.accent.color)
        .background(InkTone.paper.color)
```

Run `xcodegen generate`, then the iOS compile check AND the macOS unit recipe (both
platforms must build; watch for macOS-only pitfalls — no `Menu` with an `Image` label
is used here, and all text sizes are explicit points, so platform style drift doesn't
apply).

- [ ] **Step 5: Run unit tests to verify they pass**

Step 2's command. Expected: PASS.

- [ ] **Step 6: Write the UI tests**

New `RaconteUITests/HomeUITests.swift`, mirroring an existing class's `launchApp()`
helper (copy the `RACONTE_UITEST_ID` pattern from `NavigationUITests`):

```swift
final class HomeUITests: XCTestCase {
    // launchApp() copied from NavigationUITests's private helper.

    func testHomeShowsShelfAndNavigatesToJournal() {
        let app = launchApp()
        openPlace(app, "sidebar.home")
        XCTAssertTrue(app.buttons["home.newEntry"].firstMatch.waitForExistence(timeout: 15),
                      "Home never rendered")
        // The default minted journal shows as a face-out cover.
        let cover = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home.cover.'"))
            .firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 15), "no face-out cover on Home")
        cover.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["home.newEntry"].firstMatch.exists,
                       "tapping a cover did not leave Home")
    }

    func testNewEntryGoesToCapture() {
        let app = launchApp()
        openPlace(app, "sidebar.home")
        let newEntry = app.buttons["home.newEntry"].firstMatch
        XCTAssertTrue(newEntry.waitForExistence(timeout: 15))
        newEntry.tap()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15),
                      "New entry did not land on the capture screen")
    }
}
```

- [ ] **Step 7: Verify the UI tests fail RED for the right reason, then pass**

Use the git-stash trick if in doubt (stash `HomeView.swift` and the `detailRoot`
branch is a compile error, so instead run the tests BEFORE Step 3/4 were committed, or
trust the first run): run
`xcodebuild … -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/HomeUITests test`
Expected: PASS (2 tests). Then run `-only-testing:RaconteUITests/NavigationUITests`
— Expected: all still PASS (launch place unchanged).

- [ ] **Step 8: Commit**

```bash
git add Raconte/App/Place.swift Raconte/App/ContentView.swift \
  Raconte/Home/UI/HomeView.swift RaconteTests RaconteUITests/HomeUITests.swift
git commit -m "feat(home): Place.home + HomeView bookshelf, sidebar-reachable (#108)"
```

---

### Task 3: Flip launch to Home; recovery banners on Home

**Files:**
- Modify: `Raconte/App/Place.swift:127` (`launchPlace`)
- Modify: `Raconte/App/ContentView.swift` (root `.task` bootstrap kick; header doc
  comment)
- Modify: `Raconte/Home/UI/HomeView.swift` (banner section)
- Modify: `Raconte/Capture/UI/RecoveryBanner.swift` (only if needed for the dark-card
  wrapper — prefer wrapping at the call site)
- Test: `RaconteUITests/NavigationUITests.swift` (invert the launch test), plus a
  sweep of every UI test class that assumes capture-at-launch (~24 call sites across
  10 files — enumerate with
  `grep -rn 'capture.record"\].firstMatch.waitForExistence' RaconteUITests/`)

**Interfaces:**
- Consumes: `CaptureScreenModel.bootstrap()` (idempotent via `didBootstrap` guard),
  `CaptureScreenModel.pendingRecovered: [RecoveredRecording]`, `RecoveryBanner(
  recording:capturesRoot:onKeep:onDelete:)` and the Keep/Delete intents CaptureView
  passes it (read `CaptureView.swift`'s RecoveryBanner call site and pass the same
  model methods), `openCapture(app)` test helper.
- Produces: launch lands on Home; recovery reachable without visiting capture.

- [ ] **Step 1: Invert the launch UI test (RED first)**

In `NavigationUITests.swift`, replace `testLaunchLandsDirectlyOnCaptureWithNoTaps`:

```swift
/// `NavigationSplitView` with a non-nil sidebar selection, collapsed to a stack on
/// iPhone, must show the DETAIL column at launch — Home, since #108 (was capture).
func testLaunchLandsDirectlyOnHomeWithNoTaps() {
    let app = launchApp()
    XCTAssertTrue(app.buttons["home.newEntry"].firstMatch.waitForExistence(timeout: 30),
                  "the app did not launch into Home")
    XCTAssertFalse(app.buttons["capture.record"].firstMatch.exists,
                   "capture is showing at launch instead of Home")
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sidebar.home")
                      .firstMatch.exists,
                   "the sidebar column is showing instead of the detail column")
}
```

Run `-only-testing:RaconteUITests/NavigationUITests/testLaunchLandsDirectlyOnHomeWithNoTaps`.
Expected: FAIL (still launches into capture).

- [ ] **Step 2: Flip the constant and rehome bootstrap**

- `Place.swift:127`: `static let launchPlace: Place = .home` (SidebarView's
  `@State selection` initializer reads the same constant — stays in sync for free).
- `ContentView.swift`: alongside the existing sync `.task`, add a SEPARATE task (so
  neither can delay the other):

```swift
// #108: capture's bootstrap (the crash-recovery scan) used to ride CaptureView's
// own `.task`, which was fine while capture was the launch root. Home is now the
// root, and recovery must not depend on the owner ever visiting capture — kick it
// here too. `bootstrap()` is `didBootstrap`-guarded, so the CaptureView copy (kept,
// as a belt for previews/tests that mount CaptureView directly) never double-runs.
.task { await services.capture.bootstrap() }
```

- Update `ContentView.swift:3-7`'s header comment ("capture pre-selected… lands
  directly on the detail column (capture)") to name Home and the new test.

- [ ] **Step 3: Recovery banners on Home**

In `HomeView`, above the shelf (inside the `ScrollView`, first element — and ALSO
above `emptyInvitation` in the empty branch): for each of
`capture.pendingRecovered`, render the existing `RecoveryBanner` with the same
arguments CaptureView passes (read its call site and mirror Keep/Delete). HomeView
gains `let capture: CaptureScreenModel` (ContentView passes `services.capture`).

`RecoveryBanner` is styled for the near-black studio (white text, `.orange` tint) —
on paper it would be illegible. Wrap it AT THE CALL SITE in a dark card rather than
restyling the shared view:

```swift
RecoveryBanner(recording: recording, capturesRoot: …, onKeep: …, onDelete: …)
    .padding(12)
    .background(InkTone.studio.color,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .environment(\.colorScheme, .dark)   // pinned-dark-surface rule (CLAUDE.md)
    .padding(.horizontal, 24)
```

No auto-jump to capture — the banner is the whole treatment (spec ruling).

- [ ] **Step 4: Sweep the launch-dependent UI tests**

Enumerate: `grep -rn 'capture.record"\].firstMatch.waitForExistence' RaconteUITests/`.
For each call site that runs IMMEDIATELY after `launchApp()` (i.e. expects capture as
the launch screen — not ones that already follow an `openCapture`/`openPlace` call):
insert `openCapture(app)` after launch. `testTerminateMidRecordingRecoversOnRelaunch`
(CaptureUITests) is special — after `app.terminate()` and relaunch, do NOT add
`openCapture` before the banner assertion: the relaunched app lands on Home, and the
banner must be found THERE. That test now pins the load-bearing spec claim (recovery
without visiting capture) for free. Check `recoveryBanner(_:)`'s query is
screen-agnostic (it matches `recovery.title` anywhere); if it scopes to a capture
container, generalize it.

Also re-check `testTappingCaptureFromBareSidebar…`-style tests and any test asserting
`capture.record` absence/presence at launch — the grep above plus
`grep -rn 'launchApp()' RaconteUITests/ | wc -l` sanity-bounds the sweep.

- [ ] **Step 5: Run the full UI suite, split under the 10-minute cap**

Foreground `-only-testing:` per class (NavigationUITests, HomeUITests,
CaptureUITests, CaptureControlsUITests, EntryDetailSheetUITests, EntryPagingUITests,
JournalEditorUITests, TranscriptEditorUITests, ImageCaptureUITests,
VoiceMarkingUITests, AboutUITests — group small classes into one invocation, keep
each invocation under ~8 minutes). Reconcile pass/fail counts against the pre-change
baseline. Also run the macOS unit recipe (EntitlementsParityTests etc. must stay
green).

Expected: everything green, including the inverted launch test and the relaunch
recovery test finding its banner on Home.

- [ ] **Step 6: Commit**

```bash
git add -A Raconte RaconteUITests
git commit -m "feat(home): launch lands on Home; recovery banners surface there (#108)"
```

---

### Task 4: De-flake the scrub UI test (rider)

Red-on-first-attempt on the last three main CI runs (values 3.539/3.723 vs a
`totalSeconds - 0.5` bound with `totalSeconds ≈ 4`): XCUI's
`adjust(toNormalizedSliderPosition: 0.5)` is coarse on a narrow slider and can land
the handle near the end, where the test's own guard (correctly) refuses to assert.

**Files:**
- Modify: `RaconteUITests/CaptureUITests.swift` (in
  `testScrubbingAFinishedEntryMovesThePosition`, around line 240)

- [ ] **Step 1: Replace the single adjust with a bounded retry toward the middle**

```swift
// XCUI's normalized drag is coarse on a narrow slider: a request for 0.5 can land
// within the end-guard band and fail the run on drag imprecision alone (three
// first-attempt CI failures, 2026-08-29: 3.54–3.72s of ~4s). The test's claim is
// "scrubbing moves the position", not "lands at 50%": walk earlier targets until
// the handle lands inside the assertable band.
var handleSeconds = 0.0
for target in [0.5, 0.35, 0.25] {
    scrubber.adjust(toNormalizedSliderPosition: target)
    handleSeconds = try XCTUnwrap(Self.number(scrubber.value),
                                  "unreadable slider value \(String(describing: scrubber.value))")
    if handleSeconds > 0.5 && handleSeconds < totalSeconds - 0.5 { break }
}
XCTAssertGreaterThan(handleSeconds, 0.5, "the drag barely moved the handle")
XCTAssertLessThan(handleSeconds, totalSeconds - 0.5,
                  "the handle must land short of the end, or a still-running "
                  + "playhead could match by accident")
```

(The two assertions keep their original messages and meaning; the retry only rescues
drag imprecision, never a real scrubbing failure — a broken scrubber fails all three
targets.)

- [ ] **Step 2: Run the test 3× to check stability**

`-only-testing:RaconteUITests/CaptureUITests/testScrubbingAFinishedEntryMovesThePosition`
three consecutive foreground runs. Expected: 3/3 PASS.

- [ ] **Step 3: Commit**

```bash
git add RaconteUITests/CaptureUITests.swift
git commit -m "test(capture): de-flake scrub test — retry coarse slider drags toward the middle"
```
