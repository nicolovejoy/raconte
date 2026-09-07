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

    /// #105: one action copies the whole transcript. Reading `UIPasteboard` from the
    /// test-runner process can trigger the system Allow-Paste prompt on iOS 16+, which
    /// blocks XCUITest indefinitely — so this drives the row and confirms the sheet
    /// dismisses, rather than reading the clipboard back here. The clipboard CONTENT
    /// (paragraph joins, plain text, nil-when-empty) is covered by the pure
    /// `EntryTranscriptCopyTextTests`.
    func testCopyTranscriptRowIsOfferedAndDismissesTheSheet() {
        let app = launchApp()
        openFirstEntry(app)
        let more = app.buttons["detail.moreButton"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "`⋯` toolbar button missing on detail")
        more.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "detail.infoSheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "info sheet did not present")
        let copy = app.buttons["detail.copyTranscriptButton"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "copy row missing on an entry with a transcript")
        copy.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "info sheet still present after Copy transcript")
        XCTAssertTrue(more.exists, "detail screen's `⋯` button should still be present after the sheet dismisses")
    }

    /// #148: the detail screen names its journal and the name opens that journal.
    /// The seed's entry starts unfiled, so the test files it first through the existing
    /// info-sheet → Move → New Journal… flow, then reads the link that appears.
    func testJournalRowNamesTheJournalAndOpensIt() {
        let app = launchApp()
        openFirstEntry(app)

        let unfiled = app.descendants(matching: .any).matching(identifier: "detail.journalUnfiled").firstMatch
        XCTAssertTrue(unfiled.waitForExistence(timeout: 15), "an unfiled entry must say so")

        let more = app.buttons["detail.moreButton"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "detail.infoSheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        app.descendants(matching: .any).matching(identifier: "detail.journalPicker").firstMatch.tap()

        let newJournal = app.descendants(matching: .any).matching(identifier: "journalPicker.new").firstMatch
        XCTAssertTrue(newJournal.waitForExistence(timeout: 15), "picker has no New Journal… row")
        newJournal.tap()
        // #66: a SwiftUI identifier on an `.alert` TextField does not bridge onto the
        // UIAlertController field; it is the only text field on screen here.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Blue rabbit 2027")
        app.buttons["Create"].firstMatch.tap()

        let link = app.descendants(matching: .any).matching(identifier: "detail.journalLink").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), "a filed entry shows no journal link")
        XCTAssertTrue(link.label.contains("Blue rabbit 2027"), "link label was: \(link.label)")
        link.tap()

        let header = app.descendants(matching: .any).matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "the link did not open the journal")
        XCTAssertTrue(header.label.contains("Blue rabbit 2027"), "header label was: \(header.label)")
    }
}
