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
}
