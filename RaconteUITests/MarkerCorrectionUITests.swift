import XCTest

/// T7 Task 6.5 — marker correction as its own mode, end to end on a simulator: retract
/// a mis-tapped marker, correct a voice at an existing boundary, and add a boundary by
/// picking a word — the three cases the brief names.
///
/// The entry comes from `UITestMarkerCorrectionSeed` (`RACONTE_UITEST_SEED_MARKER_ENTRY`)
/// rather than `UITestEntrySeed`: the editor's fixture is deliberately `.none`-anchored
/// (no frames at all), so it cannot offer a single placeable word — this fixture has
/// three real frame-bounded spans plus two pre-existing raw taps (a `.voice` opener and
/// a `.paragraph` mid-way), which is what makes all three cases reachable in one entry.
final class MarkerCorrectionUITests: XCTestCase {

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

    private func openSeededEntry(_ app: XCUIApplication) {
        let recentRow = app.descendants(matching: .any)
            .matching(identifier: "capture.recentRow").firstMatch
        XCTAssertTrue(recentRow.waitForExistence(timeout: 20), "seeded entry never appeared")
        press(recentRow)
    }

    func testRetractVoiceCorrectionAndBoundaryAddByWord() throws {
        let app = launchApp()
        openSeededEntry(app)

        let correctMarkers = app.buttons["detail.correctMarkersButton"].firstMatch
        XCTAssertTrue(correctMarkers.waitForExistence(timeout: 15), "no Correct markers affordance on the detail screen")
        press(correctMarkers)

        // Seeded: seq 0 is a .voice "bn" opener, seq 1 is a .paragraph mid-way — both
        // must be present before anything is touched.
        let retractParagraph = app.buttons["markerCorrection.retract.1"].firstMatch
        XCTAssertTrue(retractParagraph.waitForExistence(timeout: 15), "the seeded paragraph marker never appeared")
        let correctToLN = app.buttons["markerCorrection.correctVoice.ln.0"].firstMatch
        XCTAssertTrue(correctToLN.waitForExistence(timeout: 10), "the seeded voice marker's correction button never appeared")

        // Case 1: retract the mis-tapped paragraph marker.
        press(retractParagraph)
        waitUntil(15, "the retracted marker's row never disappeared") {
            !app.buttons["markerCorrection.retract.1"].firstMatch.exists
        }

        // Case 2: correct the remaining voice marker from bn to ln.
        press(app.buttons["markerCorrection.correctVoice.ln.0"].firstMatch)
        waitUntil(15, "the corrected voice never showed as ln") {
            app.staticTexts["Voice: ln"].firstMatch.exists
        }
        // Having flipped to ln, the offered correction is now the OTHER voice (bn) —
        // proof the screen re-read the real record, not a locally patched copy.
        XCTAssertTrue(app.buttons["markerCorrection.correctVoice.bn.0"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["markerCorrection.correctVoice.ln.0"].firstMatch.exists)

        // Case 3: add a boundary by picking "three" — the third word, which has no
        // marker at all yet, and is the discriminating fixture: only its OWN span
        // start (not "one"'s, the group's start) is the correct anchor.
        let wordThree = app.buttons["markerCorrection.word.2"].firstMatch
        XCTAssertTrue(wordThree.waitForExistence(timeout: 10), "the third seeded word never appeared")
        XCTAssertEqual(wordThree.label, "three")
        press(wordThree)

        // A successful boundary-add appends a NEW `.correctionBoundaryAdd` record —
        // raw taps stay immutable (locked decision 5) — which `MarkerCorrections
        // .effectiveMarkers` folds into an effective `.paragraph` marker for
        // rendering. So the boundary list grows back to one row (the retract above
        // emptied it to zero paragraph rows, leaving only the voice row).
        waitUntil(15, "the boundary-add never produced a new row") {
            app.staticTexts["Paragraph break"].firstMatch.exists
        }

        // No error alert at any point — every action here should have succeeded.
        XCTAssertFalse(app.alerts["Couldn’t save"].exists)
    }
}
