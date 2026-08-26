# #101 Entry Paging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Next/previous-entry paging on the entry detail screen — toolbar chevrons everywhere, swipe on iOS, ⌥⌘↑/⌥⌘↓ menu commands on macOS — following the order of the list the entry was opened from (#101).

**Architecture:** A page turn replaces the top `LibraryDestination.entry` element of `AppRouter.detailPath` (never an in-place state swap), so the departing screen's on-disappear commit contracts fire exactly as they do for a sidebar pop. A pure `EntryPager` computes neighbors from the live `LibraryScreenModel.items` order and gates paging on the current place having a journal scope. The destination builder pins view identity with `.id(captureID)` — without it a page turn can reuse stale `@State`.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency, XcodeGen project, XCTest + XCUITest.

**Spec:** `docs/plans/2026-08-26-101-entry-paging-design.md` — read it first; every decision below is argued there.

## Global Constraints

- Xcode project is GENERATED: run `xcodegen generate` after adding files; `*.xcodeproj` is never edited by hand.
- Unit test command (macOS, sandbox REQUIRED — never `CODE_SIGNING_ALLOWED=NO`), run FOREGROUND and wait:
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test`
- iOS compile check:
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- UI tests: one class per invocation, FOREGROUND, never background an xcodebuild run (the whole suite exceeds the environment's hard 10-minute cap; single classes fit):
  `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/<Class> test`
- UI tests navigate ONLY via `openPlace(app, "sidebar.…")` (RaconteUITests/UITestNavigation.swift) — never hard-coded taps. New detail-screen identifiers use the existing `detail.*` prefix.
- Exhaustive switches over `Place`/`LibraryDestination` never gain a `default:`.
- The swipe gesture is NOT UI-tested (repo memory: simulator gestures fire where device gestures don't, and vice versa — a sim test would pass vacuously). Buttons are the tested path; the gesture ships behind the same `page(_:)` function and is owner-smoked on device.
- Ordering semantics everywhere: `orderedIDs` is newest-first (`model.items` order); **previous = index-1 (newer), next = index+1 (older)**.
- Commit messages: conventional-commits subject, then a blank line, then:
  `Co-Authored-By: Claude <noreply@anthropic.com>`

---

### Task 1: EntryPager pure core + AppRouter.replaceTopEntry

**Files:**
- Create: `Raconte/Library/EntryPager.swift`
- Modify: `Raconte/App/Place.swift` (add `replaceTopEntry` to `AppRouter`, near `goBack()`)
- Test: `RaconteTests/EntryPagerTests.swift` (new)

**Interfaces:**
- Consumes: existing `Place`, `LibraryDestination` (cases `.entry(String)` / `.journalEditor(String)`), `PlaceRouting.journalScope(for:)`, `AppRouter.detailPath: [LibraryDestination]`.
- Produces: `PagingDirection` (`.previous`/`.next`), `EntryPager.neighborID(of:in:direction:) -> String?`, `EntryPager.pagingTarget(place:detailPath:orderedIDs:direction:) -> String?`, `AppRouter.replaceTopEntry(with: String)` — Tasks 2 and 3 consume all four.

- [ ] **Step 1: Write the failing tests**

`RaconteTests/EntryPagerTests.swift`:

```swift
import XCTest
@testable import Raconte

/// #101: the paging pure core. `orderedIDs` is `LibraryScreenModel.items` order —
/// newest FIRST — so previous = index-1 (toward newer) and next = index+1 (toward
/// older). These tests pin that direction mapping; getting it backwards inverts
/// every control in the UI.
@MainActor
final class EntryPagerTests: XCTestCase {

    private let ids = ["newest", "middle", "oldest"]

    // MARK: neighborID

    func testMiddleEntryHasBothNeighborsWithTheLockedDirectionMapping() {
        XCTAssertEqual(EntryPager.neighborID(of: "middle", in: ids, direction: .previous),
                       "newest", "previous must move toward the top (newer) of the list")
        XCTAssertEqual(EntryPager.neighborID(of: "middle", in: ids, direction: .next),
                       "oldest", "next must move toward the bottom (older) of the list")
    }

