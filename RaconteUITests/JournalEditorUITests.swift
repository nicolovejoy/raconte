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
