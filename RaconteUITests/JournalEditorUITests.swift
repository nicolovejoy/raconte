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
}