    func testFirstEntryHasNoPreviousAndLastHasNoNext() {
        XCTAssertNil(EntryPager.neighborID(of: "newest", in: ids, direction: .previous))
        XCTAssertEqual(EntryPager.neighborID(of: "newest", in: ids, direction: .next), "middle")
        XCTAssertNil(EntryPager.neighborID(of: "oldest", in: ids, direction: .next))
        XCTAssertEqual(EntryPager.neighborID(of: "oldest", in: ids, direction: .previous), "middle")
    }

    func testAbsentIDAndEmptyListProduceNoNeighbor() {
        XCTAssertNil(EntryPager.neighborID(of: "gone", in: ids, direction: .next),
                     "an entry that left the list's scope pages nowhere — both ends disable")
        XCTAssertNil(EntryPager.neighborID(of: "anything", in: [], direction: .previous))
    }

    // MARK: pagingTarget (the whole gate in one place)

    func testPagingTargetRequiresAScopedPlaceAndAnEntryOnTop() {
        let path: [LibraryDestination] = [.entry("middle")]
        XCTAssertEqual(EntryPager.pagingTarget(place: .allEntries, detailPath: path,
                                               orderedIDs: ids, direction: .next), "oldest")
        XCTAssertEqual(EntryPager.pagingTarget(place: .journal("j1"), detailPath: path,
                                               orderedIDs: ids, direction: .previous), "newest")
        XCTAssertNil(EntryPager.pagingTarget(place: .capture, detailPath: path,
                                             orderedIDs: ids, direction: .next),
                     "capture-pushed details have no 'list you came from' — no paging")
        XCTAssertNil(EntryPager.pagingTarget(place: .trash, detailPath: path,
                                             orderedIDs: ids, direction: .next))
        XCTAssertNil(EntryPager.pagingTarget(place: .about, detailPath: path,
                                             orderedIDs: ids, direction: .next))
        XCTAssertNil(EntryPager.pagingTarget(place: .debug, detailPath: path,
                                             orderedIDs: ids, direction: .next))
    }

    func testPagingTargetRefusesNonEntryTops() {
        XCTAssertNil(EntryPager.pagingTarget(place: .allEntries, detailPath: [],
                                             orderedIDs: ids, direction: .next))
        XCTAssertNil(EntryPager.pagingTarget(place: .allEntries,
                                             detailPath: [.journalEditor("j1")],
                                             orderedIDs: ids, direction: .next))
        XCTAssertNil(EntryPager.pagingTarget(place: .allEntries,
                                             detailPath: [.entry("middle"), .journalEditor("j1")],
                                             orderedIDs: ids, direction: .next),
                     "only the TOP of the path pages; an editor above the entry blocks it")
    }

    // MARK: AppRouter.replaceTopEntry

    func testReplaceTopEntrySwapsOnlyAnEntryTop() {
        let router = AppRouter()
        router.detailPath = [.entry("A")]
        router.replaceTopEntry(with: "B")
        XCTAssertEqual(router.detailPath, [.entry("B")])

        router.detailPath = [.entry("A"), .journalEditor("j1")]
        router.replaceTopEntry(with: "C")
        XCTAssertEqual(router.detailPath, [.entry("A"), .journalEditor("j1")],
                       "a non-entry top is never replaced")

        router.detailPath = []
        router.replaceTopEntry(with: "C")
        XCTAssertEqual(router.detailPath, [], "an empty path is a no-op, never a crash")
    }

    func testReplaceTopEntryPreservesTheRestOfThePath() {
        let router = AppRouter()
        router.detailPath = [.entry("A"), .entry("B")]
        router.replaceTopEntry(with: "C")
        XCTAssertEqual(router.detailPath, [.entry("A"), .entry("C")],
                       "only the top element turns; anything beneath it stays")
    }
}
```

- [ ] **Step 2: Run the class to verify it fails to compile**

Run: the unit test command with `-only-testing:RaconteTests/EntryPagerTests`.
Expected: build FAILS with "cannot find 'EntryPager' in scope" (and no member `replaceTopEntry`).

- [ ] **Step 3: Implement**

`Raconte/Library/EntryPager.swift`:

```swift
import Foundation

