import XCTest

/// #81 Task 6: the Trash screen's "Unreadable entries" section — the owner's only way
/// to get an entry with a corrupt `entry.json` sidecar out of the archive without a
/// developer. Seeds a complete-otherwise entry whose sidecar is garbage bytes
/// (`UITestUnreadableEntrySeed`), opens Trash, and quarantines it through the row's
/// button and its confirmation dialog.
final class TrashRepairUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAnUnreadableEntryCanBeQuarantinedFromTrash() {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = UUID().uuidString
        app.launchEnvironment["RACONTE_UITEST_SEED_UNREADABLE_ENTRY"] = "1"
        app.launch()
        openPlace(app, "sidebar.trash")

        let section = app.staticTexts["trash.unreadable.section"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 5),
                      "the Unreadable entries section header never appeared")

        let row = app.otherElements["trash.unreadable.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "the unreadable-entries section never showed the seeded row")

        app.buttons["trash.unreadable.quarantine"].firstMatch.tap()
        let confirm = app.buttons["trash.unreadable.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "the quarantine confirmation dialog never presented")
        confirm.tap()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5),
                      "the row survived the quarantine")
    }
}
