import XCTest

/// Home (#108): the bookshelf landing, reachable via the sidebar this task — the
/// launch place itself does not change until Task 3.
final class HomeUITests: XCTestCase {

    private var testID: String!

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

    func testHomeShowsShelfAndNavigatesToJournal() {
        let app = launchApp()
        openPlace(app, "sidebar.home")
        XCTAssertTrue(app.buttons["home.newEntry"].firstMatch.waitForExistence(timeout: 15),
                      "Home never rendered")
        // The default minted journal shows as a face-out cover.
        let cover = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home.cover.'"))
            .firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 15), "no face-out cover on Home")
        cover.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["home.newEntry"].firstMatch.exists,
                       "tapping a cover did not leave Home")
    }

    func testNewEntryGoesToCapture() {
        let app = launchApp()
        openPlace(app, "sidebar.home")
        let newEntry = app.buttons["home.newEntry"].firstMatch
        XCTAssertTrue(newEntry.waitForExistence(timeout: 15))
        newEntry.tap()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15),
                      "New entry did not land on the capture screen")
    }
}
