import XCTest

/// #194 Task 9: the Search place end to end — type, see the seeded entry, open it; a query
/// with no hit says so; the journal chip scopes the list.
///
/// The entry comes from `UITestEntrySeed` (`RACONTE_UITEST_SEED_ENTRY`): one unfiled capture
/// whose canonical text is "the machine heard these words". It is findable only once the
/// launch scan's reconcile has indexed it, and the screen re-queries when that lands, so
/// every wait for a result is 15 s.
///
/// The journal chip starts on the current journal, and a fresh harness container mints one
/// ("Journal") at launch. The seeded entry is unfiled, so a test that expects to find it picks
/// All journals first rather than depend on whether that seed has landed yet.
final class SearchUITests: XCTestCase {

    /// `UITestEntrySeed.captureID` (Raconte/Capture/Debug/UITestSupport.swift). The UI test
    /// target cannot import the app target, so the literal is copied, as the other UI tests do.
    private let seededCaptureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = UUID().uuidString
        app.launchEnvironment["RACONTE_UITEST_SEED_ENTRY"] = "1"
        app.launch()
        return app
    }

    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the Search place has no search field")
        return field
    }

    private func seededResult(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["search.result.\(seededCaptureID)"]
    }

    /// Opens the journal chip's menu and picks the item `item` finds.
    private func pickJournal(_ app: XCUIApplication, _ item: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        let chip = app.buttons["search.chip.journal"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "no journal chip", file: file, line: line)
        chip.tap()
        XCTAssertTrue(item.waitForExistence(timeout: 15), "the journal chip's menu lacks the item",
                      file: file, line: line)
        item.tap()
    }

    private func allJournalsItem(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["search.chip.journal.all"].firstMatch
    }

    func testTypingFindsTheSeededEntryAndOpensIt() {
        let app = launchApp()
        openPlace(app, "sidebar.search")
        let field = searchField(app)
        pickJournal(app, allJournalsItem(app))

        field.tap()
        field.typeText("heard")
        let result = seededResult(app)
        XCTAssertTrue(result.waitForExistence(timeout: 15), "the seeded entry was never listed")
        XCTAssertTrue(result.label.contains("heard"), "the row's label carries the snippet: \(result.label)")

        result.tap()
        XCTAssertTrue(app.staticTexts["detail.transcript.text"].waitForExistence(timeout: 15),
                      "tapping the result did not open the entry")
    }

    /// "No matches" only once the index has answered the text in the field, so this wait is
    /// satisfiable by an answered query and nothing else.
    func testNoMatchesState() {
        let app = launchApp()
        openPlace(app, "sidebar.search")
        let field = searchField(app)
        pickJournal(app, allJournalsItem(app))

        field.tap()
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["search.noMatches"].waitForExistence(timeout: 15),
                      "a query with no hit never said No matches")
        XCTAssertFalse(seededResult(app).exists)
    }

    /// The seeded entry is unfiled, so any real journal scopes it out; All journals brings it
    /// back. The sidebar's journal row is waited for first, so the chip's menu has the
    /// launch-minted journal in it when it opens.
    func testJournalChipScopesOut() {
        let app = launchApp()
        XCTAssertTrue(firstJournalRow(app).waitForExistence(timeout: 15), "no journal was ever listed")
        openPlace(app, "sidebar.search")
        let field = searchField(app)
        pickJournal(app, allJournalsItem(app))

        field.tap()
        field.typeText("heard")
        let result = seededResult(app)
        XCTAssertTrue(result.waitForExistence(timeout: 15), "the seeded entry was never listed")

        let journalItem = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'search.chip.journal.item.'"))
            .firstMatch
        pickJournal(app, journalItem)
        XCTAssertTrue(result.waitForNonExistence(timeout: 15), "a journal the entry is not in still lists it")
        XCTAssertTrue(app.staticTexts["search.noMatches"].waitForExistence(timeout: 15))

        pickJournal(app, allJournalsItem(app))
        XCTAssertTrue(result.waitForExistence(timeout: 15), "All journals did not bring the entry back")
    }
}
