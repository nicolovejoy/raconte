# Swipe-to-trash linger (2026-10-06) Implementation Plan — no confirmation, a 2 s undo row instead (#83, absorbs #27)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One PR from `main`: swiping a library row to Trash writes the trash immediately and
leaves the row in place for two seconds in a "Deleting this entry…" state; a tap in that window
restores it; when the window ends the row leaves the list with a success haptic on iOS. The
"Move this entry to the trash?" confirmation dialog is gone, and with it #27's blink.

**Architecture:** A pure `TrashLinger` (new `Raconte/Library/TrashLinger.swift`) holds the
set of lingering capture ids with the instant each was armed and a window length, so arm /
undo / expiry pin with an injected clock. `LibraryScreenModel` owns the integration — nothing
load-bearing on view lifecycle (CLAUDE.md rule): `swipeTrash` writes the tombstone through the
existing `trashEntryCore`, arms the linger, rescans, and starts a model-held `Task` that
sleeps the window and then completes it; `undoTrash` restores through `restoreEntryCore`.
`rescan()` keeps a lingering row in `items` (it is already trashed on disk) so the list holds
its place. `LibraryView` renders that row as a tap-to-undo button, routes swipe and context
menu to `swipeTrash`, and fires `.sensoryFeedback(.success, trigger:)` on completion.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, XCTest. Xcode project is generated:
run `xcodegen generate` after adding any file. Local macOS test recipe (CLAUDE.md "Test
(macOS)"); the UI suite is CI-only on the laptop (CoreSimulator out of date, #189).

**Spec:** GitHub issue #83 (owner-ruled) plus the four rulings of 2026-10-06, restated here:
(1) write first — the trash write lands immediately and the window is a restore window;
(2) scope is the row's swipe action and its Mac context menu only — the entry-detail trash
confirmation and the bulk-select dialog are untouched; (3) completion feedback is
`.sensoryFeedback(.success)` (no macOS sound); (4) tests are a pure `TrashLinger` with an
injected clock, model tests over the real stores, and one UI test.

## Global Constraints

- Nothing that must happen while the window runs hangs off a view's lifecycle: the timer and
  the state live on `LibraryScreenModel`.
- Paper screens take a `TypeRole`, never a bare text style or a size literal
  (`TypeScaleTests.testPaperScreensCarryNoBareTextStyleOrSizeLiteral` covers `LibraryView`).
- Prefer semantic colors (`InkTone`) over `Color(white:)` literals.
- New source or test file → `xcodegen generate` before building, or the file is invisible and
  the suite runs green at the OLD count.
- Straggler grep for every deleted identifier/symbol over all three targets:
  `Raconte RaconteTests RaconteUITests`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- The window is **2 seconds** in production: `TrashLinger.window` default `2`, and
  `LibraryScreenModel.init(trashLingerWindow:)` default `.seconds(2)`.
- Identifiers removed: `library.row.confirmTrash`. Identifiers added: `library.row.lingering`.
  `library.row.trashSwipe` keeps its name.

## Review Focus

1. A second swipe on a row that is already lingering must be a no-op — not a second
   tombstone write, not a second timer that completes the first one early. (Task 1 pins
   `arm` returning false; Task 2 pins `swipeTrash` returning true with no second write.)
2. Undo after the window has already completed must do nothing and return false — the entry
   is in Trash, the Trash view is the route back. (Task 1 `undo` after `expire`; Task 2
   `undoTrash` after completion.)
3. A store failure on the trash write must leave no linger behind: the row stays ordinary,
   `swipeTrash` returns false, the view shows the existing `trashFailed` alert. (Task 2.)
4. A `rescan()` triggered by something else during the window (a journal switch, a sync
   landing) must keep the lingering row in `items` — the row must not vanish early and then
   reappear in Trash. (Task 2: a second `rescan()` mid-window.)
5. Switching journal scope mid-window: a lingering row from another journal must not leak
   into the scoped list. (Task 2: lingering rows are filtered by the same scope as `items`.)

---

### Task 1: `TrashLinger` — pure arm / undo / expire with an injected clock

**Files:**
- Create: `Raconte/Library/TrashLinger.swift`
- Test: `RaconteTests/TrashLingerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct TrashLinger: Equatable {
      init(window: TimeInterval = 2)
      var isEmpty: Bool
      func isLingering(_ captureID: String) -> Bool
      mutating func arm(_ captureID: String, now: Date) -> Bool      // false = already lingering
      mutating func undo(_ captureID: String) -> Bool                // false = not lingering
      mutating func expire(now: Date) -> [String]                    // ids whose window has passed; removed
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Raconte

/// #83: the two-second undo window behind swipe-to-trash, as pure state. The model owns
/// the clock and the timer; this pins what arm / undo / expiry mean.
final class TrashLingerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let a = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private let b = "01BBBBBBBBBBBBBBBBBBBBBBBB"

    func testArmMakesTheEntryLingerAndASecondArmIsANoOp() {
        var linger = TrashLinger(window: 2)
        XCTAssertFalse(linger.isLingering(a))
        XCTAssertTrue(linger.arm(a, now: t0))
        XCTAssertTrue(linger.isLingering(a))
        XCTAssertFalse(linger.arm(a, now: t0.addingTimeInterval(1)),
                       "a second swipe during the window must not re-arm (and must not restart the clock)")
    }

    func testUndoDuringTheWindowClearsItAndNothingExpiresLater() {
        var linger = TrashLinger(window: 2)
        _ = linger.arm(a, now: t0)
        XCTAssertTrue(linger.undo(a))
        XCTAssertFalse(linger.isLingering(a))
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(10)), [])
    }

    func testExpireReturnsOnlyEntriesWhoseWindowHasPassed() {
        var linger = TrashLinger(window: 2)
        _ = linger.arm(a, now: t0)
        _ = linger.arm(b, now: t0.addingTimeInterval(1.5))
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(1.999)), [],
                       "nothing has reached its window yet")
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(2)), [a],
                       "the window is inclusive at exactly 2 s")
        XCTAssertTrue(linger.isLingering(b))
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(3.5)), [b])
        XCTAssertTrue(linger.isEmpty)
    }

    func testUndoAfterExpiryIsFalse() {
        var linger = TrashLinger(window: 2)
        _ = linger.arm(a, now: t0)
        _ = linger.expire(now: t0.addingTimeInterval(2))
        XCTAssertFalse(linger.undo(a), "once the window has closed the Trash view is the only way back")
    }

    func testASecondArmDoesNotRestartTheClock() {
        var linger = TrashLinger(window: 2)
        _ = linger.arm(a, now: t0)
        _ = linger.arm(a, now: t0.addingTimeInterval(1.9))
        XCTAssertEqual(linger.expire(now: t0.addingTimeInterval(2)), [a],
                       "the original arm time governs; the ignored re-arm must not extend the window")
    }

    func testUndoOfAnUnknownIDIsFalse() {
        var linger = TrashLinger(window: 2)
        XCTAssertFalse(linger.undo(a))
    }
}
```

- [ ] **Step 2: Run to verify it fails for the right reason**

```
xcodegen generate
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' -derivedDataPath /tmp/raconte-83 CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements -only-testing:RaconteTests/TrashLingerTests test 2>&1 | grep -E "cannot find 'TrashLinger'|TEST (SUCCEEDED|FAILED)"
```
Expected: `error: cannot find 'TrashLinger' in scope` lines, `TEST FAILED`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The undo window behind swipe-to-trash (#83). The trash write has ALREADY landed when a
/// capture id is armed here — this is a restore window, not a deferred delete — so a crash
/// mid-window leaves the entry in Trash, recoverable, never silently lost. Pure: the model
/// owns the clock and the timer, so the window pins with an injected `now`.
struct TrashLinger: Equatable {
    let window: TimeInterval
    private var armedAt: [String: Date] = [:]

    init(window: TimeInterval = 2) {
        self.window = window
    }

    var isEmpty: Bool { armedAt.isEmpty }

    func isLingering(_ captureID: String) -> Bool { armedAt[captureID] != nil }

    /// False when already lingering: a second swipe neither re-arms nor restarts the clock.
    mutating func arm(_ captureID: String, now: Date) -> Bool {
        guard armedAt[captureID] == nil else { return false }
        armedAt[captureID] = now
        return true
    }

    /// False when nothing was lingering — the window closed, or it never opened.
    mutating func undo(_ captureID: String) -> Bool {
        armedAt.removeValue(forKey: captureID) != nil
    }

    /// Every id whose window has passed (inclusive at exactly `window`), removed.
    mutating func expire(now: Date) -> [String] {
        let done = armedAt.filter { now.timeIntervalSince($0.value) >= window }.map(\.key).sorted()
        for id in done { armedAt[id] = nil }
        return done
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Same command as Step 2. Expected: `Executed 6 tests, with 0 failures`, `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```
git add Raconte/Library/TrashLinger.swift RaconteTests/TrashLingerTests.swift
git commit -m "feat(#83): TrashLinger — the pure undo window behind swipe-to-trash"
```

---

### Task 2: `LibraryScreenModel.swipeTrash` / `undoTrash` — write first, linger, expire on the model

**Files:**
- Modify: `Raconte/Library/LibraryScreenModel.swift` (init at ~178; `rescan()` at ~268, the
  `items =` line at ~302; the trash/restore block at ~881–920)
- Test: `RaconteTests/LibraryTrashTests.swift` (append to the existing class; fixture
  `writeCapture(_:capturedAt:)`, `model()`, `metadata(_:)` already exist there)

**Interfaces:**
- Consumes: `TrashLinger` from Task 1; existing `trashEntryCore`, `restoreEntryCore`, `rescan()`.
- Produces (on `LibraryScreenModel`):
  ```swift
  init(capturesRoot: URL, journalsContainerRoot: URL? = nil, trashLingerWindow: Duration = .seconds(2))
  func isLingering(_ captureID: String) -> Bool
  private(set) var trashCompletions: Int          // +1 per completed linger — the haptic trigger
  @discardableResult func swipeTrash(_ captureID: String, now: Date = Date()) async -> Bool
  @discardableResult func undoTrash(_ captureID: String) async -> Bool
  ```

- [ ] **Step 1: Write the failing tests** (append inside `LibraryTrashTests`, after the
  `// MARK: - Trash / restore` tests)

```swift
    // MARK: - Swipe-to-trash linger (#83)

    private func lingerModel(windowMilliseconds: Int = 50) -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot,
                           trashLingerWindow: .milliseconds(windowMilliseconds))
    }

    /// Polls the main actor without blocking it; a model-held timer needs the actor free.
    private func waitUntil(_ timeout: TimeInterval = 3, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testSwipeTrashWritesTheTombstoneAndKeepsTheRowInPlace() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = lingerModel(windowMilliseconds: 60_000)   // a window this test never reaches
        await model.rescan()

        XCTAssertTrue(await model.swipeTrash(idA, now: Date(timeIntervalSince1970: 5_000)))

        XCTAssertNotNil(try metadata(idA).trashedAt, "write first: the tombstone is on disk at once")
        XCTAssertEqual(model.items.map(\.captureID), [idB, idA],
                       "the row holds its place in the list for the window")
        XCTAssertTrue(model.isLingering(idA))
        XCTAssertEqual(model.trashed.map(\.captureID), [idA],
                       "it is in Trash already — a crash mid-window loses nothing")
        XCTAssertEqual(model.trashCompletions, 0)
    }

    func testUndoDuringTheWindowRestoresAndTheRowIsOrdinaryAgain() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = lingerModel(windowMilliseconds: 60_000)
        await model.rescan()
        await model.swipeTrash(idA)

        XCTAssertTrue(await model.undoTrash(idA))

        XCTAssertNil(try metadata(idA).trashedAt)
        XCTAssertFalse(model.isLingering(idA))
        XCTAssertEqual(model.items.map(\.captureID), [idA])
        XCTAssertTrue(model.trashed.isEmpty)
        XCTAssertEqual(model.trashCompletions, 0, "an undone trash never completes")
    }

    func testTheWindowEndingRemovesTheRowAndCountsACompletion() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = lingerModel(windowMilliseconds: 50)
        await model.rescan()
        await model.swipeTrash(idA)
        XCTAssertEqual(model.items.count, 2)

        await waitUntil(3, "the lingering row never left the list") { model.items.count == 1 }

        XCTAssertEqual(model.items.map(\.captureID), [idB])
        XCTAssertFalse(model.isLingering(idA))
        XCTAssertEqual(model.trashCompletions, 1)
        XCTAssertEqual(model.trashed.map(\.captureID), [idA])
        XCTAssertFalse(await model.undoTrash(idA), "after the window the Trash view is the route back")
        XCTAssertNotNil(try metadata(idA).trashedAt, "a late undo must not restore")
    }

    func testASecondSwipeDuringTheWindowIsANoOp() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = lingerModel(windowMilliseconds: 60_000)
        await model.rescan()
        await model.swipeTrash(idA, now: Date(timeIntervalSince1970: 5_000))
        let first = try metadata(idA).trashedAt

        XCTAssertTrue(await model.swipeTrash(idA, now: Date(timeIntervalSince1970: 9_000)),
                      "reported as handled — there is nothing to alert about")

        XCTAssertEqual(try metadata(idA).trashedAt, first, "no second tombstone write")
        XCTAssertTrue(model.isLingering(idA))
    }

    func testAFailedTrashWriteLeavesNoLinger() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = lingerModel(windowMilliseconds: 60_000)
        await model.rescan()
        try Data("not json".utf8).write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        XCTAssertFalse(await model.swipeTrash(idA))

        XCTAssertFalse(model.isLingering(idA), "a write that did not land must not arm an undo window")
        XCTAssertEqual(model.trashCompletions, 0)
    }

    func testAnUnrelatedRescanMidWindowKeepsTheLingeringRow() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = lingerModel(windowMilliseconds: 60_000)
        await model.rescan()
        await model.swipeTrash(idA)

        await model.rescan()   // a journal switch, a sync landing — anything else that rescans

        XCTAssertEqual(model.items.map(\.captureID), [idB, idA],
                       "the row must not vanish early and then reappear only in Trash")
    }

    func testALingeringRowFromAnotherJournalDoesNotLeakIntoAScopedList() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        try EntryMetadataStore.write(EntryMetadata(journalID: "J1"),
                                     url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idB)))
        let model = lingerModel(windowMilliseconds: 60_000)
        await model.rescan()
        await model.swipeTrash(idA)   // idA is unfiled

        model.journalScope = .journal("J1")
        await model.rescan()

        XCTAssertEqual(model.items.map(\.captureID), [idB],
                       "a lingering row obeys the same journal scope as every other row")
    }
```

(`JournalScope` is `.all` / `.journal(String)` / `.unfiled`, `Raconte/Library/EntryListItem.swift:302`;
`EntryListItem.sortedByEffectiveDate` is descending, so `[idB, idA]` is the order for
capturedAt 2 000 then 1 000.)

- [ ] **Step 2: Run to verify it fails for the right reason**

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' -derivedDataPath /tmp/raconte-83 CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements -only-testing:RaconteTests/LibraryTrashTests test 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)" | sort -u
```
Expected: `extra argument 'trashLingerWindow' in call`, `has no member 'swipeTrash'`, `TEST FAILED`.

- [ ] **Step 3: Implement on `LibraryScreenModel`**

Stored properties (next to `private(set) var trashed`):

```swift
    /// Swipe-to-trash's undo window (#83). An id here is ALREADY trashed on disk — the row
    /// stays in `items` for the window so a tap can restore it; `rescan()` is what keeps it
    /// there. The timer that closes the window is `lingerTasks`, held on this model and
    /// never on a view, per the capture-screen rule.
    private var trashLinger: TrashLinger
    private var lingerTasks: [String: Task<Void, Never>] = [:]
    /// Bumped once per window that closes with the entry still trashed — the view's haptic
    /// trigger. Never bumped by an undo.
    private(set) var trashCompletions = 0
    private let trashLingerWindow: Duration
```

Init — add the parameter and the two assignments (keep every existing line):

```swift
    init(capturesRoot: URL, journalsContainerRoot: URL? = nil,
         trashLingerWindow: Duration = .seconds(2)) {
        self.trashLingerWindow = trashLingerWindow
        self.trashLinger = TrashLinger(window: Self.seconds(trashLingerWindow))
        // …existing body unchanged…
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
```

`rescan()` — replace the single `items =` line:

```swift
        // A lingering swipe-to-trash row (#83) is already trashed on disk but holds its
        // place in the list for the undo window — so filter by scope with trash INCLUDED,
        // then drop the trashed rows that are not lingering. Same sort as before.
        items = EntryListFilter(journal: scope, trash: .all).apply(to: result.items)
            .filter { !$0.isTrashed || trashLinger.isLingering($0.captureID) }
```

Public API, after `restoreEntry`:

```swift
    // MARK: - Swipe-to-trash linger (#83)

    func isLingering(_ captureID: String) -> Bool { trashLinger.isLingering(captureID) }

    /// Write first: the tombstone lands now, then the row lingers for the window with a
    /// tap-to-undo. A crash mid-window leaves the entry in Trash, recoverable — never a
    /// silent loss, which a deferred write would risk. Returns `false` only when the write
    /// did not land (same contract as `trashEntry`); then nothing is armed. A swipe on a
    /// row that is already lingering is a no-op and returns `true`.
    @discardableResult
    func swipeTrash(_ captureID: String, now: Date = Date()) async -> Bool {
        guard !trashLinger.isLingering(captureID) else { return true }
        guard await trashEntryCore(captureID, now: now) else { return false }
        _ = trashLinger.arm(captureID, now: now)
        await rescan()
        lingerTasks[captureID]?.cancel()
        lingerTasks[captureID] = Task { [weak self, window = trashLingerWindow] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.closeLingerWindows()
        }
        return true
    }

    /// The tap during the window. Clears the tombstone (the whole restore — nothing ever
    /// moved) and the linger. `false` when the window has already closed, or the write
    /// failed; the Trash view is the route back then.
    @discardableResult
    func undoTrash(_ captureID: String) async -> Bool {
        guard trashLinger.undo(captureID) else { return false }
        lingerTasks[captureID]?.cancel()
        lingerTasks[captureID] = nil
        let restored = await restoreEntryCore(captureID)
        await rescan()
        return restored
    }

    /// Timer callback: every window that has passed closes, its row leaves the list on
    /// the rescan, and each one counts as a completion for the haptic.
    private func closeLingerWindows(now: Date = Date()) async {
        let done = trashLinger.expire(now: now)
        guard !done.isEmpty else { return }
        for id in done { lingerTasks[id] = nil }
        trashCompletions += done.count
        await rescan()
    }
```

`Task.sleep(for:)` on a `Duration` is the right overload; `[weak self]` because the model
can be released mid-window. The class is `@MainActor @Observable`, so the unstructured
`Task {}` inherits main-actor isolation and `closeLingerWindows` needs no hop.

- [ ] **Step 4: Run the model tests**

Same command as Step 2 plus `-only-testing:RaconteTests/LibraryScreenModelTests -only-testing:RaconteTests/BulkOperationsTests`.
Expected: all green, `LibraryTrashTests` executed count up by **7**.

- [ ] **Step 5: Commit**

```
git add Raconte/Library/LibraryScreenModel.swift RaconteTests/LibraryTrashTests.swift
git commit -m "feat(#83): LibraryScreenModel.swipeTrash/undoTrash — write first, linger on the model, expire by timer"
```

---

### Task 3: `LibraryView` — drop the dialog, lingering row, haptic; straggler grep

**Files:**
- Modify: `Raconte/Library/UI/LibraryView.swift` (`@State` block ~20–55; `withSingleEntryDialogs`
  ~153–172; `navigableRow` ~482–527)

**Interfaces:**
- Consumes: `model.swipeTrash(_:)`, `model.undoTrash(_:)`, `model.isLingering(_:)`,
  `model.trashCompletions` from Task 2.
- Produces: accessibility identifier `library.row.lingering` (a button). Removes
  `library.row.confirmTrash` and the `pendingTrashCaptureID` state.

- [ ] **Step 1: Remove the confirmation**

In `withSingleEntryDialogs`, delete the whole
`.confirmationDialog("Move this entry to the trash?", …)` modifier (its `isPresented`
binding, the `Move to Trash` button with `library.row.confirmTrash`, the Cancel button, and
the `message:` closure). Leave the "Move to journal" dialog and everything else. Delete the
`@State private var pendingTrashCaptureID: String?` declaration and fix its doc comment so it
describes only the move. Keep `trashFailed` and its alert — a failed write still alerts.

- [ ] **Step 2: Route the swipe and the context menu to `swipeTrash`**

In `navigableRow`, replace the trash swipe button:

```swift
            // No `role: .destructive` (#27): that role makes SwiftUI remove the row
            // optimistically, and this row must STAY for the undo window (#83).
            Button {
                Task { if !(await model.swipeTrash(item.captureID)) { trashFailed = true } }
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .tint(.red)
            .accessibilityIdentifier("library.row.trashSwipe")
```

and the context menu's "Move to Trash" button body:

```swift
            Button(role: .destructive) {
                Task { if !(await model.swipeTrash(item.captureID)) { trashFailed = true } }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
```

Update the comment above `.swipeActions` — it still says the handlers reuse `trashEntry`
"exactly as the detail screen does"; say they go through `swipeTrash`, the lingering path,
and that the detail screen keeps its confirmation (ruling 2).

- [ ] **Step 3: Render the lingering row**

In the list's `ForEach(monthGroup.items) { item in … }`, add a first branch:

```swift
                                if model.isLingering(item.captureID) {
                                    lingeringRow(item)
                                } else if selection.isActive {
```

and add the row next to `navigableRow`:

```swift
    /// The two-second undo window after a swipe-to-trash (#83): the entry is already in
    /// Trash; this row holds its place and a tap brings it back. A `Button`, not a
    /// `NavigationLink` — there is nothing to navigate to, and no swipe actions: a second
    /// swipe is meaningless here.
    private func lingeringRow(_ item: EntryListItem) -> some View {
        Button {
            Task { await model.undoTrash(item.captureID) }
        } label: {
            HStack {
                Label("Deleting this entry…", systemImage: "trash")
                Spacer()
                Text("Tap to undo")
            }
            .font(TypeRole.label.font)
            .foregroundStyle(InkTone.inkSecondary.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.row.lingering")
        .listRowBackground(InkTone.paper.color)
    }
```

- [ ] **Step 4: Haptic on completion**

On the screen's outer view (where `withSingleEntryDialogs` is applied, i.e. above the `List`,
never on a `Section`), add:

```swift
        .sensoryFeedback(.success, trigger: model.trashCompletions)
```

`.sensoryFeedback` is iOS 17 / macOS 14; on macOS it is inert, which is ruling 3 (no sound).

- [ ] **Step 5: Straggler grep and both compiles**

```
grep -rn "pendingTrashCaptureID\|library.row.confirmTrash\|Move this entry to the trash" Raconte RaconteTests RaconteUITests
```
Expected: zero present-tense hits (a comment that says the dialog is GONE is fine; one that
says it exists is not).

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' -derivedDataPath /tmp/raconte-83 CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements -only-testing:RaconteTests/TypeScaleTests -only-testing:RaconteTests/LibraryTrashTests test 2>&1 | grep -E "error:|Executed|TEST (SUCCEEDED|FAILED)" | sort -u
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' -derivedDataPath /tmp/raconte-83 CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "^.*error:|BUILD (SUCCEEDED|FAILED)" | grep -v "CoreSimulator\|DVTPlugIn" | sort -u
```
Expected: `TEST SUCCEEDED` (TypeScale's paper-screen scan still passes — `TypeRole.label`,
no bare style), `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```
git add Raconte/Library/UI/LibraryView.swift
git commit -m "feat(#83): swipe-to-trash lingers two seconds with tap-to-undo; the confirmation dialog is gone (fixes #27's blink)"
```

---

### Task 4: UI test — swipe, undo, then let the window close

**Files:**
- Create: `RaconteUITests/LibraryTrashLingerUITests.swift`

**Interfaces:**
- Consumes: identifiers `library.entryLink`, `library.row.trashSwipe`, `library.row.lingering`;
  `openPlace(app, "sidebar.allEntries")` from `RaconteUITests/UITestNavigation.swift`; the
  three-entry seed `RACONTE_UITEST_SEED_MARKER_ENTRY` (as `BulkSelectUITests` uses it).

- [ ] **Step 1: Write the test**

```swift
import XCTest

/// #83: swipe-to-trash has no confirmation; the row lingers for two seconds as a
/// tap-to-undo, then leaves. One test, both halves: an undo first (the protection the
/// prompt used to give), then a swipe that is allowed to complete. Seeded by the marker
/// seed's three entries, like `BulkSelectUITests`.
final class LibraryTrashLingerUITests: XCTestCase {

    private var testID = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        testID = UUID().uuidString
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = testID
        app.launchEnvironment["RACONTE_UITEST_SEED_MARKER_ENTRY"] = "1"
        app.launch()
        return app
    }

    private func elements(_ app: XCUIApplication, _ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    /// Polls, like `BulkSelectUITests`' helper of the same name.
    private func waitUntil(_ timeout: TimeInterval = 20, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    private func swipeTopRowToTrash(_ app: XCUIApplication) {
        let rows = elements(app, "library.entryLink")
        rows.element(boundBy: 0).swipeLeft()
        let trash = app.buttons["library.row.trashSwipe"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "swipe revealed no Trash action")
        trash.tap()
    }

    func testSwipeLingersWithUndoThenCompletesWithoutAConfirmation() {
        let app = launchApp()
        openPlace(app, "sidebar.allEntries")

        let rows = elements(app, "library.entryLink")
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 20),
                      "the marker seed provides three entries; fewer means the seed changed")

        // Half 1: swipe, see the lingering row, tap it — the entry comes back.
        swipeTopRowToTrash(app)
        let lingering = elements(app, "library.row.lingering").firstMatch
        XCTAssertTrue(lingering.waitForExistence(timeout: 5), "no lingering row after the swipe")
        XCTAssertFalse(app.buttons["library.row.confirmTrash"].exists,
                       "the confirmation dialog is gone (#83)")
        XCTAssertEqual(rows.count, 2, "the lingering row replaces the link; the other two stay")
        lingering.tap()
        waitUntil(10, "undo did not bring the row back") { rows.count == 3 && !lingering.exists }

        // Half 2: swipe again and let the two-second window close.
        swipeTopRowToTrash(app)
        XCTAssertTrue(elements(app, "library.row.lingering").firstMatch.waitForExistence(timeout: 5))
        waitUntil(10, "the lingering row never left the list") {
            rows.count == 2 && !elements(app, "library.row.lingering").firstMatch.exists
        }
    }
}
```

- [ ] **Step 2: Register the file and prove it is compiled**

```
xcodegen generate
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | grep -E "LibraryTrashLingerUITests|error:|BUILD (SUCCEEDED|FAILED)" | sort -u | head
```
Expected: `BUILD SUCCEEDED`, and the file name appears in the compile lines. (The laptop
cannot RUN the UI suite — CoreSimulator is out of date, #189 — so CI judges: expected UI
count **67 → 68**. On a machine with a working simulator, run
`xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/LibraryTrashLingerUITests test`.)

- [ ] **Step 3: Commit**

```
git add RaconteUITests/LibraryTrashLingerUITests.swift
git commit -m "test(#83): UI — swipe lingers with undo, then completes with no confirmation"
```

---

### Task 5: PR

- [ ] **Step 1: Push and open the PR** — base `main`, title
  `feat(#83): swipe-to-trash lingers two seconds with tap-to-undo; no confirmation`, body
  stating: the four rulings; write-first and why (crash-safe); what moved out of the view
  and onto the model; identifiers removed/added; expected counts against main's latest CI
  (read `Executed N tests` from the latest main run — do not copy a number from a commit
  message); that #27 is already closed into #83; and the owner smoke:

  > iPhone, build N (About → App → Build): All Entries → swipe a row left → Trash. Pass: no
  > "Move this entry to the trash?" prompt; the row reads "Deleting this entry… Tap to undo"
  > for ~2 s; tapping it restores the row; letting it run removes the row with a light
  > success tap. Mac: right-click a row → Move to Trash → same lingering row, click to undo,
  > no sound.

  The close keyword: `Closes #83` only — #27 is already closed, and this plan ships nothing
  partial, so the verb is intended.