/// #101: which way a page turn moves through the entry list.
/// The list is newest-first (`EntryListItem.sortedByEffectiveDate`), so
/// `.previous` moves toward newer (up, index-1) and `.next` toward older
/// (down, index+1). Design: docs/plans/2026-08-26-101-entry-paging-design.md.
enum PagingDirection: Sendable {
    case previous
    case next
}

/// #101: the paging pure core. No SwiftUI, no model types — arrays of ids in,
/// optional id out — so the direction mapping and the whole render/enable gate
/// are unit-tested without a view in sight.
enum EntryPager {

    /// nil when `captureID` is not in `orderedIDs` (the entry left its list's
    /// scope — both controls disable) or the neighbor falls off either end
    /// (design decision 2: disable at the ends, no wrap).
    static func neighborID(of captureID: String,
                           in orderedIDs: [String],
                           direction: PagingDirection) -> String? {
        guard let index = orderedIDs.firstIndex(of: captureID) else { return nil }
        let target = direction == .previous ? index - 1 : index + 1
        guard orderedIDs.indices.contains(target) else { return nil }
        return orderedIDs[target]
    }

    /// The whole gate in one testable place: paging exists only when the CURRENT
    /// place has a journal scope (an entry list to page — a capture-pushed detail
    /// has none) AND the top of the path is the entry itself (never a journal
    /// editor sitting above it). Used by the Mac menu commands directly; the
    /// detail view reaches the same verdict through its `pagingEnabled` input
    /// plus `neighborID` (same components, same answer).
    static func pagingTarget(place: Place,
                             detailPath: [LibraryDestination],
                             orderedIDs: [String],
                             direction: PagingDirection) -> String? {
        guard PlaceRouting.journalScope(for: place) != nil,
              case .entry(let current)? = detailPath.last
        else { return nil }
        return neighborID(of: current, in: orderedIDs, direction: direction)
    }
}
```

In `Raconte/App/Place.swift`, inside `AppRouter`, directly after `goBack()` / `canGoBack`:

```swift
    /// #101: a page turn — the top `.entry` element of the path is REPLACED, never
    /// popped-and-pushed, and never swapped in-place inside the detail view (its
    /// sub-models are init-once, keyed to captureID). Navigation-expressed paging is
    /// what makes the departing screen's onDisappear commit contracts fire for free.
    /// Guarded: a non-entry top (journal editor) or an empty path is a no-op.
    func replaceTopEntry(with captureID: String) {
        guard case .entry = detailPath.last else { return }
        detailPath[detailPath.count - 1] = .entry(captureID)
    }
```

- [ ] **Step 4: `xcodegen generate`, run the class again**

Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Library/EntryPager.swift Raconte/App/Place.swift RaconteTests/EntryPagerTests.swift
git commit -m "feat(paging): EntryPager pure core + AppRouter.replaceTopEntry (#101)"
```

---

### Task 2: Detail-screen controls — toolbar chevrons, iOS swipe, ContentView wiring

**Files:**
- Modify: `Raconte/Library/UI/EntryDetailView.swift` (init gains two parameters; toolbar gains a `ToolbarItemGroup`; iOS gains the swipe gesture; the `#Preview` at the bottom of the file updates)
- Modify: `Raconte/App/ContentView.swift` (the `.entry` destination builder — new arguments plus `.id(captureID)`)

**Interfaces:**
- Consumes: `EntryPager.neighborID`, `AppRouter.replaceTopEntry` (Task 1); existing `LibraryScreenModel.items: [EntryListItem]`, `EntryListItem.captureID: String`, `PlaceRouting.journalScope(for:)`.
- Produces: `EntryDetailView(model:item:pagingEnabled:onPage:)` — the new signature; toolbar buttons with identifiers `detail.previousEntry` / `detail.nextEntry` that Task 4's UI test drives.

