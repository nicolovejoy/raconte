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

    /// Reveals a diagnostic row and returns it, scrolling only as far as it has to.
    ///
    /// The diagnostic rows sit below the fold: About gained its "What this is" / "How it
    /// works" sections (record-flow branch, owner request — About is the only
    /// Release-built screen that can tell a first-time user what this app is), and an
    /// offscreen `List` row is absent from the accessibility tree until it is scrolled
    /// into view. Without scrolling, a present row reads as MISSING rather than merely
    /// off-screen, which is exactly how this test once failed on CI.
    ///
    /// A single `swipeUp()` used to be enough. It is not a durable assumption: #118 §7
    /// added the Build row to this very section, pushing everything below it down by one
    /// row, and the next row added will do it again. So: directional swipes (never a
    /// fixed distance, so this survives other device sizes) repeated until the row
    /// appears (never a fixed COUNT, so this survives rows being added above it). Swipes
    /// past the end of the list are no-ops, so the bound only caps a genuine miss.
    ///
    /// Call these in top-to-bottom document order — the scroll only ever goes down, so a
    /// row checked after a lower one may have left the tree off the top by then.
    private func revealRow(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for _ in 0..<6 {
            if row.exists { return row }
            app.swipeUp()
        }
        _ = row.waitForExistence(timeout: 10)
        return row
    }

    func testAboutScreenShowsVersionEnvironmentAndSyncRows() {
        let app = launchApp()
        openPlace(app, "sidebar.about")

        XCTAssertTrue(revealRow(app, "about.version").exists, "version row missing")

        // #118 §7: the build TIME, moved here off the capture screen. A different fact
        // from Version — "1.0 (12)" is the same on every install of one build, while
        // "build 14: Sep 5, 10:26 AM PT" (#141) is what identifies the binary in your
        // hand after a wireless or TestFlight install.
        XCTAssertTrue(revealRow(app, "about.buildStamp").exists, "build stamp row missing")

        XCTAssertTrue(revealRow(app, "about.environment").exists, "environment row missing")

        XCTAssertTrue(revealRow(app, "about.sync.unavailable").exists,
                      "harness builds have no sync coordinator — the Sync section must "
                      + "degrade to its explanatory row, never hide")

        // T13: the Archive section comes after Sync in document order.
        XCTAssertTrue(revealRow(app, "about.export").exists, "export archive row missing")
    }
}
