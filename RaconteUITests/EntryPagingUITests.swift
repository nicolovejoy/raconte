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