- [ ] **Step 1: Extend EntryDetailView's stored properties and init**

In `Raconte/Library/UI/EntryDetailView.swift`, add two stored properties directly after `let captureID: String`:

```swift
    /// #101: false for a detail pushed from the Capture place (recent-entry row /
    /// post-stop receipt) — there is no "list you came from" to page, so the
    /// controls don't render at all. Computed by ContentView from the CURRENT
    /// place's journalScope; any sidebar selection clears the path, so the value
    /// cannot go stale under an open detail.
    let pagingEnabled: Bool
    /// #101: the page turn itself — ContentView binds this to
    /// `router.replaceTopEntry(with:)`. A closure, not the router, following the
    /// established seam (`LibraryView.onCreateEntry`).
    let onPage: (String) -> Void
```

Extend the `init` signature (existing body unchanged, two assignments added):

```swift
    @MainActor
    init(model: LibraryScreenModel, item: EntryListItem,
         pagingEnabled: Bool, onPage: @escaping (String) -> Void) {
        self.model = model
        self.captureID = item.captureID
        self.pagingEnabled = pagingEnabled
        self.onPage = onPage
        _item = State(initialValue: item)
        _editorModel = State(initialValue: TranscriptEditorModel(captureID: item.captureID,
                                                                 store: model))
        _voiceMarkingModel = State(initialValue: VoiceMarkingModel(captureID: item.captureID,
                                                                    store: model))
        _revisionHistoryModel = State(initialValue: RevisionHistoryModel(captureID: item.captureID,
                                                                          store: model))
    }
```

(If the existing init body differs slightly from the above, keep ITS body and add only the two new parameters and assignments — the four `State(initialValue:)` lines are whatever the file already has.)

- [ ] **Step 2: Add the paging computed properties and page function**

Add near the other private computed properties/helpers of `EntryDetailView`:

```swift
    // MARK: #101 paging

    /// Live list order, not a push-time snapshot (design decision 4): identical
    /// within an unchanged session, and the only truth that never navigates to a
    /// deleted entry after a rescan.
    private var pagingOrderedIDs: [String] { model.items.map(\.captureID) }

    private var previousEntryID: String? {
        guard pagingEnabled else { return nil }
        return EntryPager.neighborID(of: captureID, in: pagingOrderedIDs, direction: .previous)
    }

    private var nextEntryID: String? {
        guard pagingEnabled else { return nil }
        return EntryPager.neighborID(of: captureID, in: pagingOrderedIDs, direction: .next)
    }

    private func page(to targetID: String?) {
        guard let targetID else { return }
        onPage(targetID)
    }
```

- [ ] **Step 3: Add the toolbar group**

Inside the existing `.toolbar { … }` block (the one holding the `.principal` `ToolbarItem`), add after that item:

```swift
            // #101: chevrons match the vertical list — up = previous (newer),
            // down = next (older). Rendered only when there is a list to page
            // (design: scope gate); disabled at the ends (decision 2).
            if pagingEnabled {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        page(to: previousEntryID)
                    } label: {
                        Label("Previous Entry", systemImage: "chevron.up")
                    }
                    .disabled(previousEntryID == nil)
                    .accessibilityIdentifier("detail.previousEntry")

                    Button {
                        page(to: nextEntryID)
                    } label: {
                        Label("Next Entry", systemImage: "chevron.down")
                    }
                    .disabled(nextEntryID == nil)
                    .accessibilityIdentifier("detail.nextEntry")
                }
            }
```

- [ ] **Step 4: Add the iOS swipe**

On the detail screen's outer `ScrollView` (the view `body` returns, where the other whole-screen modifiers like `.toolbar` sit), add:

```swift
        #if os(iOS)
        // #101: swipe left = next (page forward, older), right = previous.
        // `.simultaneousGesture` because a plain `.gesture` loses to the
        // ScrollView's own pan; the horizontal-dominance guard keeps ordinary
        // vertical scrolling from ever paging. NOT UI-tested (repo memory:
        // simulator gestures ≠ device gestures) — owner-smoked on device;
        // the buttons above are the tested path through the same page(to:).
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy) * 1.5 else { return }
                    page(to: dx < 0 ? nextEntryID : previousEntryID)
                }
        )
        #endif
```

