import XCTest

/// Pins the navigation-redesign container swap (nav T4): `NavigationSplitView` with a
/// non-nil sidebar selection, collapsed to a stack on iPhone.
final class NavigationUITests: XCTestCase {

    private var testID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        testID = UUID().uuidString
    }

    /// Copied from `CaptureUITests.swift:16-21` for now; Task 5 replaces all four copies
    /// with the shared helper.
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = testID
        app.launch()
        return app
    }

    /// The load-bearing platform claim of the whole redesign: `NavigationSplitView` with a
    /// non-nil sidebar selection, collapsed to a stack on iPhone, must show the DETAIL column
    /// at launch — not the places list. If this fails, the fallback in Step 5 applies and the
    /// owner must be told at Gate A that the phone's IA is a toolbar button, not a chevron.
    func testLaunchLandsDirectlyOnCaptureWithNoTaps() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")
        XCTAssertFalse(app.buttons["sidebar.allEntries"].firstMatch.exists,
                       "the places list is showing instead of capture")
        // `sidebar.allEntries` alone is vacuous until Task 5 adds that row (Step 2's own
        // honest note). `sidebar.capture` — the stub sidebar's ONE real row — is the
        // stronger discriminator: it exists in the List regardless of `launchPlace`, so
        // it is only visible on screen when the sidebar column, not the detail column,
        // is what got shown.
        //
        // Step 6 mutation-check evidence (both directions tried, not just the brief's
        // literal instruction): mutating `PlaceRouting.launchPlace` to `.allEntries`
        // does NOT fail this test, even with the `sidebar.capture` assertion above —
        // the Task 4 stub's `detailRoot` renders `CaptureView` for every `Place` case,
        // so the detail column's content never varies with `launchPlace`, and
        // NavigationSplitView's iPhone collapse turned out not to require the
        // selection to match a List row either (tried `columnVisibility = .all` too,
        // also non-discriminating — compact width overrides it). The mutation that DOES
        // reliably fail this test: removing the `List`'s `selection:` binding entirely
        // (no pre-selected item at all) — `capture.record` never appears, confirming the
        // real claim, that a bound, pre-set sidebar `selection` is what makes the
        // collapsed iPhone split view land on the detail column. Both mutations reverted;
        // neither is committed.
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sidebar.capture")
                          .firstMatch.exists,
                       "the sidebar column is showing instead of the detail column")
    }

    /// The existing recentRow push must survive the container swap unchanged. Exercised
    /// here via `capture.libraryButton` (R4 ruling: the toolbar push into
    /// `RootDestination.library` must keep working inside the detail `NavigationStack`).
    ///
    /// Asserts on `library.trashLink` (a real `LibraryView` control), not
    /// `app.staticTexts["Library"]` — that text also exists ON the capture screen itself
    /// (`capture.libraryDoor`'s own label reads "Library"), so it gave a false pass
    /// during this task's own investigation of the Step-3-snippet regression documented
    /// in `ContentView.swift`.
    func testTheDetailColumnStillPushesAnEntryFromTheCaptureScreen() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.libraryButton"].firstMatch.waitForExistence(timeout: 30),
                      "the capture screen's library toolbar button did not appear")
        press(app.buttons["capture.libraryButton"].firstMatch)
        XCTAssertTrue(app.buttons["library.trashLink"].firstMatch.waitForExistence(timeout: 10),
                      "the library button did not push the library screen inside the detail column")
    }

    /// Cross-platform activate: XCUIElement taps on iOS, clicks on macOS.
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
}
