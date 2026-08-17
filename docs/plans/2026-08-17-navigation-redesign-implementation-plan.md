# Navigation Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single permanently-mounted `NavigationStack` with a `NavigationSplitView` of addressable places, so every screen has a name and a route, and the two (really three) view-mount hacks that depend on `CaptureView` never unmounting are removed rather than relocated.

**Architecture:** One `Place` enum drives a sidebar selection; the detail column is a `NavigationStack` with a real path binding. Route state lives in an `@Observable` `AppRouter` owned by the scene (so macOS `Commands` can drive it). Everything that used to be a view-lifecycle hook on `CaptureView` — finalize dispatch, phase dispatch, idle-timer hold, receipt reconcile — moves into the model layer behind unit-testable seams.

**Tech Stack:** SwiftUI multiplatform (iOS 26 / macOS 26), Swift 6 strict concurrency, `@Observable` + `withObservationTracking`, XcodeGen (`project.yml` is the source of truth), XCTest + XCUITest.

**Spec:** `docs/plans/2026-08-17-navigation-redesign-design.md` — owner-approved 2026-08-17. Read it first; every task argues from it. Its file:line cites were re-verified against main `0286a4f8` while this plan was written and all hold.

---

## Global Constraints

- Branch `nav/redesign` in its own worktree, based on **main** (subagent worktrees branch from the default branch — that is the correct base here; do **not** base on `m4/sync`).
- **After creating any new file: `xcodegen generate`**, or `-only-testing` reports "Executed 0 tests" and **exits 0** — a silent pass.
- Never pipe `xcodebuild` through `head`. After any interrupted UI run: `xcrun simctl shutdown all` before re-running.
- Test (macOS): `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test` with `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`. **On main this works as-is** — the entitlements carry no iCloud keys. It will stop working the day `m4/sync` merges (that branch's entitlements cannot be ad-hoc signed and need `CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements`, and **never** `CODE_SIGNING_ALLOWED=NO`, which unsandboxes the app-hosted test runner onto the real archive). Task 9 records the transition.
- UI tests (simulator only): `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' test`.
- iOS compile checks need `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`.
- TDD with RED evidence: every new behaviour's test must be shown failing **for the reason the task names** before the implementation lands. Compile-error red is **NOT** acceptable evidence. For SwiftUI view-wiring halves, RED is verified by `git stash push` on just the production files, running the new UI test against the stashed-out code, watching it fail for the right reason, then `git stash pop` (repo memory: swiftui-verify-red-via-stash).
- Every task names at least one **mutation check**; the implementer runs it and reports the failing output verbatim.
- Vacuous-fixture rule: every fixture exercises the non-degenerate path; cardinality ≥ 2 where a rule quantifies. Source-scanning tests must **strip `//` comments** before matching, or this repo's own prose satisfies them.
- Commit messages **and PR bodies**: never place a close-verb immediately before an issue number unless auto-close is intended.
- Each task ends green: full unit suite + iOS build + macOS build, on the committed tree.

## Global Invariants (copied verbatim from design §8 — every task brief repeats the ones it can break)

1. **Color pins**: scoped `.environment(\.colorScheme, .dark)` sites stay exactly as scoped (`CaptureView.swift:1313, 1456, 1549, 1714, 1170`); `preferredColorScheme` remains forbidden anywhere in the capture subtree.
2. **Foreground-style resets** at every presentation boundary out of the capture surface (`CaptureView.swift:899, 1335, 1343, 1358, 1367, 1502`; `PrecisionDatePicker.swift:226-229`) — the white-on-white alert class.
3. **One `LibraryScreenModel` app-wide** (`ContentView.swift:6-8`; asserted `CaptureView.swift:165-166`). The sidebar and every list resolve entries through it.
4. **UI-test identifiers live on links, never on rows inside them** (`library.entryLink`, `capture.recentRow`); **no identifier on control-bar containers** (flattening trap, hit three times).
5. **Back-is-Done** semantics on editor / Mark voices / revision history stay push-based — converting any to a sheet changes the save contract.
6. **`EntryDetailView` keeps its own `item` copy** (`EntryDetailView.swift:10-15`) — journal reassignment must not blank a pushed detail.
7. Detail sub-models built once in `init`, never re-minted per body evaluation (`EntryDetailView.swift:27-47`).
8. The capture screen's internal content (bands, control bar, marker buttons, §53/§Option-B geometry and its `CaptureControlsUITests` pins) is **out of scope** — this design changes the frame around screens, not the screens.

## Locked decisions (apply to every task)

These are rulings this plan makes where the design was silent or where the code contradicted it. Each is flagged in the handoff report.

- **`Place` always carries `.debug`.** The enum case is unconditional so every `switch` stays total and unit-testable; only *listing* it in the sidebar is `#if DEBUG`.
- **Journal filter chips are removed from `LibraryView`.** The sidebar's journal rows *are* the filter. Two controls writing one piece of state (`journalScope`) is the "can't tell where I am" problem the redesign exists to fix. `library.journalChips` / `library.journalChip` identifiers go with them; no test uses either.
- **`LibraryDestination` loses `.trash`** (Trash is a place). `RootDestination` is deleted outright. `LibraryDestination` keeps exactly `case entry(String)`.
- **`library.trashLink` (the library toolbar Trash button) is deleted.** Trash is reached only from the sidebar.
- **No global Esc binding.** Design §7 wants Esc-as-back "unless the editor is focused"; a menu-bar command wins the responder chain unconditionally, so binding it globally would break `TranscriptEditorView`'s existing `.keyboardShortcut(.cancelAction)` (`TranscriptEditorView.swift:58-60`). Back is bound to **⌘[** only. This satisfies "editor wins when focused" by construction rather than by hope.
- **⌘-digit map is fixed-place only**: ⌘1 Capture, ⌘2 All Entries, ⌘3 Trash, ⌘4 Debug (DEBUG builds). Journals are a variable-length list and get no digits — a fixed digit for "first journal" silently retargets when a journal is created.
- **Idle-timer hold is applied by the model through an injectable seam**, not by an `onChange` at the scene root. Same guarantee the design asks for (independent of what is mounted), plus it becomes unit-testable, which the view version never was.
- Sidebar accessibility identifiers: `sidebar.capture`, `sidebar.capture.live`, `sidebar.journal.<journalID>`, `sidebar.allEntries`, `sidebar.trash`, `sidebar.debug`, `sidebar.toggle`. Rows in a `List(selection:)` are not `NavigationLink`s, so invariant 4's flattening trap does not apply — but nothing may put an identifier on the enclosing `List`.

## Blockers found in the code that the design missed

Read these before Task 2; they change the task order.

- **Finalize and phase dispatch are view-mounted.** `CaptureView.swift:820-825` carries `.onChange(of: model.coordinator.phase) { model.handlePhase() }` and `.onChange(of: model.coordinator.finalizeQueue) { model.handleFinalizeQueue() }`. Today `CaptureView` is the permanently-mounted stack root so they always fire. The moment the capture view can be unmounted (Task 4), a capture that reaches `.captured` while the owner is browsing — an interruption budget exhausting, a route loss giving up, `mediaServicesReset` — **never runs the finalizer**, and the recording sits unencoded until the next launch's recovery scan. This is a data-path hazard of the same family as design §5's two named hacks and is retired in **Task 2, before the split view lands**.
- **⌘N has nowhere to land.** The New Journal alert is driven by `@State private var showingNewJournalPrompt` inside `JournalHeaderView` (`CaptureView.swift:1240`, alert at `:1333`), a private view nested three levels inside `CaptureView`. A `Commands` item cannot reach it, and even hoisting the flag would only work while the Capture place is selected. Task 8 moves a root-level New Journal alert onto `ContentView`, driven by an observable flag on `AppRouter`.
- **There is no shared UI-test helper file.** Four test classes each carry their own private `launchApp` / `press` / `waitUntil`, and the library-navigation steps are hard-coded in 11 places outside any helper. Task 5 introduces `RaconteUITests/UITestNavigation.swift` first, then reroutes.
- **Deleting the Library door breaks two *unit* tests, not just UI tests.** Design §9 anticipates UI-test fallout only. `RaconteTests/CaptureLabelTests.swift:154` `testEveryLabelCaseIsActuallyAppliedToAView` fails the moment `libraryDoor` leaves the view (`CaptureLabel.libraryDoor` / `.libraryDoorChevron` become cases no view applies — the exact defect that adversary exists to catch), and `CaptureLayoutModelTests` pins `showsLibraryDoor` in six places. Both are handled in Task 5 by deleting the cases, never by exempting them.
- **`VoiceMarkingUITests` addresses library rows by index** (`boundBy: 0/1/2`, documented at `VoiceMarkingUITests.swift:48-65`). Removing the journal chips does not change the ordering (All Entries is unscoped, grouped by year, newest-first, exactly as the chips' "All" state was), but Task 5's reviewer must confirm it empirically rather than by argument.

## File structure

```
Raconte/App/
  Place.swift                NEW  pure: Place, PlaceRow, SidebarModel, AppRouter, CaptureSidebarRow   (T1, T6)
  SidebarView.swift          NEW  the sidebar list                                                     (T5)
  RaconteCommands.swift      NEW  #if os(macOS) menu bar + shortcuts                                   (T8)
  ContentView.swift          MOD  NavigationSplitView root, detail-column destinations                 (T4, T5, T8)
  RaconteApp.swift           MOD  owns AppServices (models + router), attaches Commands                (T4, T8)
Raconte/Capture/UI/
  CaptureScreenModel.swift   NEW  extracted verbatim from CaptureView.swift                            (T2)
  CaptureView.swift          MOD  loses the model, the door, the Debug sheet, four onChange hooks      (T2, T3, T5)
  CaptureLayoutModel.swift   MOD  loses showsLibraryDoor                                               (T5)
Raconte/Capture/Debug/
  IdleTimerControl.swift     NEW  seam + platform impls                                                (T2)
  DebugMenuView.swift        MOD  reshaped as a screen                                                 (T7)
  BuildStamp.swift           MOD  async wrapper                                                        (T7)
Raconte/Library/
  LibraryScreenModel.swift   MOD  rescan observer seam                                                 (T3)
  UI/LibraryView.swift       MOD  chips + trash link removed, LibraryDestination trimmed               (T5)
RaconteTests/
  PlaceRoutingTests.swift            NEW (T1)
  CaptureSidebarRowTests.swift       NEW (T6)
  CaptureScreenModelObservationTests.swift NEW (T2)
  LibraryRescanObserverTests.swift   NEW (T3)
  BuildStampAsyncTests.swift         NEW (T7)
  AppRouterCommandTests.swift        NEW (T8)
  CaptureLayoutModelTests.swift      MOD (T5)
RaconteUITests/
  UITestNavigation.swift     NEW  shared place-navigation helpers                                      (T5)
  CaptureUITests.swift       MOD (T4, T5, T6)
  CaptureControlsUITests.swift MOD (T5)
  VoiceMarkingUITests.swift  MOD (T5)
  TranscriptEditorUITests.swift MOD (T5, no navigation change expected)
  NavigationUITests.swift    NEW  launch/place/recording-survives pins                                 (T4, T5, T6, T7)
```

---

### Task 1: The pure routing model

Nothing here touches a view. This is the type every later task switches over.

**Files:**
- Create: `Raconte/App/Place.swift`
- Test: `RaconteTests/PlaceRoutingTests.swift`

**Interfaces:**
- Consumes: `Journal` (`Raconte/Library/Journal.swift`), `JournalScope` (`Raconte/Library/EntryListItem.swift:216` — `.all` / `.journal(String)`), `LibraryDestination` (`Raconte/Library/UI/LibraryView.swift:6`).
- Produces:

```swift
enum Place: Hashable, Sendable {
    case capture
    case journal(String)      // journal id
    case allEntries
    case trash
    case debug                // always present in the type; only its LISTING is #if DEBUG
}

struct PlaceRow: Identifiable, Equatable, Sendable {
    var place: Place
    var title: String
    var subtitle: String?          // a journal's derived date range, nil otherwise
    var systemImage: String?       // nil for journal rows (they draw a cover thumbnail)
    var journalID: String?         // non-nil ⇒ draw JournalCoverThumbnail
    var accessibilityIdentifier: String
    var id: Place { place }
}

enum SidebarModel {
    /// `dateRanges` is journalID → formatted range (or absent). Caller supplies it from
    /// `LibraryScreenModel.dateRange(forJournal:)` so this stays pure.
    static func rows(journals: [Journal],
                     dateRanges: [String: String],
                     includesDebug: Bool) -> [PlaceRow]
}

enum PlaceRouting {
    static let launchPlace: Place = .capture
    /// Selecting a DIFFERENT place clears the detail path; re-selecting the same place keeps it.
    static func detailPath(afterSelecting new: Place,
                           from old: Place,
                           path: [LibraryDestination]) -> [LibraryDestination]
    /// A `.journal(id)` for a journal that is not in the registry falls back to `.capture`.
    /// Every other place resolves to itself.
    static func resolve(_ place: Place, journals: [Journal]) -> Place
    /// The scope the entry list must run under. `nil` for places that are not entry lists.
    static func journalScope(for place: Place) -> JournalScope?
}

@MainActor @Observable
final class AppRouter {
    var place: Place = PlaceRouting.launchPlace
    var detailPath: [LibraryDestination] = []
    var showingNewJournalPrompt = false      // consumed by T8's ⌘N and T8's root alert
    func select(_ place: Place)              // applies PlaceRouting.detailPath(...)
    func goBack()                            // pops detailPath if non-empty; no-op otherwise
    var canGoBack: Bool { !detailPath.isEmpty }
}
```

Row order and titles (locked): Capture (`"Capture"`, `"mic.circle"`), then one row per journal in registry order (title = journal name, subtitle = formatted date range or nil, `journalID` set), then All Entries (`"All Entries"`, `"books.vertical"`), Trash (`"Trash"`, `"trash"`), then Debug (`"Debug"`, `"ladybug"`) when `includesDebug`.

- [ ] **Step 1: Write the failing tests** in `RaconteTests/PlaceRoutingTests.swift`.

```swift
@MainActor
final class PlaceRoutingTests: XCTestCase {

    private func journal(_ id: String, _ name: String) -> Journal {
        Journal(id: id, name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    // Cardinality ≥ 2 on purpose: one journal cannot distinguish "a row per journal"
    // from "a row for the first journal".
    func testRowsAreCaptureThenEveryJournalThenAllEntriesThenTrash() {
        let rows = SidebarModel.rows(journals: [journal("j1", "1987"), journal("j2", "France")],
                                     dateRanges: ["j1": "1987"],
                                     includesDebug: false)
        XCTAssertEqual(rows.map(\.place),
                       [.capture, .journal("j1"), .journal("j2"), .allEntries, .trash])
        XCTAssertEqual(rows[1].title, "1987")
        XCTAssertEqual(rows[1].subtitle, "1987")
        XCTAssertNil(rows[2].subtitle, "a journal with no entries shows no range, not an empty one")
        XCTAssertEqual(rows[1].journalID, "j1")
        XCTAssertNil(rows[0].journalID, "only journal rows draw a cover")
    }

    func testDebugRowIsLastAndOnlyWhenIncluded() {
        let without = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: false)
        XCTAssertFalse(without.contains { $0.place == .debug })
        let with = SidebarModel.rows(journals: [], dateRanges: [:], includesDebug: true)
        XCTAssertEqual(with.last?.place, .debug)
    }

    func testEveryRowCarriesItsOwnIdentifier() {
        let rows = SidebarModel.rows(journals: [journal("j1", "1987"), journal("j2", "France")],
                                     dateRanges: [:], includesDebug: true)
        XCTAssertEqual(Set(rows.map(\.accessibilityIdentifier)).count, rows.count,
                       "two rows sharing an identifier makes every UI test that taps one ambiguous")
        XCTAssertEqual(rows.first { $0.place == .journal("j2") }?.accessibilityIdentifier,
                       "sidebar.journal.j2")
        XCTAssertEqual(rows.first { $0.place == .trash }?.accessibilityIdentifier, "sidebar.trash")
    }

    func testSwitchingPlacesClearsTheDetailPath() {
        let path: [LibraryDestination] = [.entry("A"), .entry("B")]
        XCTAssertEqual(PlaceRouting.detailPath(afterSelecting: .trash, from: .allEntries, path: path),
                       [])
    }

    func testReselectingTheSamePlaceKeepsTheDetailPath() {
        let path: [LibraryDestination] = [.entry("A")]
        XCTAssertEqual(PlaceRouting.detailPath(afterSelecting: .capture, from: .capture, path: path),
                       path,
                       "tapping the place you are already in must not throw away where you are")
    }

    func testAJournalPlaceForAMissingJournalFallsBackToCapture() {
        XCTAssertEqual(PlaceRouting.resolve(.journal("gone"), journals: [journal("j1", "1987")]),
                       .capture)
        XCTAssertEqual(PlaceRouting.resolve(.journal("j1"), journals: [journal("j1", "1987")]),
                       .journal("j1"))
    }

    func testJournalScopePerPlace() {
        XCTAssertEqual(PlaceRouting.journalScope(for: .allEntries), .all)
        XCTAssertEqual(PlaceRouting.journalScope(for: .journal("j1")), .journal("j1"))
        XCTAssertNil(PlaceRouting.journalScope(for: .capture))
        XCTAssertNil(PlaceRouting.journalScope(for: .trash))
        XCTAssertNil(PlaceRouting.journalScope(for: .debug))
    }

    func testRouterLaunchesOnCapture() {
        XCTAssertEqual(AppRouter().place, .capture)
        XCTAssertTrue(AppRouter().detailPath.isEmpty)
    }

    func testRouterGoBackPopsOnceAndIsSafeWhenEmpty() {
        let router = AppRouter()
        router.detailPath = [.entry("A"), .entry("B")]
        XCTAssertTrue(router.canGoBack)
        router.goBack()
        XCTAssertEqual(router.detailPath, [.entry("A")])
        router.goBack()
        XCTAssertFalse(router.canGoBack)
        router.goBack()                       // must not trap
        XCTAssertEqual(router.detailPath, [])
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  -only-testing:RaconteTests/PlaceRoutingTests test
```

Expected: build failure naming `Place`, `SidebarModel`, `PlaceRouting`, `AppRouter` as undefined. **This is compile-error red and is NOT sufficient evidence on its own** — after Step 3, re-run the mutation checks in Step 5 to get behavioural red.

- [ ] **Step 3: Write `Raconte/App/Place.swift`, then `xcodegen generate`, then run the tests green.**

`PlaceRouting.journalScope(for:)` and `PlaceRouting.resolve(_:journals:)` must be exhaustive `switch`es over `Place` with **no `default`** — the repo convention (`CaptureLayoutModel.make`, `MarkerControlsModel.make`): a new place must break the build here rather than silently getting somebody else's behaviour.

- [ ] **Step 4: Run the whole suite + both builds green, commit**

```bash
git add Raconte/App/Place.swift RaconteTests/PlaceRoutingTests.swift project.yml
git commit -m "feat: pure Place routing model — places, sidebar rows, detail-path rules (nav T1)"
```

- [ ] **Step 5: Mutation checks (report the failing output verbatim)**

1. Make `PlaceRouting.detailPath(afterSelecting:from:path:)` return `path` unconditionally → `testSwitchingPlacesClearsTheDetailPath` must fail.
2. Make `SidebarModel.rows` emit `"sidebar.journal"` (no id suffix) for every journal row → `testEveryRowCarriesItsOwnIdentifier` must fail on the uniqueness assertion, not only on the literal.
3. Make `PlaceRouting.resolve` return its argument unchanged → the missing-journal test must fail.

**Adversarial reviewer should probe:**
- Whether `SidebarModel.rows` survives an empty journals array and a journal whose name is empty.
- Whether any test would still pass if `Place.debug` were removed from the enum entirely (it must not — `testDebugRowIsLastAndOnlyWhenIncluded` is the pin).
- Whether the identifier-uniqueness test is vacuous with 0 or 1 journals (it is; the fixture must carry ≥ 2, and the reviewer should delete one journal from the fixture and confirm the test stops discriminating — then restore it).

---

### Task 2: Retire the view-mounted coordinator hooks (finalize, phase, idle timer)

**This must land before Task 4.** See "Blockers": once `CaptureView` can be unmounted, `.onChange(of: model.coordinator.finalizeQueue)` stops firing and a capture that commits while the owner is browsing never gets encoded.

**Files:**
- Create: `Raconte/Capture/UI/CaptureScreenModel.swift` (extraction, commit 1)
- Create: `Raconte/Capture/Debug/IdleTimerControl.swift`
- Modify: `Raconte/Capture/UI/CaptureView.swift` (delete the model; delete lines 820-825 and 833-854)
- Test: `RaconteTests/CaptureScreenModelObservationTests.swift`

**Interfaces:**
- Consumes: `CaptureCoordinator` (`@Observable`, `phase: CaptureState`, `finalizeQueue: [String]`, `elapsed`), `CaptureState.keepsDisplayAwake` (`CaptureState.swift:27`).
- Produces:

```swift
@MainActor protocol IdleTimerControlling: AnyObject {
    func setIdleTimerDisabled(_ disabled: Bool)
}
// iOS: wraps UIApplication.shared.isIdleTimerDisabled. macOS: a no-op impl.
// `CaptureScreenModel.init` gains `idleTimer: any IdleTimerControlling = PlatformIdleTimer()`.

extension CaptureScreenModel {
    /// True while the CURRENT coordinator's phase must hold the display awake.
    var keepsDisplayAwake: Bool { get }
}
```

**Invariants this task can break (design §8, verbatim):**
> 3. **One `LibraryScreenModel` app-wide** (`ContentView.swift:6-8`; asserted `CaptureView.swift:165-166`). The sidebar and every list resolve entries through it.
> 8. The capture screen's internal content (bands, control bar, marker buttons, §53/§Option-B geometry and its `CaptureControlsUITests` pins) is **out of scope** — this design changes the frame around screens, not the screens.

- [ ] **Step 1: Extract `CaptureScreenModel` verbatim, commit alone**

`CaptureView.swift` is 1,759 lines and the model occupies roughly the first 757. Cut `@MainActor @Observable final class CaptureScreenModel { … }` (and only that) into `Raconte/Capture/UI/CaptureScreenModel.swift`, add the same `import SwiftUI` / `#if os(iOS) import UIKit #endif` header. Then `xcodegen generate`, run the full suite, and verify the move is mechanical:

```bash
git diff --stat        # two files, roughly equal +/- , no third file touched
xcodegen generate
```

```bash
git add Raconte/Capture/UI/CaptureScreenModel.swift Raconte/Capture/UI/CaptureView.swift project.yml
git commit -m "refactor: extract CaptureScreenModel out of the 1759-line CaptureView (nav T2)"
```

- [ ] **Step 2: Write the failing tests** in `RaconteTests/CaptureScreenModelObservationTests.swift`

Build the model with the existing fake session/recorder/encoder helpers that `RaconteTests/CaptureScreenModelTests.swift` already uses (reuse them; do not mint a second set), plus a recording fake:

```swift
@MainActor
final class FakeIdleTimer: IdleTimerControlling {
    private(set) var calls: [Bool] = []
    var current: Bool? { calls.last }
    func setIdleTimerDisabled(_ disabled: Bool) { calls.append(disabled) }
}
```

Tests — **no view is constructed in any of them; that is the whole point**:

```swift
func testACaptureFinalizesWithNoViewMounted() async throws {
    // RED reason today: handleFinalizeQueue() is only ever called from
    // CaptureView.body's .onChange, so with no view nothing drains the queue and the
    // capture never reaches the library.
    let model = makeModel()                       // fakes, temp captures root
    await model.bootstrap()
    await model.record()
    try await waitFor { model.coordinator.phase == .recording }
    await model.done()
    try await waitFor { model.receipt != nil }    // receipt is built at the END of finishCurrentCapture
    XCTAssertEqual(model.library.allEntries.count, 1)
}

func testASecondCaptureFinalizesToo() async throws {
    // Cardinality ≥ 2: `finishCurrentCapture` REPLACES the coordinator (`coordinator = spawn()`),
    // so an observation armed against the first instance and never re-armed passes the
    // single-capture test and fails here.
    ...  // record/done twice, assert allEntries.count == 2
}

func testIdleTimerIsHeldWhileRecordingAndReleasedAfterwards() async throws {
    let timer = FakeIdleTimer()
    let model = makeModel(idleTimer: timer)
    await model.bootstrap()
    XCTAssertEqual(timer.current, false, "an idle model must not hold the display awake")
    await model.record()
    try await waitFor { timer.current == true }
    await model.done()
    try await waitFor { timer.current == false }
}

func testIdleTimerFollowsTheRespawnedCoordinator() async throws {
    // Same re-arm hazard as the second-capture test, on the idle-timer half.
}

func testAPhaseChangeDuringTheDispatchHopIsNotLost() async throws {
    // The observation is LEVEL-triggered, not edge-triggered: every handler re-reads
    // current state, so a phase that moves twice inside one main-actor turn still ends
    // with the handlers agreeing with the coordinator. Drive record() and done() back
    // to back with no await between, then assert the entry lands.
}
```

`waitFor` is a small polling helper — poll the observable, `await Task.yield()` between attempts, never `Task.sleep` as the signal (repo precedent: the #4/#22 flake family; a sleep-shielded assertion is what hid `testFailedResumeDiskWriteReturnsToInterruptedNotRecording`).

- [ ] **Step 3: Run them and watch `testACaptureFinalizesWithNoViewMounted` fail by TIMING OUT on `model.receipt != nil`**, with `model.library.allEntries` empty. That is the correct reason. Record the output.

- [ ] **Step 4: Implement**

Add to `CaptureScreenModel`:

```swift
private let idleTimer: any IdleTimerControlling

var keepsDisplayAwake: Bool { coordinator.phase.keepsDisplayAwake }

/// Everything that used to be an `.onChange` on `CaptureView` — the screen is no longer
/// permanently mounted, so a view-lifecycle hook is no longer a guarantee about anything.
///
/// LEVEL-triggered, not edge-triggered: `onChange` fires *before* the new value is
/// visible, so the work hops to the next main-actor turn and every handler re-reads
/// current state rather than trusting a delivered value. Consequence worth stating:
/// changes that land inside the hop window are coalesced, never lost, because no handler
/// depends on seeing a particular edge.
///
/// Re-arming is mandatory and load-bearing twice over: `withObservationTracking` fires at
/// most once per arm, and `finishCurrentCapture` REPLACES `coordinator` outright, so the
/// arm must follow the new instance. Reading `coordinator.phase` registers a dependency on
/// `self.coordinator` as well as on `phase`, which is what makes the swap itself a trigger.
private func armCoordinatorObservation() {
    withObservationTracking {
        _ = coordinator.phase
        _ = coordinator.finalizeQueue
    } onChange: { [weak self] in
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handlePhase()
            self.handleFinalizeQueue()
            self.idleTimer.setIdleTimerDisabled(self.keepsDisplayAwake)
            self.armCoordinatorObservation()
        }
    }
}
```

Call `armCoordinatorObservation()` and `idleTimer.setIdleTimerDisabled(keepsDisplayAwake)` as the **last two lines of `init`** (all stored properties are assigned by then, so `self` is usable) — the second is the `initial: true` the old `.onChange` carried.

Then delete from `CaptureView.body`:
- `.onChange(of: model.coordinator.phase) { _, _ in model.handlePhase() }` (`:820-822`)
- `.onChange(of: model.coordinator.finalizeQueue) { _, _ in model.handleFinalizeQueue() }` (`:823-825`)
- the entire `#if os(iOS)` block (`:833-854`: the `initial: true` onChange, the `onAppear`, the `onDisappear`)

Leave `.task { await model.bootstrap() }` and `.onChange(of: model.library.allEntries)` alone — the latter is Task 3's.

- [ ] **Step 5: Full suite + both builds green, commit**

```bash
git add Raconte/Capture/Debug/IdleTimerControl.swift Raconte/Capture/UI/CaptureScreenModel.swift \
        Raconte/Capture/UI/CaptureView.swift RaconteTests/CaptureScreenModelObservationTests.swift project.yml
git commit -m "feat: coordinator dispatch and idle-timer hold move into the model (nav T2)"
```

- [ ] **Step 6: Mutation checks (report failing output verbatim)**

1. Delete the `self.armCoordinatorObservation()` re-arm line → `testASecondCaptureFinalizesToo` and `testIdleTimerFollowsTheRespawnedCoordinator` must both fail while the single-capture tests still pass. **This is the mutation that proves the tests are not vacuous.**
2. Remove `_ = coordinator.finalizeQueue` from the tracked block → `testACaptureFinalizesWithNoViewMounted` must fail (phase alone flips to `.captured` before the queue is filled — `handleFinalizeQueue`'s own doc comment at `CaptureScreenModel.swift` says exactly this).
3. Replace `self.idleTimer.setIdleTimerDisabled(self.keepsDisplayAwake)` with `…(true)` → the release-afterwards assertion must fail.

**Adversarial reviewer should probe:**
- **Double-fire**: grep (comments stripped) that no view still calls `handlePhase` / `handleFinalizeQueue`; then probe that `handlePhase` runs at most once per `.recording` entry (instrument a counter) — it is documented idempotent, but a doubled `markOpeningVoice` would reset `currentVoice` and mis-attribute a whole entry.
- **Observation leak**: instrument the arm count; after N phase changes there must be exactly one live observation, not N.
- **The willSet gap**: write a throwaway probe that reads `coordinator.phase` *inside* the `onChange` closure without the `Task` hop and confirm it observes the OLD value — i.e. confirm the hop is load-bearing, not decoration.
- **Retain cycle**: `armCoordinatorObservation` captures `[weak self]` twice (closure and Task). Confirm a `CaptureScreenModel` deallocates when released.
- Whether `keepsDisplayAwake` on macOS is genuinely inert (the no-op impl) and `CaptureStateDisplayAwakeTests` still passes unmodified.

---

### Task 3: Receipt reconcile becomes a model invariant (#62)

Design §5.1, verbatim: *"the rule moves into the model layer — `LibraryScreenModel`'s rescan path notifies `CaptureScreenModel.reconcileReceipt()` directly (model-to-model, no view involved). 'A receipt whose entry left the library is cleared' becomes a model invariant that holds regardless of what is mounted. The three existing #62 unit tests already pin the model behavior and must stay green; the deliberate restore-does-NOT-revive pin stays."*

**Files:**
- Modify: `Raconte/Library/LibraryScreenModel.swift` (observer seam + one call at the end of `rescan()`)
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift` (conformance + registration)
- Modify: `Raconte/Capture/UI/CaptureView.swift` (delete `:826-832`)
- Test: `RaconteTests/LibraryRescanObserverTests.swift`
- **Must pass unmodified:** `RaconteTests/CaptureScreenModelTests.swift:123` `testReconcileClearsTheReceiptWhenItsEntryIsTrashed`, `:136` `testReconcileKeepsTheReceiptWhileItsEntryExists`, `:147` `testRestoreDoesNotReviveAReconciledReceipt`; `RaconteUITests/CaptureUITests.swift:312` `testTrashingTheReceiptsEntryRetiresTheReceipt`.

**Interfaces:**
- Produces:

```swift
@MainActor protocol LibraryRescanObserver: AnyObject {
    func libraryDidRescan()
}
extension LibraryScreenModel {
    /// WEAK. `CaptureScreenModel` holds `library` strongly; a strong back-reference is a
    /// cycle, and although both live for the app's lifetime, every test that builds a pair
    /// would leak one.
    weak var rescanObserver: (any LibraryRescanObserver)?
}
extension CaptureScreenModel: LibraryRescanObserver { func libraryDidRescan() }
```

- [ ] **Step 1: Write the failing tests**

```swift
func testTrashingThroughTheLibraryClearsTheReceiptWithNoViewMounted() async throws {
    // RED reason today: reconcileReceipt() is called only from CaptureView's
    // .onChange(of: model.library.allEntries). With no view, trashing leaves the receipt
    // naming an entry that is gone — the #62 symptom, one layer down.
    let model = makeModelWithACommittedReceipt()
    let id = try XCTUnwrap(model.receipt?.captureID)
    _ = await model.library.trashEntry(id)        // trashEntry ends in rescan()
    XCTAssertNil(model.receipt)
}

func testASupersededRescanDoesNotNotify() async throws {
    // rescan() bumps `scanGeneration` and returns EARLY (LibraryScreenModel.swift:176)
    // without publishing when it has been overtaken. A notify placed above that guard
    // would hand the observer a view of the world the model never adopted.
    ...  // start two overlapping rescans; assert the observer is notified exactly once,
         // and only after `allEntries` reflects the later scan
}

func testTheObserverIsHeldWeakly() async throws {
    let library = LibraryScreenModel(capturesRoot: tempRoot)
    do {
        let capture = makeModel(library: library)
        XCTAssertNotNil(library.rescanObserver)
        _ = capture
    }
    XCTAssertNil(library.rescanObserver, "a strong back-reference is a retain cycle")
}

func testAFreshReceiptSurvivesTheRescanThatPrecedesIt() async throws {
    // finishCurrentCapture does rescan() and THEN buildReceipt() (CaptureScreenModel:569-574).
    // Pins that the new hook cannot reconcile away a receipt that has just been built,
    // and that the entry the receipt names is present in `allEntries` at that moment.
    ...
}
```

- [ ] **Step 2: Run and watch the first test fail with `model.receipt` non-nil.** Record the output.

- [ ] **Step 3: Implement**

In `LibraryScreenModel.rescan()`, after `isLoading = false` (the last line of the published block, **below** the `guard generation == scanGeneration else { return }` at `:176`):

```swift
// Model-to-model, no view in the loop (#62, nav redesign §5.1). Placed after every
// published assignment and after the superseded-scan guard: the observer's whole job is
// to compare the receipt against `allEntries`, so it must never see a half-applied scan
// or one this model has already abandoned.
rescanObserver?.libraryDidRescan()
```

In `CaptureScreenModel`, add the conformance and register as the **last line of `init`**:

```swift
resolvedLibrary.rescanObserver = self
```

Delete `CaptureView.swift:826-832` (the `.onChange(of: model.library.allEntries)` block and its comment).

- [ ] **Step 4: Full suite (including the four untouched #62 tests) + both builds green, commit**

```bash
git add Raconte/Library/LibraryScreenModel.swift Raconte/Capture/UI/CaptureScreenModel.swift \
        Raconte/Capture/UI/CaptureView.swift RaconteTests/LibraryRescanObserverTests.swift
git commit -m "feat: receipt reconcile is a model invariant, not a view hook (nav T3, #62)"
```

- [ ] **Step 5: Mutation checks**

1. Move `rescanObserver?.libraryDidRescan()` above the `guard generation == scanGeneration` line → `testASupersededRescanDoesNotNotify` must fail.
2. Change `weak var rescanObserver` to `var rescanObserver` → `testTheObserverIsHeldWeakly` must fail.
3. Make `libraryDidRescan()` an empty body → `testTrashingThroughTheLibraryClearsTheReceiptWithNoViewMounted` must fail while the three original `reconcileReceipt()`-calling tests still pass (proving those three do **not** cover the wiring, which is why this task's tests exist).

**Adversarial reviewer should probe:**
- That `git diff` shows **zero** changes to `CaptureScreenModelTests.swift` and to `CaptureUITests.swift:312`.
- Every `LibraryScreenModel` mutation path ends in `rescan()` — `moveEntry:259`, `setBackdate:280`, `setJournalCover:293`, `removeJournalCover:298`, `trashEntry:323`, `restoreEntry:338`, `deleteEntryPermanently:364`, `sweepTrash:375` (conditional). Confirm by reading, and confirm the conditional one is deliberate.
- That restore still does **not** revive the receipt after a reconcile through the new path (the deliberate pin).

---

### Task 4: `NavigationSplitView` skeleton, and the iPhone-collapse verification

The whole synthesis rests on a pre-selected sidebar item surviving the compact-width collapse. **Verify it here, in a task whose only job is the container, not at Gate A.**

Old routes (`capture.libraryButton`, `capture.libraryDoor`, `RootDestination.library`, `library.trashLink`) are deliberately **kept working** so every existing UI test stays green through this task.

**Files:**
- Modify: `Raconte/App/RaconteApp.swift` (owns the models and the router)
- Modify: `Raconte/App/ContentView.swift` (becomes the split view)
- Create: `RaconteUITests/NavigationUITests.swift`
- Modify: `Raconte/App/Place.swift` if the fallback is needed (see Step 5)

**Interfaces:**
- Produces:

```swift
@MainActor @Observable
final class AppServices {
    let library: LibraryScreenModel
    let capture: CaptureScreenModel
    let router: AppRouter
    init()           // library = .live(); capture = .liveWithTranscription(library:); router = AppRouter()
}
```

`RaconteApp` holds `@State private var services = AppServices()` and passes it to `ContentView(services:)`. This exists now (rather than in Task 8) because macOS `Commands` live on the `Scene`, outside any view, and cannot reach a `ContentView`-private `@State`.

**Invariants this task can break (design §8, verbatim):**
> 3. **One `LibraryScreenModel` app-wide** (`ContentView.swift:6-8`; asserted `CaptureView.swift:165-166`). The sidebar and every list resolve entries through it.
> 4. **UI-test identifiers live on links, never on rows inside them** (`library.entryLink`, `capture.recentRow`); **no identifier on control-bar containers** (flattening trap, hit three times).
> 6. **`EntryDetailView` keeps its own `item` copy** (`EntryDetailView.swift:10-15`) — journal reassignment must not blank a pushed detail.
> 7. Detail sub-models built once in `init`, never re-minted per body evaluation (`EntryDetailView.swift:27-47`).

- [ ] **Step 1: Write the failing UI test** in `RaconteUITests/NavigationUITests.swift`

```swift
/// The load-bearing platform claim of the whole redesign: `NavigationSplitView` with a
/// non-nil sidebar selection, collapsed to a stack on iPhone, must show the DETAIL column
/// at launch — not the places list. If this fails, the fallback in Step 5 applies and the
/// owner must be told at Gate A that the phone's IA is a toolbar button, not a chevron.
func testLaunchLandsDirectlyOnCaptureWithNoTaps() {
    let app = launchApp()
    XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                  "the app did not launch into the capture screen")
    XCTAssertFalse(app.buttons["sidebar.allEntries"].firstMatch.exists,
                   "the places list is showing instead of capture")
}

func testTheDetailColumnStillPushesAnEntryFromTheCaptureScreen() {
    // The existing recentRow push must survive the container swap unchanged.
}
```

`launchApp()` is copied from `CaptureUITests.swift:16-21` for now; Task 5 replaces all four copies with the shared helper.

- [ ] **Step 2: Run it against unmodified main and watch `testLaunchLandsDirectlyOnCaptureWithNoTaps` PASS** (there is no sidebar today, so `sidebar.allEntries` cannot exist). Note this honestly in the task report: this test is **vacuous before the change** and only becomes discriminating in Step 4. Its RED evidence is the Step 6 mutation, not Step 2.

- [ ] **Step 3: Rewrite `ContentView`**

```swift
struct ContentView: View {
    let services: AppServices
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        @Bindable var router = services.router
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Task 4 stub: one row. Task 5 replaces this with SidebarView.
            List(selection: Binding(get: { router.place },
                                    set: { router.select($0 ?? .capture) })) {
                Text("Capture").tag(Place.capture)
                    .accessibilityIdentifier("sidebar.capture")
            }
            .navigationTitle("Raconte")
        } detail: {
            NavigationStack(path: $router.detailPath) {
                detailRoot
                    .navigationDestination(for: LibraryDestination.self, destination: destination(for:))
                    // Retired in Task 5; kept here so every existing UI test stays green.
                    .navigationDestination(for: RootDestination.self) { _ in
                        LibraryView(model: services.library)
                    }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
    }

    @ViewBuilder private var detailRoot: some View {
        switch services.router.place {
        case .capture:            CaptureView(model: services.capture)
        case .allEntries, .journal, .trash, .debug:  CaptureView(model: services.capture) // Task 5
        }
    }
}
```

`destination(for:)` carries the issue-#32 `ContentUnavailableView` **verbatim** from `ContentView.swift:37-53`, `entry.unavailable` identifier included. Do not paraphrase the copy; move the comment with it.

Note the `minWidth` change: 420 does not fit a sidebar plus a usable detail column. 720 is the smallest that keeps the capture control bar's `maxWidth: 560` band un-squeezed beside a ~200 pt sidebar.

- [ ] **Step 4: Run the new test, the full unit suite, `CaptureUITests`, `CaptureControlsUITests`, `VoiceMarkingUITests`, `TranscriptEditorUITests` — all green on iPhone 17 simulator.** Then build and run on macOS.

- [ ] **Step 5: THE VERIFICATION GATE — if `testLaunchLandsDirectlyOnCaptureWithNoTaps` fails on the iPhone simulator, apply the fallbacks in this order and record which one was needed.**

1. Add `.navigationSplitViewStyle(.balanced)`.
2. Seed the selection again after first layout: `.onAppear { if services.router.place != .capture && services.router.detailPath.isEmpty { services.router.select(.capture) } }` — harmless, and covers a collapse that resets selection to nil.
3. **Structural fallback (do this only if 1 and 2 fail).** Split the container by size class, keeping one router and one `Place`:
   ```swift
   #if os(iOS)
   @Environment(\.horizontalSizeClass) private var sizeClass
   // compact ⇒ NavigationStack(path:) rooted at CaptureView, with a "Places" toolbar
   // button that pushes the sidebar list as a screen; regular ⇒ NavigationSplitView.
   #endif
   ```
   Both branches read and write the same `AppRouter`, so `Place.swift`, `SidebarView`, and every later task are unaffected. **The cost is IA, and the owner must be told at Gate A:** the phone gets a "Places" toolbar button rather than the design's back-chevron-reveals-the-list. Note it in the task report and add it to the Gate A smoke script.

- [ ] **Step 6: Mutation check**

Set the router's initial place to `.allEntries` (`PlaceRouting.launchPlace`) and re-run `testLaunchLandsDirectlyOnCaptureWithNoTaps` on the iPhone simulator. **It must fail** — either because `capture.record` never appears, or because `sidebar.allEntries` is visible. If it still passes, the test is not measuring collapse behaviour and must be rewritten before proceeding. Revert the mutation.

- [ ] **Step 7: Commit**

```bash
git add Raconte/App/RaconteApp.swift Raconte/App/ContentView.swift Raconte/App/Place.swift \
        RaconteUITests/NavigationUITests.swift project.yml
git commit -m "feat: NavigationSplitView root with capture pre-selected; old routes retained (nav T4)"
```

**Adversarial reviewer should probe:**
- Re-run the collapse verification independently on a **cold** simulator (`simctl shutdown all` first) — first-launch layout is where this behaviour differs.
- That `services.library === services.capture.library` (invariant 3): assert it, do not read it.
- Whether `EntryDetailView`'s three sub-models are still built once (invariant 7) — the destination builder must not re-mint them; check that `destination(for:)` constructs `EntryDetailView(model:item:)` exactly as `ContentView.swift:45` did.
- macOS: that the window at `minWidth: 720` shows both columns and the control bar still measures ≤ ⅓ (run `CaptureControlsUITests` — it runs on the simulator, so also eyeball the Mac build).
- That `RootDestination` is still reachable and every pre-existing UI test passed **unmodified** in this task.

---

### Task 5: Sidebar content, place routing, and the UI-test reroute

The big mechanical task. Everything the sidebar replaces is deleted here.

**Files:**
- Create: `Raconte/App/SidebarView.swift`
- Create: `RaconteUITests/UITestNavigation.swift`
- Modify: `Raconte/App/ContentView.swift` (real detail root; delete `RootDestination`)
- Modify: `Raconte/Library/UI/LibraryView.swift` (delete chips, delete trash link, `LibraryDestination` loses `.trash`, title from the place)
- Modify: `Raconte/Capture/UI/CaptureView.swift` (delete `libraryDoor` `:1089-1120` and its mount `:923-925`; delete the `DEBUG-HARNESS-MOUNT` button + sheet `:886-901`)
- Modify: `Raconte/Capture/UI/CaptureLayoutModel.swift` (delete `showsLibraryDoor`)
- Modify: `Raconte/Capture/UI/CaptureSurface.swift` (delete `CaptureLabel.libraryDoor` `:182` and `.libraryDoorChevron` `:183`, and their four switch arms at `:208, :212, :231/:234, :241/:244`)
- Modify: `RaconteTests/CaptureLayoutModelTests.swift` (`:28, :35, :87, :88, :117, :120`)
- Modify: `RaconteUITests/CaptureUITests.swift`, `CaptureControlsUITests.swift`, `VoiceMarkingUITests.swift`, `TranscriptEditorUITests.swift`, `NavigationUITests.swift`

**Invariants this task can break (design §8, verbatim):**
> 1. **Color pins**: scoped `.environment(\.colorScheme, .dark)` sites stay exactly as scoped (`CaptureView.swift:1313, 1456, 1549, 1714, 1170`); `preferredColorScheme` remains forbidden anywhere in the capture subtree.
> 2. **Foreground-style resets** at every presentation boundary out of the capture surface (`CaptureView.swift:899, 1335, 1343, 1358, 1367, 1502`; `PrecisionDatePicker.swift:226-229`) — the white-on-white alert class.
> 4. **UI-test identifiers live on links, never on rows inside them** (`library.entryLink`, `capture.recentRow`); **no identifier on control-bar containers** (flattening trap, hit three times).
> 5. **Back-is-Done** semantics on editor / Mark voices / revision history stay push-based — converting any to a sheet changes the save contract.
> 8. The capture screen's internal content (bands, control bar, marker buttons, §53/§Option-B geometry and its `CaptureControlsUITests` pins) is **out of scope** — this design changes the frame around screens, not the screens.

Note on invariant 2: deleting the Debug sheet deletes the `.foregroundStyle(Color.primary)` at `CaptureView.swift:899`. That is correct — the reset existed because the sheet was a presentation boundary out of the capture surface, and the Debug place is not inside that surface at all. The other five sites at `:1335, :1343, :1358, :1367, :1502` must remain untouched.

#### The rerouting rule (stated once, applied everywhere)

> Any UI-test step that reached the library by tapping `capture.libraryButton` or `capture.libraryDoor` now calls `openPlace(app, "sidebar.allEntries")`. Any step that reached the Trash by then tapping `library.trashLink` now calls `openPlace(app, "sidebar.trash")` **directly** — the two-hop route is gone, and the `trashLink.label.contains("1")` waits it carried are deleted, not translated (each of those tests already asserts `trash.row.remaining` immediately afterwards, which is the stronger signal). Entry rows keep `library.entryLink`, and the identifier stays on the **link**, never on `LibraryEntryRow` (invariant 4).

- [ ] **Step 1: Create the shared helper file first**

`RaconteUITests/UITestNavigation.swift` — top-level functions, not private methods, so all four classes share one implementation:

```swift
import XCTest

/// Reveal the sidebar and select a place.
///
/// On macOS/iPad both columns are visible and the row is a straight tap. On iPhone the
/// split view is COLLAPSED to a stack whose root is the places list, so the sidebar is
/// reached by the navigation bar's back button — which is also exactly what the owner
/// does. `sidebar.toggle` covers the regular-width case where the column is hidden.
func openPlace(_ app: XCUIApplication,
               _ identifier: String,
               file: StaticString = #filePath,
               line: UInt = #line) {
    let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    if !row.waitForExistence(timeout: 3) {
        if app.buttons["sidebar.toggle"].firstMatch.exists {
            app.buttons["sidebar.toggle"].firstMatch.tap()
        } else if app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }
    XCTAssertTrue(row.waitForExistence(timeout: 15),
                  "could not reach \(identifier)", file: file, line: line)
    row.tap()
}

/// Back to the capture place from anywhere.
func openCapture(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    openPlace(app, "sidebar.capture", file: file, line: line)
}
```

`xcodegen generate` after creating it.

- [ ] **Step 2: Write the failing UI tests** (append to `NavigationUITests.swift`)

```swift
func testTheSidebarIsReachableWhileRecording() {
    // Design §3: the Debug/library routes used to exist only in the IDLE branch of the
    // setup band, which is why the owner failed to find the Library door twice and why the
    // Debug modal trapped the app. Reachability must no longer depend on capture phase.
    let app = launchApp()
    press(recordButton(app))
    openPlace(app, "sidebar.allEntries")
    XCTAssertTrue(app.descendants(matching: .any)
                    .matching(identifier: "library.list").firstMatch.waitForExistence(timeout: 15))
}

func testTheSidebarIsReachableWhileAReceiptIsUp() {
    // Design §3: "it no longer hides the exits."
}

func testTheDebugPlaceIsAScreenNotAModal() {
    let app = launchApp()
    openPlace(app, "sidebar.debug")
    XCTAssertTrue(app.descendants(matching: .any)
                    .matching(identifier: "debug.list").firstMatch.waitForExistence(timeout: 15))
    openCapture(app)      // must be possible: a modal sheet would make this impossible
    XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15))
}

func testSelectingAJournalPlaceScopesTheEntryList() {
    // Record into the default journal, create a second journal, select it in the sidebar,
    // assert the list is empty; select the first, assert one row. Cardinality ≥ 2 journals.
}
```

- [ ] **Step 3: Verify RED via `git stash`** (repo memory: swiftui-verify-red-via-stash). Write the tests, `git stash push` the production files listed above, run the new tests against the stashed-out code, confirm each fails because `sidebar.*` does not exist (not because the app crashed), `git stash pop`.

- [ ] **Step 4: Implement `SidebarView`**

```swift
struct SidebarView: View {
    let services: AppServices

    var body: some View {
        @Bindable var router = services.router
        List(selection: Binding(get: { router.place },
                                set: { router.select($0 ?? .capture) })) {
            ForEach(rows) { row in
                SidebarRowView(row: row,
                               cover: row.journalID.flatMap { services.library.journalCovers[$0] },
                               live: CaptureSidebarRow.make(phase: .idle, elapsed: 0))  // Task 6
                    .tag(row.place)
                    .accessibilityIdentifier(row.accessibilityIdentifier)
            }
        }
        .navigationTitle("Raconte")
        // NO accessibilityIdentifier on the List itself — the container-flattening trap
        // this repo has hit three times (design §8.4).
    }

    private var rows: [PlaceRow] {
        var ranges: [String: String] = [:]
        for journal in services.library.journals {
            if let range = services.library.dateRange(forJournal: journal.id) {
                ranges[journal.id] = range.formatted()
            }
        }
        #if DEBUG
        let includesDebug = true
        #else
        let includesDebug = false
        #endif
        return SidebarModel.rows(journals: services.library.journals,
                                 dateRanges: ranges,
                                 includesDebug: includesDebug)
    }
}
```

Journal rows draw `JournalCoverThumbnail(data: cover, size: 30)` (`Raconte/Library/UI/JournalCoverImage.swift`), the same component the retired chips used, so a journal with no cover looks exactly as it did.

- [ ] **Step 5: Wire the detail root**

```swift
@ViewBuilder private var detailRoot: some View {
    switch services.router.place {
    case .capture:
        CaptureView(model: services.capture)
    case .allEntries, .journal:
        LibraryView(model: services.library, title: libraryTitle)
    case .trash:
        TrashView(model: services.library)
    case .debug:
        #if DEBUG
        DebugMenuView()
        #else
        CaptureView(model: services.capture)
        #endif
    }
}
```

`AppRouter.select` additionally drives the scope: in `ContentView`, `.onChange(of: services.router.place) { _, place in if let scope = PlaceRouting.journalScope(for: place) { Task { await services.library.selectJournalScope(scope) } } }`. Also `.onChange(of: services.library.journals)` re-resolving via `PlaceRouting.resolve` so a deleted journal's place falls back to `.capture` rather than showing an empty list forever.

- [ ] **Step 6: Delete the retired surfaces**

- `CaptureView.swift`: delete `private var libraryDoor` (`:1089-1120`) and its `if layout.showsLibraryDoor { libraryDoor }` mount (`:923-925`); delete the whole `#if DEBUG` `DEBUG-HARNESS-MOUNT` block (`:886-901`) including `@State private var showDebugMenu` (`:760-762`).
- `CaptureLayoutModel.swift`: delete `showsLibraryDoor` and its doc comment; update all three `.init(...)` call sites.
- `ContentView.swift`: delete `enum RootDestination` and its `navigationDestination(for:)`.
- `LibraryView.swift`: delete `journalChips`, `chip(title:subtitle:cover:isSelected:action:)`, `trashLink`, the `.toolbar` that hosts it, and `case trash` from `LibraryDestination`. Add `let title: String` and `.navigationTitle(title)`.
- `TrashView` gains `.navigationTitle("Trash")` (it had none; it was always pushed under the library's title).

- [ ] **Step 7: Reroute every affected UI test.** The complete enumeration — nothing else in `RaconteUITests/` touches these routes.

**Via `capture.libraryButton` → `library.trashLink` (4 traversals, 3 tests, all `CaptureUITests.swift`):**
| test | lines to change |
|---|---|
| `testTrashAndRestoreAnEntry` (254-294) | `:279` tap → `openPlace(app, "sidebar.trash")`; delete `:280-282` trashLink lookup and `:283` label wait |
| `testDeleteNowPermanentlyRemovesEntry` (350-415) | `:374` → `openPlace(app, "sidebar.trash")`; `:396` generic `navigationBars.buttons.firstMatch.tap()` → `openPlace(app, "sidebar.allEntries")` (the `:397` zero-`library.row.duration` assertion stays); `:409` (post-relaunch) → `openPlace(app, "sidebar.trash")` and replace the `:412` trashLink-label check with `XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "trash.empty").firstMatch.waitForExistence(timeout: 15))` |
| `testMoveToTrashWhilePlaybackIsRunningStillTrashesTheEntry` (426-469) | `:457` → `openPlace(app, "sidebar.trash")`; delete the trashLink lookup/label wait |

**Via `capture.libraryDoor` (4 sites, 3 files):**
| test | change |
|---|---|
| `CaptureUITests.testRepeatedRecordStopCyclesProduceSeparateEntries` (154-182), `:178` | tap → `openPlace(app, "sidebar.allEntries")`; `:180` `libraryRows(app).count == 3` stays |
| `CaptureControlsUITests.testStoppingRaisesAReceiptAndClearsTheLiveTranscript` (225-254), `:252` | the door was a proxy for "the landing screen did not come back". Replace with `XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "capture.recentRow").firstMatch.exists)` — `CaptureLayoutModel` sets `showsLastEntry: false` in receipt mode, so this is the same claim against a control that still exists |
| `CaptureControlsUITests.testLandingScreenShowsOneEntryAndAProminentLibraryRoute` (261-294), `:266-273` | its subject is retired. Rename to `testLandingScreenShowsExactlyOneRecentEntryAndAReachableLibrary`; delete the `capture.libraryDoor` existence/hittability assertions and the `capture.seeAllLink` absence assertion; keep the two record/stop/dismiss cycles and the "exactly one `capture.recentRow`" assertion at `:288-293`; add `openPlace(app, "sidebar.allEntries")` + assert `library.list` appears, so the "there is a route to everything else from the landing screen" claim still has a pin |
| `VoiceMarkingUITests.openSeededEntry(_:row:)` (66-75), `:69` | tap → `openPlace(app, "sidebar.allEntries")`; the `library.entryLink` `boundBy:` lookup at `:71-74` is unchanged |

**Untouched by design (verify, do not edit):** every `capture.recentRow` path — `CaptureUITests` helper `recentRows(_:)` at `:41-43` and its 16 call sites, `TranscriptEditorUITests.openSeededEntry(_:)` at `:76-81`, `CaptureControlsUITests:289/292`. These push onto the detail stack from the capture place, which still works.

**Unit-test fallout, two places:**

1. `RaconteTests/CaptureLayoutModelTests.swift` — remove the `showsLibraryDoor` assertions at `:28, :35, :87, :88, :117, :120`. Do **not** weaken the surrounding assertions; `showsLastEntry` must keep its per-mode pins.
2. `RaconteTests/CaptureLabelTests.swift:154` `testEveryLabelCaseIsActuallyAppliedToAView` **will go red** the moment `libraryDoor` is deleted from the view — that adversary exists precisely to catch a `CaptureLabel` case that no view applies (it is what found the 15 pt journal name and the dead `seeAllLink`). The correct response is to **delete the two now-unused cases**, `CaptureLabel.libraryDoor` (`CaptureSurface.swift:182`) and `.libraryDoorChevron` (`:183`), together with their four switch arms (`:208, :212`, `:231/:234`, `:241/:244`). **Do not add an exemption to the test** — an exemption list is exactly the escape hatch that made `seeAllLink` invisible for weeks. Report the red output before deleting the cases: it is this task's cleanest RED evidence.

- [ ] **Step 8: Full unit suite + all four UI test classes + `NavigationUITests` green on iPhone 17; macOS build green. Commit.**

```bash
git add -A
git commit -m "feat: sidebar of places replaces the library door, toolbar button and Debug sheet (nav T5)"
```

- [ ] **Step 9: Mutation checks**

1. Make `SidebarView.rows` always pass `includesDebug: false` → `testTheDebugPlaceIsAScreenNotAModal` must fail.
2. Delete the `.onChange(of: services.router.place)` scope wiring → `testSelectingAJournalPlaceScopesTheEntryList` must fail.
3. Put an `.accessibilityIdentifier("sidebar.list")` on the sidebar `List` and re-run the suite → at least one `openPlace` must break (flattening). Revert. This is a live re-demonstration of invariant 4, not decoration.
4. Restore `CaptureLabel.libraryDoor` to `CaptureSurface.swift` without restoring the view → `testEveryLabelCaseIsActuallyAppliedToAView` must fail. This proves the adversary was honoured rather than defeated.

**Adversarial reviewer should probe:**
- **Row-index coupling**: `VoiceMarkingUITests` addresses seeded rows `boundBy: 0/1/2` (documented `:48-65`). Run those three tests and confirm the three seeded entries appear in the same order as before chip removal; if not, the fix is to address rows by their snippet text, not to renumber.
- Source-scan (comments stripped) that `RootDestination`, `capture.libraryDoor`, `capture.libraryButton`, `library.trashLink`, `library.journalChip` appear **nowhere** in `Raconte/` or `RaconteUITests/`.
- The five `.environment(\.colorScheme, .dark)` sites and the five surviving `.foregroundStyle(Color.primary)` sites are intact; `preferredColorScheme` still appears nowhere in the capture subtree.
- macOS light mode by eye: sidebar readable, capture surface still near-black, no white-on-white in the New Journal / Rename alerts (those alerts still live inside `JournalHeaderView` in this task).
- That `TrashView` and `LibraryView` are no longer nested under each other — a Trash reached as a place must still restore and Delete-Now correctly (`testTrashAndRestoreAnEntry`, `testDeleteNowPermanentlyRemovesEntry`).

---

### Task 6: The live-capture indicator, and the recording-survives-navigation pin

Design §5, verbatim: *"Recording survives navigation — the coordinator already lives in `CaptureScreenModel`, owned at the app root; unmounting the capture view must not touch it. The sidebar's live indicator (§3) is the visibility guarantee. A UI test pins: start recording → navigate to All Entries → return → same recording still running, elapsed time advanced."*

**Files:**
- Modify: `Raconte/App/Place.swift` (add `CaptureSidebarRow`)
- Modify: `Raconte/App/SidebarView.swift`
- Create: `RaconteTests/CaptureSidebarRowTests.swift`
- Modify: `RaconteUITests/NavigationUITests.swift`

**Interfaces:**
- Produces:

```swift
struct CaptureSidebarRow: Equatable, Sendable {
    var isLive: Bool
    var elapsedText: String?     // nil when not live
    /// Exhaustive switch over CaptureState, no `default` — same rule as
    /// CaptureLayoutModel.make and MarkerControlsModel.make.
    static func make(phase: CaptureState, elapsed: TimeInterval) -> CaptureSidebarRow
}
```

`isLive` is true for exactly `.preparing, .recording, .interrupted, .resuming, .stopping` — the same set `CaptureLayoutModel.make` treats as `.capturing` (`CaptureLayoutModel.swift:116`). `elapsedText` uses `CaptureCoordinator.formatDuration(_:)` (`CaptureCoordinator.swift:837`, already `nonisolated static`).

- [ ] **Step 1: Write the failing tests**

```swift
func testIsLiveHoldsForExactlyTheCapturingPhases() {
    // Quantified over EVERY CaptureState — the repo's own precedent
    // (MarkerControlsModel's `isEnabled == (phase == .recording)` across all cases).
    // A hand-picked subset is how a new phase silently gets the wrong answer.
    let capturing: Set<CaptureState> = [.preparing, .recording, .interrupted, .resuming, .stopping]
    for phase in CaptureState.allCases {
        XCTAssertEqual(CaptureSidebarRow.make(phase: phase, elapsed: 12).isLive,
                       capturing.contains(phase),
                       "\(phase)")
    }
}

func testElapsedTextIsPresentOnlyWhileLive() {
    XCTAssertEqual(CaptureSidebarRow.make(phase: .recording, elapsed: 65).elapsedText, "1:05")
    XCTAssertNil(CaptureSidebarRow.make(phase: .idle, elapsed: 65).elapsedText,
                 "an idle row showing a stale duration reads as a recording that is still running")
}
```

And the UI pin:

```swift
func testARecordingSurvivesNavigatingAwayAndComingBack() {
    let app = launchApp()
    press(recordButton(app))
    let live = app.descendants(matching: .any).matching(identifier: "sidebar.capture.live").firstMatch

    openPlace(app, "sidebar.allEntries")
    XCTAssertTrue(live.waitForExistence(timeout: 15),
                  "a recording is invisible from everywhere but the capture screen")
    let first = live.label

    openCapture(app)
    XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15))
    waitUntil(20, "elapsed time did not advance — the coordinator was torn down") {
        live.exists ? live.label != first : app.staticTexts.matching(identifier: "capture.elapsed").firstMatch.label != first
    }
    press(recordButton(app))     // stop
    finishReceipt(app)
    XCTAssertEqual(recentRows(app).count, 1, "the recording did not commit")
}
```

If `capture.elapsed` does not exist as an identifier on `RecStatusLine`, add it there — a one-line addition, and the only capture-screen edit this task is permitted (invariant 8 covers geometry, not identifiers; do not touch sizes, spacing, or `CaptureControlBarMetrics`).

- [ ] **Step 2: Run and watch RED.** Unit tests: undefined type — then get behavioural red from Step 5's mutations. UI test: RED via `git stash` on `SidebarView.swift` + `Place.swift`, confirming `sidebar.capture.live` never appears.

- [ ] **Step 3: Implement.** The sidebar's Capture row renders, when `isLive`: a red `Circle().frame(width: 8, height: 8)` plus `Text(elapsedText).monospacedDigit()`, the pair carrying `.accessibilityIdentifier("sidebar.capture.live")` and `.accessibilityLabel("Recording, \(elapsedText)")`. The row reads `CaptureSidebarRow.make(phase: services.capture.coordinator.phase, elapsed: services.capture.coordinator.elapsed)`.

Document the cost in the code: reading `coordinator.elapsed` re-evaluates the sidebar once per timer tick. That is accepted — the sidebar is a handful of rows, and the alternative (a coarser published "live" flag with no time) loses the thing the indicator exists for.

- [ ] **Step 4: Full suite + all UI classes + both builds green. Commit.**

```bash
git add Raconte/App/Place.swift Raconte/App/SidebarView.swift Raconte/Capture/UI/RecStatusLine.swift \
        RaconteTests/CaptureSidebarRowTests.swift RaconteUITests/NavigationUITests.swift project.yml
git commit -m "feat: live-capture indicator in the sidebar; recording survives navigation (nav T6)"
```

- [ ] **Step 5: Mutation checks**

1. Hardcode `isLive = true` → `testIsLiveHoldsForExactlyTheCapturingPhases` must fail (and name the offending phases).
2. Hardcode `isLive = (phase == .recording)` → the same test must fail on `.interrupted`/`.resuming`/`.stopping`. **Two distinct mutations, because a single one cannot distinguish "quantified over all cases" from "happens to pass".**
3. Return `elapsedText` unconditionally → `testElapsedTextIsPresentOnlyWhileLive` must fail.

**Adversarial reviewer should probe:**
- Whether `testARecordingSurvivesNavigatingAwayAndComingBack` would still pass if `AppServices` re-minted `CaptureScreenModel` on every body evaluation — delete the `@State` on `services` in `RaconteApp` (making it a plain `let` re-created per body) and confirm the test fails.
- Whether the indicator survives an interruption (`.interrupted` is in the live set by design — a paused-by-a-phone-call recording is still a recording the owner must be able to see).
- That the elapsed label is monospaced-digit (a proportional digit width makes the sidebar row jitter every second).

---

## Gate A — after Task 6

**Independent adversarial reviewer** (probe tests required, per repo convention — findings confirmed by throwaway tests, not by argument):

- Re-run the **full unit suite on the committed tree yourself**; do not trust the implementers' reported counts. Build iOS and macOS.
- **Probe 1 (the Task 2 blocker, end to end):** in the simulator, start a recording, navigate to All Entries, drive the coordinator to `.captured` without returning to the capture screen (use the DEBUG transition-breakpoint harness from the Debug place, or `simctl` backgrounding), and confirm the entry is finalized and appears in the library. On unmodified main this path silently never encodes.
- **Probe 2:** delete the `armCoordinatorObservation()` re-arm line and confirm the suite goes red in the two named places.
- **Probe 3:** confirm the sidebar is reachable in every capture phase by construction — the sidebar is outside `CaptureLayoutModel`'s switch entirely, so a source read is sufficient, but write the assertion down.
- **Probe 4:** retain-cycle check on `LibraryScreenModel.rescanObserver`.
- **Probe 5:** source-scan (comments stripped) that no view carries `.onChange` over `coordinator.phase`, `coordinator.finalizeQueue`, or `library.allEntries`.

**Owner smoke (5 steps, self-contained — restate every path and identifier; assume zero carried-over context):**

1. **Launch on iPhone.** Build and install; open Raconte from the home screen. **Pass:** the capture screen is on screen immediately — the big record button and the "Recording into <journal>" header, exactly as before. **Fail:** a list of places appears first, or anything else.
2. **Launch on Mac** (`~/Desktop/Raconte-nav.app`). **Pass:** a window with a sidebar on the left (Capture, your journals, All Entries, Trash, Debug) and the dark capture screen filling the right. Capture is highlighted.
3. **Reach the sidebar in all three capture states.** (a) From the idle capture screen, reveal the sidebar and tap **All Entries** — the entry list appears. Go back to **Capture**. (b) Tap the record button, and while it is recording reveal the sidebar again — **Pass:** the sidebar opens and the **Capture** row shows a red dot and a running time. (c) Tap **Capture**, stop the recording so the "Saved" receipt appears, and reveal the sidebar once more — **Pass:** it opens; the receipt does not block it.
4. **Recording survives navigation.** Start a recording, note the timer, tap **All Entries**, count slowly to ten, tap **Capture**. **Pass:** still recording, timer roughly ten seconds higher, and pressing stop saves a normal entry.
5. **Mac: ⌘Q while Debug is up.** Select **Debug** in the sidebar, then press ⌘Q. **Pass:** the app quits immediately. **Fail (the bug this fixes):** nothing happens.

If Task 4 needed its structural fallback, add: *on iPhone, the places list is reached by a "Places" button in the top-left toolbar rather than a back chevron* — and say so out loud, because it is a visible departure from the approved design.

Close Gate A in the ledger only when the reviewer's probes and all five owner steps pass.

---

### Task 7: The Debug place, reshaped

Design §6, verbatim: *"Build info (`BuildStamp.currentBuildDisplayString()`) promoted to the **top** — it is the row the owner actually visits. The nine transition-breakpoint toggles and the Kill-now button move **below**, under an explicit 'Harness — can wedge or kill the app' section header. Fencing is presentational (a section boundary + warning label), not functional — it is a DEBUG screen. `BuildStamp` work runs off the main actor (`.task` already exists; make the call genuinely async). Not the freeze cause, fixed on principle."*

**Files:**
- Modify: `Raconte/Capture/Debug/DebugMenuView.swift`
- Modify: `Raconte/Capture/Debug/BuildStamp.swift`
- Create: `RaconteTests/BuildStampAsyncTests.swift`
- Modify: `RaconteUITests/NavigationUITests.swift`

Today `DebugMenuView` carries **zero** `accessibility*` calls; every identifier below is new.

**Interfaces:**
- Produces: `BuildStamp.currentBuildDisplayStringAsync() async -> String?`
- Identifiers: `debug.list`, `debug.buildInfo`, `debug.killNow`, `debug.disarmAll`, `debug.row.<CaptureState.rawValue>`.

- [ ] **Step 1: Write the failing tests**

```swift
// RaconteTests/BuildStampAsyncTests.swift
func testAsyncStringMatchesTheSynchronousOne() async {
    let sync = BuildStamp.currentBuildDisplayString()
    let async = await BuildStamp.currentBuildDisplayStringAsync()
    XCTAssertEqual(sync, async)
}

func testAsyncCallDoesNotRequireTheMainActor() async {
    // Runs off the main actor; the point of the change. Compiles-and-passes IS the
    // assertion here, so it is paired with the mutation check below rather than
    // standing alone.
    let value = await Task.detached { await BuildStamp.currentBuildDisplayStringAsync() }.value
    XCTAssertEqual(value, BuildStamp.currentBuildDisplayString())
}
```

```swift
// RaconteUITests/NavigationUITests.swift
func testDebugPlaceShowsBuildInfoAboveTheHarness() {
    let app = launchApp()
    openPlace(app, "sidebar.debug")
    let build = app.descendants(matching: .any).matching(identifier: "debug.buildInfo").firstMatch
    let kill = app.descendants(matching: .any).matching(identifier: "debug.killNow").firstMatch
    XCTAssertTrue(build.waitForExistence(timeout: 15))
    XCTAssertTrue(kill.waitForExistence(timeout: 15))
    XCTAssertLessThan(build.frame.minY, kill.frame.minY,
                      "build info must sit above the harness — it is the row the owner visits")
}
```

A rendered-frame assertion, not a source scan: the repo's own `CaptureControlsUITests` precedent, and the only honest pin for "above".

- [ ] **Step 2: RED.** Unit tests fail to compile (then get behavioural red from Step 5). UI test: RED via `git stash` on `DebugMenuView.swift`, confirming `debug.buildInfo` does not exist at all.

- [ ] **Step 3: Implement**

```swift
struct DebugMenuView: View {
    private let controller = TransitionBreakpointController.shared
    @State private var buildInfo: String?

    var body: some View {
        List {
            Section("Build") {
                Text(buildInfo ?? "Build info unavailable")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("debug.buildInfo")
            }

            Section {
                Button(role: .destructive) { controller.abort() } label: {
                    Label("Kill now", systemImage: "bolt.trianglebadge.exclamationmark.fill")
                }
                .disabled(controller.waitingStates.isEmpty)
                .accessibilityIdentifier("debug.killNow")

                ForEach(CaptureState.allCases, id: \.self) { state in
                    row(for: state).accessibilityIdentifier("debug.row.\(state.rawValue)")
                }

                Button("Disarm all", role: .cancel) { controller.disarmAll() }
                    .disabled(controller.armedStates.isEmpty)
                    .accessibilityIdentifier("debug.disarmAll")
            } header: {
                Text("Harness — can wedge or kill the app")
            } footer: {
                Text("Arming a transition pauses the app when it reaches that state. "
                     + "Kill now calls fatalError immediately.")
            }
        }
        .navigationTitle("Debug")
        .accessibilityIdentifier("debug.list")
        .task {
            if buildInfo == nil { buildInfo = await BuildStamp.currentBuildDisplayStringAsync() }
        }
    }
}
```

```swift
// BuildStamp.swift — the bundle enumeration and dyld image walk are file I/O; running
// them inline on the main actor stalls the first paint of this screen. Not the 2026-08-17
// freeze (that was the modal sheet blocking ⌘Q), fixed on principle.
static func currentBuildDisplayStringAsync() async -> String? {
    await Task.detached(priority: .utility) { currentBuildDisplayString() }.value
}
```

`DebugMenuView`'s `#Preview` at `:78-80` keeps its `NavigationStack` wrapper — it is a preview, not a route.

- [ ] **Step 4: Full suite + UI classes + both builds green. Commit.**

```bash
git add Raconte/Capture/Debug/DebugMenuView.swift Raconte/Capture/Debug/BuildStamp.swift \
        RaconteTests/BuildStampAsyncTests.swift RaconteUITests/NavigationUITests.swift project.yml
git commit -m "feat: Debug is a place — build info first, harness fenced below, async build stamp (nav T7)"
```

- [ ] **Step 5: Mutation checks**

1. Swap the two `Section`s back to harness-first → `testDebugPlaceShowsBuildInfoAboveTheHarness` must fail.
2. Make `currentBuildDisplayStringAsync()` return a constant `"x"` → both `BuildStampAsyncTests` must fail. (This is what makes `testAsyncCallDoesNotRequireTheMainActor` non-vacuous.)

**Adversarial reviewer should probe:**
- That the harness still works: arm a state from the new layout, drive the app into it, confirm "waiting — gate hit" and that Kill now aborts. A fenced control that no longer functions is a regression, not a fix — the design says the fencing is *presentational*.
- That `⌘Q` works with the Debug place selected on macOS (the original defect).
- That nothing in `DebugMenuView` is `#if DEBUG`-inconsistent — the file is already wrapped `#if DEBUG` at `:1`, so `Place.debug` must never route here in Release (check the `#else` branch in `detailRoot`).

---

### Task 8: macOS commands and keyboard

Design §7. Three departures are locked in this plan's "Locked decisions": **no global Esc** (⌘[ only), **fixed-place digits only** (no journal digits), and **⌘N presents a root-level alert** (the existing one is unreachable from a menu).

**Files:**
- Create: `Raconte/App/RaconteCommands.swift`
- Modify: `Raconte/App/RaconteApp.swift` (attach `.commands`)
- Modify: `Raconte/App/ContentView.swift` (root-level New Journal alert)
- Modify: `Raconte/App/Place.swift` (`AppRouter.showingNewJournalPrompt` already declared in T1)
- Create: `RaconteTests/AppRouterCommandTests.swift`

- [ ] **Step 1: Write the failing tests**

Menu shortcuts are not unit-testable and XCUITest cannot reliably drive a Mac menu bar from the simulator-only UI scheme. So the **pure half is tested and the binding half is owner-smoked at Gate B** — say so in the code, do not pretend otherwise.

```swift
func testCommandTargetsAreTheRouterFunctions() {
    let router = AppRouter()
    router.select(.allEntries)
    router.detailPath = [.entry("A")]
    router.goBack()
    XCTAssertEqual(router.place, .allEntries)
    XCTAssertTrue(router.detailPath.isEmpty)
}

func testNewJournalRequestIsAFlagTheRootCanSee() {
    let router = AppRouter()
    XCTAssertFalse(router.showingNewJournalPrompt)
    router.requestNewJournal()
    XCTAssertTrue(router.showingNewJournalPrompt,
                  "⌘N must work from any place, so the flag lives on the router, not "
                  + "inside JournalHeaderView's private @State")
}

/// Source scan, comments stripped (repo memory: source-scanning-tests-must-strip-comments).
func testNoGlobalEscapeBinding() throws {
    let source = try strippingComments(String(contentsOf: commandsFileURL))
    XCTAssertFalse(source.contains("cancelAction"),
                   "a menu command wins the responder chain, which would break "
                   + "TranscriptEditorView's Esc-closes contract")
    XCTAssertFalse(source.contains(".escape"))
}
```

Reuse the existing comment-stripping helper (the one `CaptureLabelTests`' source scans use) rather than writing a second.

- [ ] **Step 2: RED** — undefined `requestNewJournal`, and `commandsFileURL` pointing at a file that does not exist. Get behavioural red from Step 5's mutations.

- [ ] **Step 3: Implement**

```swift
#if os(macOS)
struct RaconteCommands: Commands {
    let services: AppServices

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Journal…") { services.router.requestNewJournal() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Capture")     { services.router.select(.capture) }.keyboardShortcut("1")
            Button("All Entries") { services.router.select(.allEntries) }.keyboardShortcut("2")
            Button("Trash")       { services.router.select(.trash) }.keyboardShortcut("3")
            #if DEBUG
            Button("Debug")       { services.router.select(.debug) }.keyboardShortcut("4")
            #endif
            Divider()
            // ⌘[ only. Esc belongs to whatever is focused — TranscriptEditorView binds it
            // to .cancelAction, and a menu command would win that fight unconditionally.
            Button("Back") { services.router.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!services.router.canGoBack)
        }
    }
}
#endif
```

`RaconteApp`:

```swift
WindowGroup { ContentView(services: services) }
#if os(macOS)
.commands { RaconteCommands(services: services) }
#endif
```

The root New Journal alert moves onto `ContentView`'s outermost view (so it presents from any place):

```swift
.alert("New Journal", isPresented: $router.showingNewJournalPrompt) {
    // `.foregroundStyle(Color.primary)` for the same reason JournalHeaderView's copy has
    // it: an alert draws on the system's own light material, but its content is a builder
    // nested inside a view tree that may set .foregroundStyle(.white) — owner smoke
    // 2026-08-15, "white on white, can't read what I type".
    TextField("Journal name", text: $newJournalName)
        .foregroundStyle(Color.primary)
        .accessibilityIdentifier("root.newJournalNameField")
    Button("Create") { Task { await services.capture.createJournal(name: newJournalName) } }
    Button("Cancel", role: .cancel) {}
}
```

`JournalHeaderView`'s own New Journal menu item and alert stay — the capture screen's journal picker is capture configuration, not navigation (design §3), and removing it would take the affordance away on iPhone where there is no menu bar.

- [ ] **Step 4: macOS build + full suite + UI classes green. Commit.**

```bash
git add Raconte/App/RaconteCommands.swift Raconte/App/RaconteApp.swift Raconte/App/ContentView.swift \
        Raconte/App/Place.swift RaconteTests/AppRouterCommandTests.swift project.yml
git commit -m "feat: Mac menu bar — Go menu, cmd-bracket back, cmd-N new journal (nav T8)"
```

- [ ] **Step 5: Mutation checks**

1. Make `AppRouter.goBack()` an empty body → `testCommandTargetsAreTheRouterFunctions` must fail.
2. Add `.keyboardShortcut(.cancelAction)` to the Back button → `testNoGlobalEscapeBinding` must fail. Then add it **inside a `//` comment instead** and confirm the test still passes — this proves the comment stripping works and the scan is not satisfied by prose.

**Adversarial reviewer should probe:**
- Build the Mac app and check by hand: About/Quit/Window/Edit menus present and behaving; ⌘1/⌘2/⌘3 switch places; ⌘[ pops one level in the detail column and is greyed out at the root; ⌘N opens the alert from **All Entries**, not only from Capture.
- That Esc still closes the transcript editor and does nothing anywhere else.
- That `⌘N` from the capture screen does not present two alerts (the root one and `JournalHeaderView`'s).
- That the `#if DEBUG` around ⌘4 matches the `#if DEBUG` around the sidebar Debug row — a shortcut that selects an unlisted place is a way to reach a screen that does not exist in Release.

---

### Task 9: Documentation

**Files:**
- Modify: `docs/overview.md` (navigation section)
- Modify: `docs/plans/2026-08-17-navigation-redesign-design.md` (as-built §11)
- Modify: `CLAUDE.md` (Commands section + conventions)

- [ ] **Step 1: `docs/overview.md`** — a plain-words navigation section beside the existing mental models: the app is a sidebar of *places*; Capture is one of them and is selected at launch; entry list → entry detail → editor are pushes inside the detail column; the phone shows the same graph collapsed to a stack. One mermaid diagram of Place → detail column.

- [ ] **Step 2: As-built §11 in the design doc**, recording every ruling this plan made that the design did not:
  - Journal chips removed from `LibraryView`; the sidebar is the filter.
  - `LibraryDestination` trimmed to `.entry(String)`; `RootDestination` deleted; `library.trashLink` deleted.
  - The **third** hack retirement: `handlePhase`/`handleFinalizeQueue` were view-mounted and would have stopped firing (§5 named only two).
  - Idle timer applied by the model through `IdleTimerControlling`, not by a scene-root `onChange`.
  - No global Esc; ⌘[ only. ⌘1–⌘4 fixed places only; journals get no digits.
  - ⌘N presents a root-level alert because `JournalHeaderView`'s is unreachable from a menu.
  - Whether Task 4's structural fallback was needed, and if so what the phone's IA actually is.
  - macOS `minWidth` 420 → 720.

- [ ] **Step 3: `CLAUDE.md`**
  - Commands section: keep the plain macOS/iOS/UI-test commands (they work on main). Add the note that **when `m4/sync` merges**, macOS tests will require `CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements` and must never use `CODE_SIGNING_ALLOWED=NO`.
  - Add a convention: *"UI tests reach places through `openPlace(app, "sidebar.…")` in `RaconteUITests/UITestNavigation.swift`. Never hard-code a navigation tap in a test class."*
  - Add a convention: *"Nothing that must happen while a capture is running may hang off a view's lifecycle. `CaptureView` is no longer permanently mounted."*
  - Note that both this branch and `m4/sync` rewrite `ContentView.swift` and will conflict; whichever merges second resolves (design §10 accepts this).

- [ ] **Step 4: Commit**

```bash
git add docs/overview.md docs/plans/2026-08-17-navigation-redesign-design.md CLAUDE.md
git commit -m "docs: navigation redesign as-built — places, hack retirements, Mac keyboard (nav T9)"
```

---

## Gate B — after Task 9

**Independent adversarial reviewer**, whole branch:

- Re-run the **full unit suite on the committed tree yourself**. Build iOS and macOS. Run all five UI test classes on a freshly-shut-down iPhone 17 simulator.
- **Probe 1 — source scans, comments stripped:** `preferredColorScheme` appears nowhere in the capture subtree; the five `.environment(\.colorScheme, .dark)` sites survive; `RootDestination`, `capture.libraryDoor`, `capture.libraryButton`, `library.trashLink` appear nowhere; no view carries `.onChange` over `coordinator.phase` / `coordinator.finalizeQueue` / `library.allEntries`.
- **Probe 2 — invariants 5/6/7:** the editor, Mark voices and revision history are still `navigationDestination` **pushes**, not sheets; `EntryDetailView` still holds its own `item` copy and still builds its three sub-models once in `init`. Diff-check, then confirm behaviourally: open the editor, type, press system Back, and confirm the edit survives (`TranscriptEditorUITests` covers this — confirm it was not weakened).
- **Probe 3 — the whole point:** start a recording, navigate to All Entries, open an entry, open its transcript editor, come all the way back. The recording must still be running and must still commit.
- **Probe 4 — retain cycles:** `LibraryScreenModel.rescanObserver`, and the coordinator observation's two `[weak self]` captures.
- **Probe 5 — regression on the two #62 pins:** `CaptureScreenModelTests` `:123/:136/:147` and `CaptureUITests:312` must be byte-identical to main and green.
- **Probe 6 — deleted-journal place:** create a journal, select it in the sidebar, delete it (or make `journals.json` unreadable), and confirm the app falls back to Capture rather than showing a dead list.

**Owner smoke (self-contained; restate everything):**

1. **Mac keyboard.** Open `~/Desktop/Raconte-nav.app`. Press **⌘2** — the All Entries list. **⌘3** — Trash. **⌘1** — the capture screen. Click an entry from All Entries to open it, then press **⌘[** — you go back to the list. Press **⌘[** again at the list — nothing happens (correct). **Pass:** all five behave as described.
2. **⌘N from a browse place.** Press **⌘2** (All Entries), then **⌘N**. **Pass:** a "New Journal" box appears and you can read what you type. Type a name, click Create, and the new journal appears as a sidebar row.
3. **Esc still belongs to the editor.** Open any entry with a transcript, tap **Edit transcript**, type a word, press **Esc**. **Pass:** the editor closes and your word is saved. Then, on the entry list, press **Esc** — **Pass:** nothing happens.
4. **Debug place.** Select **Debug** in the sidebar. **Pass:** the build date and identity are the **first** thing on screen; the transition toggles and "Kill now" are below, under a heading that says the harness can wedge or kill the app. Press **⌘Q** — the app quits.
5. **iPhone, the full walk.** Install and open. **Pass:** the capture screen. Record ten seconds; stop; the "Saved" receipt appears; from the receipt reveal the sidebar and tap **All Entries** — your entry is there; tap it, read it, come back, tap **Capture** — the receipt is still there (it stays until you dismiss it) and **Record another** returns you to the landing screen.
6. **iPad sanity** (if convenient): the sidebar is visible beside the capture screen and rotating the device does not lose your place.

- PR for Nico to merge (auto-mode cannot `gh pr merge`). PR body must reference issues **without** a close-verb before the number.

---

## Self-review notes (done at write time)

- **Spec coverage.** design §1→T4/T5/T7 (every named defect); §2→T4 + T4 Step 5's collapse verification; §3→T1/T5/T6 (map of places, live indicator, receipt no longer hides exits); §4→T1/T4 (`Place`, path binding, `RootDestination`/`LibraryDestination` supersession, `entry.unavailable` carried verbatim); §5.1→T3; §5.2→T2; §5 "recording survives navigation"→T6; §6→T7; §7→T8; §8→copied verbatim into T2/T4/T5 briefs and into Gate B probes 1-2; §9→each task's test block; §10 out-of-scope respected (capture internals untouched beyond one `capture.elapsed` identifier, journal management left in the capture menu, no state restoration, no `openWindow`, `ContentView` conflict with `m4/sync` accepted and recorded in T9).
- **Deliberate deviation from the skill template:** steps are task-level TDD requirements rather than 2-minute micro-steps. This repo's seven shipped SDD loops all ran from this shape and per-task implementers extract their own red/green cycles from the named tests.
- **Type-consistency pass:** `Place` defined T1, consumed T4/T5/T6/T8; `PlaceRow`/`SidebarModel` defined T1, consumed T5; `AppRouter` defined T1, consumed T4/T5/T8 (`showingNewJournalPrompt` declared in T1 so T8 adds only `requestNewJournal()`); `AppServices` defined T4, consumed T5/T6/T8; `IdleTimerControlling` defined T2, consumed nowhere else; `LibraryRescanObserver` defined T3, consumed nowhere else; `CaptureSidebarRow` defined T6, consumed T6 only; `openPlace`/`openCapture` defined T5, consumed T5/T6/T7.
- **Known residual risk, stated rather than hidden:** menu-bar shortcuts have no automated pin on either platform (macOS UI testing needs interactive automation permission; the UI scheme is simulator-only). Task 8 tests the pure router targets and source-scans the Esc ruling; the bindings themselves rest on Gate B owner smoke step 1.
