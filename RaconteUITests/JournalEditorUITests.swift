import XCTest

final class JournalEditorUITests: XCTestCase {
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

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    /// A SwiftUI `Toggle` in a `Form`/`List` merges its label and switch into ONE
    /// accessibility element spanning the whole row, and `.tap()` taps that element's
    /// CENTER — which lands on the label text, not the switch. A real finger tap
    /// anywhere on the row does flip it (this is not a production bug; verified by
    /// probe), but XCUITest's synthesized center-tap on this control specifically does
    /// not. Tapping near the trailing edge, where the switch itself renders, does.
    private func toggle(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        #endif
    }

    /// Same shape as `CaptureUITests`' own private copy: XCTest's expectation API can't
    /// watch a query/label predicate directly, so a simple poll loop keeps these tests
    /// readable. Duplicated rather than shared, matching this test target's existing
    /// per-file-helper convention (`press`, `launchApp`, etc.).
    private func waitUntil(_ timeout: TimeInterval = 20, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// Wait for the post-stop receipt and dismiss it — mirrors `CaptureUITests`'
    /// `finishReceipt`, needed here only to get a real entry into a journal for the
    /// disabled-affordance test below.
    private func finishReceipt(_ app: XCUIApplication) {
        let dismiss = app.buttons["capture.receipt.dismiss"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 30),
                      "the post-stop receipt never appeared")
        press(dismiss)
    }

