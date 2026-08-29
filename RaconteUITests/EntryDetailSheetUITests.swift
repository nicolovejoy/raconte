import XCTest

/// Task 5 (#55): the `⋯` info sheet gathering journal/backdate/add-image/edit/mark-voices/
/// revision-history/trash. Drives the sheet only — the destinations it hands off to
/// (editor, backdate sheet, image picker, trash confirmation) are exercised end-to-end
/// by their own test classes; this class checks the sheet opens, carries the right
/// identifiers, and that one row (edit) actually reaches its destination, plus that
/// the trash row reaches its confirmation dialog.
final class EntryDetailSheetUITests: XCTestCase {

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

    private func openFirstEntry(_ app: XCUIApplication) {
        openPlace(app, "sidebar.allEntries")
        let rows = app.descendants(matching: .any).matching(identifier: "library.entryLink")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "no entries in the seed")
        rows.element(boundBy: 0).tap()
    }

    func testMoreButtonOpensInfoSheetAndEditRowReachesTheEditor() {
        let app = launchApp()
        openFirstEntry(app)

        let more = app.buttons["detail.moreButton"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "`⋯` toolbar button missing on detail")
        more.tap()

        let sheet = app.descendants(matching: .any).matching(identifier: "detail.infoSheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "info sheet did not present")

        let edit = app.buttons["detail.editButton"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Edit transcript row missing from the info sheet")
        edit.tap()

        // The sheet's own dismissal must complete before the editor push begins (the
        // `pendingInfoAction`/`onDismiss:` dance) — `editor.done`'s toolbar button is
        // this class's proxy for "the editor actually appeared", the same identifier
        // `TranscriptEditorView` always carries regardless of loading/editing/read-only
        // state's own body.
        let editorDone = app.buttons["editor.done"].firstMatch
        XCTAssertTrue(editorDone.waitForExistence(timeout: 10), "transcript editor never appeared")
    }

    func testTrashRowReachesTheConfirmationDialog() {
        let app = launchApp()
        openFirstEntry(app)

        let more = app.buttons["detail.moreButton"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()

        let trash = app.buttons["detail.trashButton"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 10), "Move to Trash row missing from the info sheet")
        trash.tap()

        let confirm = app.buttons["detail.confirmTrash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "trash confirmation dialog never appeared")

        // No explicit Cancel row to tap here (unrelated to this task): at this
        // window's size class the system renders this `confirmationDialog` as a
        // popover, which omits a Cancel item and relies on a tap outside to dismiss —
        // observed live via the accessibility tree, not a guess. Tapping the popover's
        // own dismiss region is that "outside tap"; nothing in this test needs the
        // trash write to actually happen.
        let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
        if dismissRegion.exists {
            dismissRegion.tap()
        } else {
            app.buttons["Cancel"].firstMatch.tap()
        }
    }
}
