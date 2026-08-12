import XCTest

/// T7 Mark Voices, issue #56, Task 6 — the mark-voices screen, end to end on a
/// simulator: tap a paragraph to flip its voice and see the detail screen render the
/// change, on both an already-marked entry and one with no markers at all.
///
/// Both fixtures come from `UITestVoiceMarkingSeed` (`RACONTE_UITEST_SEED_MARKER_ENTRY`,
/// same env gate the old marker-correction screen used — CI wiring untouched): the
/// marked entry (`captureID`) opens a `bn` voice at frame 0, the unmarked entry
/// (`unmarkedCaptureID`) has no `markers.jsonl` at all. `UITestEntrySeed`'s fixture is
/// deliberately `.none`-anchored (no frames), so it cannot exercise a real flip.
final class VoiceMarkingUITests: XCTestCase {

    private var testID: String!

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

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// `UITestVoiceMarkingSeed.seedIfRequested` seeds BOTH fixtures under the one env
    /// gate, so both show up in the capture screen's Recent section. The tiebreak in
    /// `LibraryScreenModel.mostRecentlyCaptured` (equal `capturedAt` -> larger
    /// `captureID` first) is what orders them: `captureID` ("…TQZ6") sorts before
    /// `unmarkedCaptureID` ("…TQZ2") — see `UITestVoiceMarkingSeed`'s doc comment — so
    /// row 0 is always the marked entry and row 1 is always the unmarked one.
    private func openSeededEntry(_ app: XCUIApplication, row index: Int) {
        let rows = app.descendants(matching: .any).matching(identifier: "capture.recentRow")
        let row = rows.element(boundBy: index)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded entry row \(index) never appeared")
        press(row)
    }

    private func openMarkVoices(_ app: XCUIApplication) {
        let markVoices = app.buttons["detail.markVoicesButton"].firstMatch
        XCTAssertTrue(markVoices.waitForExistence(timeout: 15), "no Mark voices affordance on the detail screen")
        press(markVoices)
    }

    private func tapParagraph(_ app: XCUIApplication, identifier: String) {
        let paragraph = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 15), "\(identifier) never appeared")
        press(paragraph)
    }

    func testTapFlipsAParagraphAndTheDetailViewShowsIt() throws {
        let app = launchApp()
        openSeededEntry(app, row: 0)
        openMarkVoices(app)

        // Header is always visible in marking mode.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceMarking.header")
            .firstMatch.waitForExistence(timeout: 15))

        // Seeded: a single paragraph, opened bn at frame 0.
        tapParagraph(app, identifier: "voiceMarking.paragraph.0.bn")

        // The tap is a drag that ends where it began -> a flip, not a range mark. The
        // fixture's one paragraph has no neighbour, so flipping it produces exactly
        // one paragraph, now ln.
        waitUntil(15, "the paragraph never flipped to ln") {
            app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.0.ln")
                .firstMatch.exists
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.0.bn")
            .firstMatch.exists, "the old bn id must not still be present")

        // Back exits the mode (system Back = Done, by design) and the detail screen
        // repaints with the new voice — VoiceOver's label carries it even with no
        // journal labels configured (falls back to the uppercased voice id). Task 6
        // review finding 2: with exactly one paragraph, this used to be unreachable —
        // iOS's accessibility tree merged the paragraph's own identifier/label into the
        // outer `detail.transcript.text` element — fixed in `EntryDetailView` via
        // `.accessibilityElement(children: .combine)` on the paragraph's `Group`, which
        // forces it to be its own independently-exposed element regardless of sibling
        // count.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let paragraph = app.descendants(matching: .any).matching(identifier: "detail.transcript.paragraph.0").firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 15), "the detail transcript paragraph never appeared")
        XCTAssertTrue(paragraph.label.hasPrefix("LN"),
                      "expected the detail paragraph's a11y label to begin \"LN\", got \(paragraph.label)")

        // Round trip: re-entering Mark Voices shows the flip survived, and both
        // screens' reads agree.
        openMarkVoices(app)
        waitUntil(15, "the flip did not survive the round trip through the detail screen") {
            app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.0.ln")
                .firstMatch.exists
        }

        XCTAssertFalse(app.alerts["Couldn’t save"].exists)
    }

    func testMarkVoicesOnAnUnmarkedEntryOffersMarkingAndWrites() throws {
        let app = launchApp()
        openSeededEntry(app, row: 1)
        openMarkVoices(app)

        // No markers at all -> the paragraph renders with no voice.
        tapParagraph(app, identifier: "voiceMarking.paragraph.0.none")

        // Flipping an unmarked paragraph writes an opener (bn) then a boundary (ln) at
        // the same frame — later-seq-wins makes the whole paragraph read as ln.
        waitUntil(15, "the unmarked paragraph never flipped to ln") {
            app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.0.ln")
                .firstMatch.exists
        }

        XCTAssertFalse(app.alerts["Couldn’t save"].exists)
    }
}
