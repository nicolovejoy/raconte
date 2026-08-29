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

    /// Polls, like `VoiceMarkingUITests`'s helper of the same name — no shared helper
    /// file exists yet for this small a duplication.
    private func waitUntil(_ timeout: TimeInterval = 20, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// The transcript's own accessibility label. Two shapes, per `EntryDetailView
    /// .transcriptDisplay`: an entry with usable markers renders `.attributed`, one
    /// `detail.transcript.paragraph.<i>` per paragraph (this is the seeded `captureID`
    /// fixture — voice `bn`); an entry with NO usable markers at all — the seeded
    /// `unmarkedCaptureID` fixture — attributes to `nil` paragraphs
    /// (`EntryTranscriptLoader.attributedParagraphs` returns `nil` when `snapped` is
    /// empty) and falls to `.plain(text)`, identifier `detail.transcript.text` directly
    /// on the `Text` itself. The outer `.attributed` container ALSO carries
    /// `detail.transcript.text` but as `.accessibilityElement(children: .contain)`
    /// (Task 6 review Important 2) — it deliberately keeps children separately exposed
    /// and carries no synthesized label of its own, so paragraph.0 must be tried first.
    /// Non-asserting: `nil` while neither shape has (re)appeared yet, for use inside
    /// `waitUntil`'s poll — asserting here would abort the test on the FIRST empty poll
    /// rather than actually waiting out the transition.
    private func currentTranscriptLabel(_ app: XCUIApplication) -> String? {
        let paragraph = app.descendants(matching: .any)
            .matching(identifier: "detail.transcript.paragraph.0").firstMatch
        if paragraph.exists { return paragraph.label }
        let plain = app.descendants(matching: .any)
            .matching(identifier: "detail.transcript.text").firstMatch
        return plain.exists ? plain.label : nil
    }

    private func transcriptParagraphLabel(_ app: XCUIApplication) -> String {
        waitUntil(15, "no transcript element (paragraph or plain) ever appeared") {
            currentTranscriptLabel(app) != nil
        }
        return currentTranscriptLabel(app) ?? ""
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

    /// #103: the owner reported that after finishing one entry and moving to the next,
    /// the previous entry's transcript still showed. PR #111 pinned `EntryDetailView`'s
    /// identity to the entry with `.id(captureID)` in `ContentView`'s
    /// `navigationDestination` — this is the regression test for that fix, driven
    /// through the paging chevron rather than the swipe gesture (same reasoning as the
    /// test above: a sim swipe pins nothing about the device).
    ///
    /// The marker seed's row 0 (`captureID`, voice `bn`, words "one two three") and row 1
    /// (`unmarkedCaptureID`, no voice, words "alpha beta gamma" — deliberately DISTINCT
    /// from row 0's, `UITestVoiceMarkingSeed.unmarkedWords`) are adjacent in paging order
    /// (same deterministic captureID-descending tiebreak the class doc above already
    /// relies on), so a stale-transcript bug is directly observable: without the `.id`
    /// pin, paging from row 0 to row 1 would leave `detail.transcript.paragraph.0`
    /// showing row 0's words.
    func testTranscriptDoesNotLingerWhilePagingForward() {
        let app = launchApp()
        openPlace(app, "sidebar.allEntries")

        let rows = app.descendants(matching: .any).matching(identifier: "library.entryLink")
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 20))
        rows.element(boundBy: 0).tap()

        let firstLabel = transcriptParagraphLabel(app)
        XCTAssertTrue(firstLabel.contains("one"), "row 0's transcript should read \"one two three\", got \(firstLabel)")

        let next = button(app, "detail.nextEntry")
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()

        waitUntil(15, "the transcript still shows row 0's words after paging to row 1") {
            let label = currentTranscriptLabel(app)
            return label != nil && !label!.contains("one")
        }
        let secondLabel = transcriptParagraphLabel(app)
        XCTAssertNotEqual(firstLabel, secondLabel, "paging must not leave the previous entry's transcript showing")
        XCTAssertTrue(secondLabel.contains("alpha"), "row 1's transcript should read \"alpha beta gamma\", got \(secondLabel)")
    }

    /// The #103 report's likely path: not the paging chevron, but list -> open entry ->
    /// back -> open a DIFFERENT entry. This exercises the same `navigationDestination`
    /// case as the paging test above (there is only one — `.entry(let captureID)` in
    /// `ContentView.swift` — so both routes are covered by the same `.id(captureID)`
    /// pin), but through a fresh push rather than `onPage`'s in-place path replacement,
    /// which is worth pinning independently since it is a structurally different
    /// SwiftUI code path (a full pop + a new push, not a path-element replace). Back
    /// navigation goes through `openPlace(app, "sidebar.allEntries")`, not a hard-coded
    /// nav-bar tap — see `UITestNavigation.swift`'s doc comment for why that matters on
    /// iPhone's collapsed split view vs. Mac/iPad's two-column layout.
    func testTranscriptDoesNotLingerAfterListBackAndReselect() {
        let app = launchApp()
        openPlace(app, "sidebar.allEntries")

        let rows = app.descendants(matching: .any).matching(identifier: "library.entryLink")
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 20))
        rows.element(boundBy: 0).tap()

        let firstLabel = transcriptParagraphLabel(app)
        XCTAssertTrue(firstLabel.contains("one"), "row 0's transcript should read \"one two three\", got \(firstLabel)")

        // Back to the list — through `openPlace`, not a hard-coded nav-bar tap: it
        // already handles the iPhone-collapsed-vs-Mac/iPad-both-columns difference
        // (back-button vs. straight tap) in one place (project convention).
        openPlace(app, "sidebar.allEntries")

        let rowsAgain = app.descendants(matching: .any).matching(identifier: "library.entryLink")
        XCTAssertTrue(rowsAgain.element(boundBy: 1).waitForExistence(timeout: 20),
                      "back to the list should show the same rows")
        rowsAgain.element(boundBy: 1).tap()

        waitUntil(15, "the transcript still shows row 0's words after selecting row 1") {
            let label = currentTranscriptLabel(app)
            return label != nil && !label!.contains("one")
        }
        let secondLabel = transcriptParagraphLabel(app)
        XCTAssertNotEqual(firstLabel, secondLabel,
                          "re-selecting a different entry must not leave the previous one's transcript showing")
        XCTAssertTrue(secondLabel.contains("alpha"), "row 1's transcript should read \"alpha beta gamma\", got \(secondLabel)")
    }
}