    /// `openPlace`/`firstJournalRow` (`UITestNavigation.swift`) each try exactly ONE
    /// reveal tap before searching, which is enough from a place's own root screen. The
    /// editor is a SECOND push on top of that root (sidebar -> journal list ->
    /// `JournalEditorView`), so reaching the sidebar from inside it can take two taps on
    /// the collapsed iPhone stack. Loops rather than assuming a fixed depth, so it stays
    /// correct if a later task pushes the editor from somewhere already one level deeper.
    private func revealSidebar(_ app: XCUIApplication) {
        for _ in 0..<4 {
            if app.descendants(matching: .any)
                .matching(identifier: "sidebar.allEntries").firstMatch.exists { return }
            if app.buttons["Show Sidebar"].firstMatch.exists {
                app.buttons["Show Sidebar"].firstMatch.tap()
            } else if app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            } else {
                return
            }
        }
    }

    /// Tapping the journal header pushes the editor (Task 6), and its name field starts
    /// out prefilled with the journal's actual name — not just "some field exists".
    func testTappingTheHeaderOpensTheEditorPrefilledWithTheJournalName() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        let journalRow = firstJournalRow(app)
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        let journalName = journalRow.label
        press(journalRow)

        let header = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        press(header)

        let nameField = app.textFields["journalEditor.name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 15),
                      "tapping the journal header did not open the editor")
        XCTAssertEqual(nameField.value as? String, journalName,
                       "the editor's name field did not start prefilled with the journal's actual name")
    }

    /// The load-bearing test for the write-through requirement (Task 6 brief): a rename
    /// must survive the editor being popped out from under it with NO Done button and NO
    /// explicit defocus — `PlaceRouting.detailPath(afterSelecting:from:path:)` always
    /// clears `detailPath`, so any sidebar tap tears this screen down immediately. This
    /// pins the `onDisappear` safety net specifically: it types into the field, then goes
    /// straight to another sidebar place without ever tapping away first, which is the
    /// one path a focus-loss-only commit would silently lose.
    func testRenameSurvivesTheEditorBeingPoppedFromUnderneathBySidebarNavigation() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        let journalRow = firstJournalRow(app)
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        press(journalRow)

        let header = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        press(header)

        let nameField = app.textFields["journalEditor.name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 15))
        press(nameField)
        // Appended, not replaced — the default journal name is short ("Journal"), and a
        // distinctive suffix is enough to assert on without needing a reliable
        // select-all across both platforms.
        nameField.typeText(" Renamed XYZ")

        // Straight to another place, no Done button, no manual defocus — the exact
        // scenario `onDisappear` exists to guard against. `revealSidebar` first since
        // the editor is a second push (see its doc comment) that `openPlace`'s own
        // single-tap reveal cannot be relied on to escape in one shot.
        revealSidebar(app)
        openPlace(app, "sidebar.allEntries")
        XCTAssertFalse(app.textFields["journalEditor.name"].firstMatch.exists,
                       "the editor should have been popped, not left on screen")

        let journalRowAgain = firstJournalRow(app)
        XCTAssertTrue(journalRowAgain.waitForExistence(timeout: 15))
        press(journalRowAgain)

        let headerAgain = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(headerAgain.waitForExistence(timeout: 15))
        XCTAssertTrue(headerAgain.label.contains("Renamed XYZ"),
                      "the rename did not survive the editor being popped underneath it "
                      + "(onDisappear write-through did not reach the registry) — "
                      + "header label was: \(headerAgain.label)")
    }

    /// Same load-bearing shape as the rename test above, for Task 7's span editor: turn
    /// the "This journal covers a date range" toggle on (no year/month/day wheel
    /// interaction needed — the toggle alone commits an open-ended span anchored on
    /// today, per `JournalSpanEditor`'s default), then leave via a sidebar tap with no
    /// Done button and no explicit defocus. Checks the effect on `journal.header`'s
    /// dateLine (`JournalDateLine`, span-first) rather than reopening the editor and
    /// re-reading its own toggle state, so the pin is independent of the control that
    /// wrote it.
    func testSettingASpanSurvivesTheEditorBeingPoppedFromUnderneathBySidebarNavigation() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        let journalRow = firstJournalRow(app)
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        press(journalRow)

        let header = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        XCTAssertFalse(header.label.contains("–"),
                       "a brand-new journal must start with no span — header was: \(header.label)")
        press(header)

        let hasSpanToggle = app.switches["journalSpanEditor.hasSpan"].firstMatch
        XCTAssertTrue(hasSpanToggle.waitForExistence(timeout: 15))
        toggle(hasSpanToggle)

        // Straight to another place, no Done button, no manual defocus — the exact
        // scenario `onDisappear` exists to guard against, same as the rename test.
        revealSidebar(app)
        openPlace(app, "sidebar.allEntries")
        XCTAssertFalse(app.switches["journalSpanEditor.hasSpan"].firstMatch.exists,
                       "the editor should have been popped, not left on screen")

        let journalRowAgain = firstJournalRow(app)
        XCTAssertTrue(journalRowAgain.waitForExistence(timeout: 15))
        press(journalRowAgain)

        let headerAgain = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(headerAgain.waitForExistence(timeout: 15))
        XCTAssertTrue(headerAgain.label.contains("–"),
                      "the span did not survive the editor being popped underneath it "
                      + "(onChange/onDisappear write-through did not reach the registry) — "
                      + "header label was: \(headerAgain.label)")
    }

    /// Task 8: the cover row is the editor's only remaining route to a journal's cover
    /// now that the capture screen's picker is gone. This pins the wiring end-to-end —
    /// tapping "Add a cover photo…" presents the real `JournalCoverPickerSheet` (its
    /// title names the journal, its Choose-from-Library row is reachable) — without
    /// actually driving a photo pick, which XCUITest cannot do against a real Photos
    /// library. Cancel proves it is a real dismissible sheet, not a dead tap.
    func testAddingACoverOpensTheRealPickerSheet() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        let journalRow = firstJournalRow(app)
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        press(journalRow)

        let header = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        press(header)

        let nameField = app.textFields["journalEditor.name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 15))

        let addCoverButton = app.buttons["journalEditor.cover.add"].firstMatch
        XCTAssertTrue(addCoverButton.waitForExistence(timeout: 15),
                      "a journal with no cover must offer an add-cover affordance")
        press(addCoverButton)

        let choosePhoto = app.buttons["journalCover.choosePhoto"].firstMatch
        XCTAssertTrue(choosePhoto.waitForExistence(timeout: 15),
                      "tapping Add a cover photo… did not present the real cover picker sheet")

        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        press(cancel)

        XCTAssertTrue(app.textFields["journalEditor.name"].firstMatch.waitForExistence(timeout: 15),
                      "Cancel should dismiss the sheet back to the still-open editor")
    }

    /// A journal place shows the journal itself above its entries — All Entries does not.
    func testSelectingAJournalShowsItsHeader() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        openPlace(app, "sidebar.allEntries")
        XCTAssertFalse(app.descendants(matching: .any)
                        .matching(identifier: "journal.header").firstMatch.exists,
                       "All Entries is not a journal and must show no journal header")

        // Not `openPlace` — the journal's id is minted fresh per test run, so it can't
        // be named exactly the way `openPlace` requires. `firstJournalRow` mirrors its
        // reveal step for a prefix match instead (UITestNavigation.swift).
        let journalRow = firstJournalRow(app)
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        press(journalRow)

        XCTAssertTrue(app.descendants(matching: .any)
                        .matching(identifier: "journal.header").firstMatch
                        .waitForExistence(timeout: 15),
                      "selecting a journal did not show its header")
    }

    /// The sidebar `+` (nav T9) is a third caller of the one existing creation path
    /// (`CaptureScreenModel.createJournal`, also used by the capture screen's own "New
    /// Journal…" and the Mac's ⌘N) and, unlike either of those, pushes straight into the
    /// new journal's editor — the owner's ruling that this is the moment the metadata is
    /// actually in hand.
    func testSidebarPlusCreatesAJournalAndOpensItsEditor() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30))

        // Reveal the sidebar on compact width before reaching for its toolbar.
        // `openPlace` reveals AND selects — selecting pushes past the sidebar onto the
        // chosen place's own screen, hiding the sidebar (and its toolbar) again. The `+`
        // lives on the sidebar itself, so this needs the reveal-only helper.
        revealSidebar(app)
        let plus = app.buttons["sidebar.newJournal"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15),
                      "the sidebar has no New Journal button")
        press(plus)

        // Not queried by `root.newJournalNameField` (issue #66): a SwiftUI
        // `.accessibilityIdentifier` on an `.alert`'s `TextField` does not bridge onto the
        // native `UIAlertController` text field it becomes. It is the only text field on
        // screen at this point, so `app.textFields.firstMatch` is unambiguous — same
        // workaround `NavigationUITests` already uses for this identical alert reached via
        // ⌘N/the capture picker.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        press(field)
        field.typeText("Blue rabbit 2027")
        app.buttons["Create"].firstMatch.tap()

        XCTAssertTrue(app.textFields["journalEditor.name"].firstMatch
                        .waitForExistence(timeout: 15),
                      "creating from the sidebar did not open the new journal's editor")
    }

    /// Fix-round-1 pin: `ContentView`'s `.onChange(of: library.journals)` must NOT
    /// re-select the current place on every journals mutation. `library.journals`
    /// changes on EVERY rescan — a rename, a cover set, an unrelated journal being
    /// created (nav T9's own sidebar `+`) — and `router.select` unconditionally clears
    /// `detailPath` (`PlaceRouting.detailPath` always returns `[]`), EVEN when the
    /// resolved place is identical to the one already showing. This is the exact shape
    /// issue #67 flags for the `m4/sync` merge: a background CloudKit journals pull
    /// must not pop the reader mid-read.
    ///
    /// No sidebar-`+`/⌘N-driven repro is reachable from this suite while keeping
    /// `detailPath` non-empty: reaching the sidebar's `+` requires revealing the
    /// sidebar first, which — on the collapsed iPhone stack this suite drives — pops
    /// any open push BEFORE the `+` is even visible (see `revealSidebar`'s doc
    /// comment), and ⌘N is `#if os(macOS)`-only, absent from this target entirely
    /// (`RaconteCommands.swift`). Renaming a journal from its OWN open editor is the
    /// cheapest real trigger that keeps `detailPath` non-empty throughout: it mutates
    /// `library.journals` (`LibraryScreenModel.renameJournal` → `rescan()`) while the
    /// editor itself stays the visible, pushed screen — no navigation involved at all.
    /// If the guard regresses to an unconditional `router.select`, this in-place
    /// rename immediately pops the editor back to the journal's plain library, purely
    /// as a side effect of committing its own name field.
    func testRenamingFromTheOpenEditorDoesNotPopTheEditorItself() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30))

        let journalRow = firstJournalRow(app)
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        press(journalRow)

        let header = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        press(header)

        let nameField = app.textFields["journalEditor.name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 15))
        press(nameField)
        // "\n" hits `.onSubmit { commitName() }` — commits WITHOUT navigating
        // anywhere, the in-place mutation the guard must survive.
        nameField.typeText(" Renamed In Place\n")

        // Let the async rename + rescan round trip land, then assert the editor is
        // STILL the screen on top — not popped back to the journal's library. A
        // fixed settle wait, not a `waitForExistence` poll: the field exists BEFORE
        // the round trip lands too, so polling for its existence would pass
        // vacuously before the regression this test exists to catch has any chance
        // to fire.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.textFields["journalEditor.name"].firstMatch.exists,
                      "the editor was popped by its own in-place rename — "
                      + "the journals-onChange guard regressed to an unconditional select")

        // Confirm the rename genuinely reached the registry (not a false pass from
        // the async write never landing at all): leave and come back, same pattern
        // as `testRenameSurvivesTheEditorBeingPoppedFromUnderneathBySidebarNavigation`.
        revealSidebar(app)
        openPlace(app, "sidebar.allEntries")
        let journalRowAgain = firstJournalRow(app)
        XCTAssertTrue(journalRowAgain.waitForExistence(timeout: 15))
        press(journalRowAgain)
        let headerAgain = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(headerAgain.waitForExistence(timeout: 15))
        XCTAssertTrue(headerAgain.label.contains("Renamed In Place"),
                      "the in-place rename did not actually reach the registry — "
                      + "header was: \(headerAgain.label)")
    }

    /// Fix-round-1 item 2: the capture screen's own "New Journal…" (`JournalHeaderView`,
    /// `CaptureView.swift:398,421,474`) is a DIFFERENT code path from the shared root
    /// alert the sidebar `+`/⌘N use (`ContentView.swift`'s `$router.showingNewJournalPrompt`)
    /// — it owns its own private `showingNewJournalPrompt`/`draftName` state and its
    /// Create button calls `model.createJournal` directly with no `router` interaction
    /// at all. By design (spec ruling 6, #69): you meet a new paper journal at the
    /// moment you sit down to read it, and editing its name/cover/span is housekeeping
    /// for later — dropping the owner into an editor mid-capture would be wrong. Pinned
    /// here so a future edit that accidentally routes this path through the shared
    /// alert (and inherits its editor push) can't do so silently.
    func testCaptureScreenNewJournalStaysOnCapture() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30))

        // Not `capture.journalPicker` (the Menu's own identifier) — the enclosing
        // VStack's `capture.journalHeader` is what actually resolves to a queryable
        // button, per the container-identifier-flattening trap `NavigationUITests`
        // already documents for this exact control.
        let journalPicker = app.buttons["capture.journalHeader"].firstMatch
        XCTAssertTrue(journalPicker.waitForExistence(timeout: 15))
        press(journalPicker)
        let newJournalItem = app.buttons["New Journal…"].firstMatch
        XCTAssertTrue(newJournalItem.waitForExistence(timeout: 10))
        press(newJournalItem)

        // Not `capture.newJournalNameField` (issue #66): an alert `TextField`'s
        // `.accessibilityIdentifier` does not bridge onto the native
        // `UIAlertController` field it becomes. Only text field on screen.
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        press(nameField)
        nameField.typeText("Capture Path Journal")
        app.buttons["Create"].firstMatch.tap()

        // Must still be ON the capture screen, never the journal editor.
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15),
                      "creating a journal from the capture screen navigated away from capture")
        XCTAssertFalse(app.textFields["journalEditor.name"].firstMatch.exists,
                       "the capture screen's New Journal must never open the journal editor")
    }

    // MARK: Task B3 (#80) — delete an empty journal from its editor

    /// A brand-new, empty journal that is NOT the last one in the registry (the sidebar
    /// `+` flow leaves the pre-existing default journal in place too) must be
    /// deletable. Confirming the dialog must both remove the sidebar row AND pop the
    /// editor onto a real screen — never a stale "Journal Unavailable" push, the same
    /// hazard issue #32 named for a deleted entry, and never a blank detail column.
    /// Navigation is expected to fall out of the existing `ContentView`
    /// `.onChange(of: library.journals)` / `PlaceRouting.resolve` machinery (the #67
    /// guard's own documented id-left-registry case) rather than anything this test
    /// drives directly.
    func testDeletingAnEmptyJournalRemovesItAndLandsSomewhereSane() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        revealSidebar(app)
        let journalRowsBefore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.journal.'")).count

        let plus = app.buttons["sidebar.newJournal"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15),
                      "the sidebar has no New Journal button")
        press(plus)

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        press(field)
        field.typeText("Deletable Journal")
        app.buttons["Create"].firstMatch.tap()

        let nameField = app.textFields["journalEditor.name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 15),
                      "creating from the sidebar did not open the new journal's editor")

        let deleteRow = app.buttons["journalEditor.delete"].firstMatch
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 15),
                      "the editor has no Delete Journal affordance")
        XCTAssertTrue(deleteRow.isEnabled,
                      "a brand-new, non-last journal with no entries must be deletable")
        press(deleteRow)

        let confirm = app.buttons["journalEditor.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15),
                      "no delete confirmation dialog appeared")
        press(confirm)

        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15),
                      "deleting the open journal did not land on a real screen")
        XCTAssertFalse(app.textFields["journalEditor.name"].firstMatch.exists,
                       "the editor should have been popped once its journal was deleted")
        XCTAssertFalse(app.descendants(matching: .any)
                        .matching(identifier: "journalEditor.unavailable").firstMatch.exists,
                       "deletion must not leave a stale editor push showing a blank "
                       + "Unavailable screen")

        revealSidebar(app)
        let journalRowsAfter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.journal.'")).count
        XCTAssertEqual(journalRowsAfter, journalRowsBefore,
                      "the deleted journal's sidebar row must be gone")
    }

    /// Owner ruling 2 (#80): a journal that cannot be deleted still shows the row —
    /// disabled, with an explanatory footnote — never an invisible affordance. A
    /// journal holding a real entry is the concrete trigger named in the brief; the
    /// default journal from a fresh launch is used directly rather than creating a
    /// second one, since it is also (incidentally) the last-remaining journal, and
    /// either reason is sufficient to refuse.
    func testAJournalWithAnEntryShowsTheDisabledDeleteAffordance() {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)
        press(record)
        finishReceipt(app)

        let journalRow = firstJournalRow(app)
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        press(journalRow)

        let header = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        press(header)

        let deleteRow = app.buttons["journalEditor.delete"].firstMatch
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 15),
                      "a journal with an entry must still show the Delete Journal row")
        XCTAssertFalse(deleteRow.isEnabled,
                       "a journal holding an entry must not be deletable")

        // The delete row is the LAST section, so its footer sits below the fold on
        // iPhone — the Form's underlying `UICollectionView` does not materialize an
        // accessibility element for a supplementary view that has never scrolled into
        // view. Scroll it in before searching, same idiom `CaptureControlsUITests`
        // already uses for an offscreen scroll view.
        deleteRow.swipeUp()

        let reason = app.descendants(matching: .any)
            .matching(identifier: "journalEditor.delete.reason").firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 15),
                      "a disabled delete affordance must explain why, not just refuse silently")
        XCTAssertFalse(reason.label.isEmpty)
    }
}
