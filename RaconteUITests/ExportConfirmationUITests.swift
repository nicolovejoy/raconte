import XCTest

/// #157: the confirmation sheet between the folder picker and the first written byte.
///
/// The system folder picker cannot be driven from XCUITest, so the harness build accepts
/// `RACONTE_UITEST_EXPORT_DESTINATION=tmp` and opens the sheet for the app's own temporary
/// directory instead — same DEBUG-gated env-var pattern as the seeds in `UITestSupport`.
/// `RACONTE_UITEST_SEED_ENTRY` seeds exactly one capture (a revision chain, no `entry.json`),
/// which the sheet must count under `Unfiled entries · 1`.
final class ExportConfirmationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = UUID().uuidString
        app.launchEnvironment["RACONTE_UITEST_SEED_ENTRY"] = "1"
        app.launchEnvironment["RACONTE_UITEST_EXPORT_DESTINATION"] = "tmp"
        app.launch()
        return app
    }

    /// Same reason and shape as `AboutUITests.revealRow`: About's Archive section is below
    /// the fold and an offscreen List row is absent from the accessibility tree.
    private func revealRow(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<8 where !element.exists {
            app.swipeUp()
        }
        return element
    }

    /// `.tap()` on a Form Toggle lands on the label, not the switch (standing lesson);
    /// tap at the trailing edge where the switch renders.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    private func openSheet(_ app: XCUIApplication) -> XCUIElement {
        openPlace(app, "sidebar.about")
        revealRow(app, "about.export").tap()
        let sheet = app.descendants(matching: .any)["about.export.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "confirmation sheet did not present")
        return sheet
    }

    func testSheetShowsDestinationCountsAndCancelWritesNothing() {
        let app = launchApp()
        _ = openSheet(app)

        XCTAssertTrue(app.descendants(matching: .any)["about.export.destination"].exists)
        let unfiled = app.descendants(matching: .any)["about.export.unfiled"]
        XCTAssertTrue(unfiled.exists, "the seeded entry has no entry.json, so it is unfiled")
        XCTAssertEqual(unfiled.label, "Unfiled entries · 1")

        let confirm = app.buttons["about.export.confirm"]
        XCTAssertTrue(confirm.exists)
        XCTAssertEqual(confirm.label, "Export 1 entry")
        XCTAssertTrue(confirm.isEnabled)

        app.buttons["about.export.cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["about.export.sheet"]
            .waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["about.export.progress"].exists,
                       "Cancel must not start an export")
        XCTAssertFalse(app.descendants(matching: .any)["about.export.result"].exists,
                       "Cancel must not produce a result row")
    }

    func testDeselectingUnfiledDropsTheCountToZeroAndDisablesExport() {
        let app = launchApp()
        _ = openSheet(app)
        let confirm = app.buttons["about.export.confirm"]
        let unfiled = app.descendants(matching: .any)["about.export.unfiled"]

        flip(unfiled)
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        XCTAssertEqual(confirm.label, "Export 0 entries")
        XCTAssertFalse(confirm.isEnabled)

        flip(unfiled)
        XCTAssertEqual(confirm.label, "Export 1 entry")
        XCTAssertTrue(confirm.isEnabled)
    }

    func testConfirmExportsToTheHarnessDestinationAndReportsVerified() {
        let app = launchApp()
        _ = openSheet(app)

        app.buttons["about.export.confirm"].tap()

        let result = app.descendants(matching: .any)["about.export.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertTrue(result.label.hasPrefix("Exported 1 "), result.label)
        XCTAssertTrue(result.label.hasSuffix("— verified"), result.label)
    }
}
