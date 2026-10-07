import XCTest

/// #83: swipe-to-trash has no confirmation; the row lingers for two seconds as a
/// tap-to-undo, then leaves (the test launches with a 6 s window). One test, both halves: an undo first (the protection the
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
        // A 6 s window instead of 2 s, so a loaded CI runner can act inside it.
        app.launchEnvironment["RACONTE_UITEST_TRASH_LINGER_MS"] = "6000"
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
        // No confirmation dialog exists any more; the lingering row appearing straight
        // after the swipe is the proof.
        XCTAssertEqual(rows.count, 2, "the lingering row replaces the link; the other two stay")
        lingering.tap()
        waitUntil(10, "undo did not bring the row back") { rows.count == 3 && !lingering.exists }

        // Half 2: swipe again and let the two-second window close.
        swipeTopRowToTrash(app)
        XCTAssertTrue(elements(app, "library.row.lingering").firstMatch.waitForExistence(timeout: 5),
                      "no lingering row after the second swipe")
        waitUntil(30, "the lingering row never left the list") {
            rows.count == 2 && !elements(app, "library.row.lingering").firstMatch.exists
        }
    }
}