- [ ] **Step 5: Update ContentView's destination builder**

In `Raconte/App/ContentView.swift`, the `.entry` case of `.navigationDestination(for: LibraryDestination.self)` becomes:

```swift
                        case .entry(let captureID):
                            // The `else` is not decoration (issue #32): a destination
                            // builder that returns nothing still pushes, so an unresolvable
                            // id used to land the owner on a blank page with no way to tell
                            // what went wrong. `item` is scope-independent now, which leaves
                            // only the honest cases — a capture that is genuinely gone.
                            if let item = services.library.item(captureID) {
                                EntryDetailView(model: services.library,
                                                item: item,
                                                pagingEnabled: PlaceRouting.journalScope(
                                                    for: services.router.place) != nil,
                                                onPage: { services.router.replaceTopEntry(with: $0) })
                                    // #101, load-bearing: a page turn REPLACES this path
                                    // element in place, and a same-depth value change does
                                    // not reliably re-identify the destination view — the
                                    // init-once sub-models would stay on the OLD entry.
                                    // `.id` pins identity to the entry.
                                    .id(captureID)
                            } else {
```

(The `else` branch is untouched.)

- [ ] **Step 6: Update the `#Preview` in EntryDetailView.swift**

Whatever `EntryDetailView(...)` construction the preview at the bottom of the file uses gains `pagingEnabled: false, onPage: { _ in }`. If the file has no preview constructing `EntryDetailView`, skip this step. Then sweep for any OTHER construction site: `grep -rn "EntryDetailView(" Raconte RaconteTests` — ContentView and the preview must be the only ones; if another appears, stop and report it rather than guessing its paging semantics.

- [ ] **Step 7: Run the full unit suite, then the iOS compile check**

