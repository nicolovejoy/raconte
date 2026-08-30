import XCTest

/// #89: the About screen renders in the harness build and carries its three
/// diagnostic rows. The harness runs with `SyncCoordinator.live()` refused (nil
/// coordinator), so the Sync section's DEGRADED row is the assertible state here —
/// the live-coordinator rows are owner-smoked on a TestFlight build, where the
/// whole point of this screen (Release visibility) is the thing under test.
final class AboutUITests: XCTestCase {

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

    func testAboutScreenShowsVersionEnvironmentAndSyncRows() {
        let app = launchApp()
        openPlace(app, "sidebar.about")

        // The three diagnostic rows moved below the fold when About gained its
        // "What this is" / "How it works" sections (record-flow branch, owner request:
        // About is the only Release-built screen that can tell a first-time user what
        // this app is). An offscreen `List` row is absent from the accessibility tree
        // until it is scrolled into view, so without this the rows read as MISSING
        // rather than merely off-screen — which is exactly how this test failed on CI.
        // Directional, not a fixed distance, so it survives other device sizes.
        app.swipeUp()

        let version = app.descendants(matching: .any)
            .matching(identifier: "about.version").firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10), "version row missing")

        let environment = app.descendants(matching: .any)
            .matching(identifier: "about.environment").firstMatch
        XCTAssertTrue(environment.waitForExistence(timeout: 10), "environment row missing")

        let syncDegraded = app.descendants(matching: .any)
            .matching(identifier: "about.sync.unavailable").firstMatch
        XCTAssertTrue(syncDegraded.waitForExistence(timeout: 10),
                      "harness builds have no sync coordinator — the Sync section must "
                      + "degrade to its explanatory row, never hide")
    }
}
