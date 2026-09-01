import XCTest

/// #128 Task 5: the bulk round trip, end to end — enter select mode in All Entries,
/// select two of the marker seed's three entries, bulk-trash them (confirming the
/// count-named dialog), verify both are gone from the list and present in Trash, then
/// bulk-restore them from Trash's own select mode and verify the library is whole again.
///
/// Screens are reached with `openPlace` only — never a hard-coded navigation tap.
/// Row selection is POSITION-based (boundBy), never content-based, same discipline as
/// `EntryPagingUITests`: the seed's three entries order deterministically and this test
/// does not need to know which is which.
final class BulkSelectUITests: XCTestCase {

    private var testID = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        testID = UUID().uuidString
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = testID
        // Three entries with real transcripts — enough rows to select two and still
        // have a third proving the bulk action did not over-reach.
        app.launchEnvironment["RACONTE_UITEST_SEED_MARKER_ENTRY"] = "1"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func elements(_ app: XCUIApplication, _ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    /// Polls, like `EntryPagingUITests`/`VoiceMarkingUITests`' helper of the same name.
    private func waitUntil(_ timeout: TimeInterval = 20, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    func testBulkTrashTwoEntriesThenBulkRestoreThemFromTrash() {
        let app = launchApp()
        openPlace(app, "sidebar.allEntries")

        let entryLinks = elements(app, "library.entryLink")
        XCTAssertTrue(entryLinks.element(boundBy: 2).waitForExistence(timeout: 20),
                      "the marker seed provides three entries; fewer means the seed changed")

        // Enter select mode and select the top two rows.
        element(app, "library.select").tap()
        let selectRows = elements(app, "library.selectRow")
        XCTAssertTrue(selectRows.element(boundBy: 2).waitForExistence(timeout: 10),
                      "select mode must re-render every row as a toggling row")
        selectRows.element(boundBy: 0).tap()
        selectRows.element(boundBy: 1).tap()
        waitUntil(10, "the bar must count exactly the two selected rows") {
            self.element(app, "library.selectionCount").label == "2 selected"
        }

        // Bulk trash, through the count-naming confirmation.
        element(app, "library.bulkTrash").tap()
        let confirm = element(app, "library.confirmBulkTrash")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "the bulk trash confirmation must present")
        confirm.tap()

        // Full success leaves select mode: navigable rows return, and only one remains.
        waitUntil(20, "exactly one entry must remain in the library after the bulk trash") {
            entryLinks.element(boundBy: 0).exists && !entryLinks.element(boundBy: 1).exists
        }

        // Both trashed entries are in Trash.
        openPlace(app, "sidebar.trash")
        let trashRows = elements(app, "trash.row.remaining")
        XCTAssertTrue(trashRows.element(boundBy: 1).waitForExistence(timeout: 20),
                      "both bulk-trashed entries must appear in Trash")
        XCTAssertFalse(trashRows.element(boundBy: 2).exists,
                       "only the two selected entries may have been trashed")

        // Bulk restore from Trash's own select mode (no confirmation — restore only
        // ever puts entries back).
        element(app, "trash.select").tap()
        let trashSelectRows = elements(app, "trash.selectRow")
        XCTAssertTrue(trashSelectRows.element(boundBy: 1).waitForExistence(timeout: 10),
                      "Trash select mode must re-render every row as a toggling row")
        trashSelectRows.element(boundBy: 0).tap()
        trashSelectRows.element(boundBy: 1).tap()
        element(app, "trash.bulkRestore").tap()

        XCTAssertTrue(element(app, "trash.empty").waitForExistence(timeout: 20),
                      "restoring both entries must leave the Trash empty")

        // And the library is whole again.
        openPlace(app, "sidebar.allEntries")
        waitUntil(20, "all three entries must be back after the bulk restore") {
            entryLinks.element(boundBy: 2).exists
        }
    }
}