Run: `xcodegen generate`, the full unit test command, then the iOS compile check.
Expected: unit suite 0 failures (no new unit tests in this task — the view layer is covered by Task 4's UI test; the logic it calls was tested in Task 1); iOS BUILD SUCCEEDED (the `#if os(iOS)` gesture block only compiles there).

- [ ] **Step 8: Commit**

```bash
git add Raconte/Library/UI/EntryDetailView.swift Raconte/App/ContentView.swift
git commit -m "feat(paging): detail-screen chevrons + iOS swipe, identity-pinned page turns (#101)"
```

---

### Task 3: macOS Go-menu commands

**Files:**
- Create: none — the `AppServices` extension goes in `Raconte/Library/EntryPager.swift` (Task 1's file)
- Modify: `Raconte/App/RaconteCommands.swift`
- Test: `RaconteTests/AppRouterCommandTests.swift`

**Interfaces:**
- Consumes: `EntryPager.pagingTarget`, `AppRouter.replaceTopEntry` (Task 1); existing `AppServices` (`Raconte/App/RaconteApp.swift` — holds `library`, `router`).
- Produces: `AppServices.entryPagingTarget(_:) -> String?` and `AppServices.pageEntry(_:)`.

- [ ] **Step 1: Extend the unit tests first**

In `RaconteTests/AppRouterCommandTests.swift`, add to `testCommandTargetsAreTheRouterFunctions` (after the existing assertions):

```swift
        // #101: the Go menu's Previous/Next Entry items route through
        // replaceTopEntry — the same function the detail screen's own controls use.
        router.detailPath = [.entry("A")]
        router.replaceTopEntry(with: "B")
        XCTAssertEqual(router.detailPath, [.entry("B")])
```

Add a new test method to the same class:

```swift
    /// #101: the menu items' enable/target logic is `EntryPager.pagingTarget`,
    /// pinned end-to-end in EntryPagerTests — this pins only that the COMMAND-shaped
    /// inputs (a real router's place + path) reach it correctly.
    func testEntryPagingTargetGateMatchesTheRouterState() {
        let router = AppRouter()
        router.select(.allEntries)
        router.detailPath = [.entry("middle")]
        XCTAssertEqual(EntryPager.pagingTarget(place: router.place,
                                               detailPath: router.detailPath,
                                               orderedIDs: ["newest", "middle", "oldest"],
                                               direction: .next),
                       "oldest")
        router.select(.capture)   // select clears detailPath — the gate goes dark
        XCTAssertNil(EntryPager.pagingTarget(place: router.place,
                                             detailPath: router.detailPath,
                                             orderedIDs: ["newest", "middle", "oldest"],
                                             direction: .next))
    }
```

Run the class (`-only-testing:RaconteTests/AppRouterCommandTests`); expected: the new
method PASSES already (it exercises Task 1 code — this is a wiring pin, not TDD RED;
say so in the report rather than manufacturing a failure).

- [ ] **Step 2: Add the AppServices extension**

Append to `Raconte/Library/EntryPager.swift`:

```swift
/// #101: the Mac menu's view of paging. Lives here rather than in RaconteApp.swift
/// so everything #101 adds outside the view layer sits in one file. `@MainActor`
/// matches AppServices' own isolation.
@MainActor
extension AppServices {

    /// nil ⇒ the corresponding menu item is disabled. Recomputed on each Commands
    /// body evaluation; even a stale verdict is safe — `pageEntry` re-derives it.
    func entryPagingTarget(_ direction: PagingDirection) -> String? {
        EntryPager.pagingTarget(place: router.place,
                                detailPath: router.detailPath,
                                orderedIDs: library.items.map(\.captureID),
                                direction: direction)
    }

    func pageEntry(_ direction: PagingDirection) {
        guard let target = entryPagingTarget(direction) else { return }
        router.replaceTopEntry(with: target)
    }
}
```

(If the compiler objects that `AppServices` is not `@MainActor`, drop the extension's
`@MainActor` and match whatever isolation `AppServices` declares in RaconteApp.swift —
the two functions only touch `router` and `library`, both main-actor models.)

- [ ] **Step 3: Add the menu items**

In `Raconte/App/RaconteCommands.swift`, inside `CommandMenu("Go")`, after the Back button:

```swift
            Divider()
            // #101. ⌥⌘ arrows deliberately: a menu shortcut beats the responder
            // chain (the no-global-Esc lesson above), and bare or ⌘-only arrows
            // collide with text-editing bindings in any presented editor.
            Button("Previous Entry") { services.pageEntry(.previous) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(services.entryPagingTarget(.previous) == nil)
            Button("Next Entry") { services.pageEntry(.next) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(services.entryPagingTarget(.next) == nil)
```

- [ ] **Step 4: Run the full unit suite**

Run: the full unit test command. Expected: 0 failures (the source-scan test
`testNoGlobalEscapeBinding` must still pass — the new code contains neither
`cancelAction` nor `.escape`).

- [ ] **Step 5: Commit**

```bash
git add Raconte/Library/EntryPager.swift Raconte/App/RaconteCommands.swift RaconteTests/AppRouterCommandTests.swift
git commit -m "feat(paging): macOS Go-menu Previous/Next Entry, ⌥⌘ arrows (#101)"
```

---

### Task 4: Paging UI test

**Files:**
- Create: `RaconteUITests/EntryPagingUITests.swift`

**Interfaces:**
- Consumes: `detail.previousEntry` / `detail.nextEntry` (Task 2), `library.entryLink` row identifier (pre-existing), `openPlace(_:_:)` (pre-existing), the `RACONTE_UITEST_SEED_MARKER_ENTRY` seed (pre-existing — seeds THREE entries; see `Raconte/Capture/Debug/UITestSupport.swift`).
- Produces: nothing downstream.

- [ ] **Step 1: Write the test**

`RaconteUITests/EntryPagingUITests.swift`:

```swift
import XCTest

/// #101: paging walks the All-Entries list and disables at the ends. Drives the
/// BUTTONS only — the swipe gesture is deliberately untested here (repo memory:
/// simulator gestures fire where device gestures don't, so a sim swipe test pins
/// nothing about the device) and is owner-smoked instead; both paths share page(to:).
///
/// Assertions are POSITION-based (top row, count of taps), never content-based —
/// the marker seed's three entries page deterministically (effectiveDate desc,
/// captureID-desc tie-break) without this test knowing which entry is which.
/// This test is also the proof of the `.id(captureID)` identity pin: without it a
/// page turn reuses the old view's state and the enable/disable pattern below
/// cannot occur.
final class EntryPagingUITests: XCTestCase {

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

    private func button(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    func testPagingWalksTheListAndDisablesAtTheEnds() {
        let app = launchApp()
        openPlace(app, "sidebar.allEntries")

        let rows = app.descendants(matching: .any).matching(identifier: "library.entryLink")
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 20),
                      "the marker seed provides three entries; fewer means the seed changed")
        rows.element(boundBy: 0).tap()

        let next = button(app, "detail.nextEntry")
        let previous = button(app, "detail.previousEntry")
        XCTAssertTrue(next.waitForExistence(timeout: 10), "paging chevrons missing on detail")
        XCTAssertFalse(previous.isEnabled, "top row = first of the list = no previous")
        XCTAssertTrue(next.isEnabled)

        next.tap()   // → middle entry
        XCTAssertTrue(button(app, "detail.previousEntry").waitForExistence(timeout: 10))
        XCTAssertTrue(button(app, "detail.previousEntry").isEnabled,
                      "middle entry pages both ways")
        XCTAssertTrue(button(app, "detail.nextEntry").isEnabled)

        button(app, "detail.nextEntry").tap()   // → last entry
        XCTAssertTrue(button(app, "detail.previousEntry").waitForExistence(timeout: 10))
        XCTAssertFalse(button(app, "detail.nextEntry").isEnabled,
                       "last entry = end of the list = next disables (no wrap)")
        XCTAssertTrue(button(app, "detail.previousEntry").isEnabled)

        button(app, "detail.previousEntry").tap()   // ← back to the middle
        XCTAssertTrue(button(app, "detail.nextEntry").waitForExistence(timeout: 10))
        XCTAssertTrue(button(app, "detail.nextEntry").isEnabled,
                      "paging back re-enables next — the turn really changed entries")
    }
}
```

- [ ] **Step 2: Run the new class**

Run: `xcodegen generate`, then the UI test command with `-only-testing:RaconteUITests/EntryPagingUITests` (FOREGROUND).
Expected: 1/1 PASS. If "iPhone 17" is unavailable, pick an available iPhone from `xcrun simctl list devices` and note it in the report.

- [ ] **Step 3: Regression-run the detail-screen-heavy class**

Run: the UI test command with `-only-testing:RaconteUITests/VoiceMarkingUITests` (the class that lives on the detail screen whose toolbar this branch changed).
Expected: same pass count as baseline, 0 failures. A single flaky-looking failure: re-run once to distinguish flake from regression; report both outcomes.

- [ ] **Step 4: Commit**

```bash
git add RaconteUITests/EntryPagingUITests.swift
git commit -m "test(paging): EntryPagingUITests — walk the list, ends disable (#101)"
```

---

### Final gate (controller, not a task)

- Full unit suite: 0 failures. iOS compile check: BUILD SUCCEEDED.
- Whole-branch review, then PR to `main` — merges are the owner's; the branch ends at
  an OPEN PR whose body says "addresses #101" (never a close-verb + #101 — the owner
  closes after the device smoke, because the swipe gesture and the ⌥⌘ shortcuts are
  deliberately not machine-tested).
- Owner device-smoke instructions to include in the handoff/PR:
  1. iPhone: open any journal → open an entry → swipe left/right pages older/newer;
     chevrons match; at the newest entry the up-chevron is disabled, at the oldest
     the down-chevron is.
  2. iPhone: edit the backdate, immediately page away, page back — the edit stuck
     (the write-through-on-commit contract under a page turn).
  3. Mac: open an entry → ⌥⌘↓ / ⌥⌘↑ page; both menu items disable on the capture
     screen and at the list ends.
