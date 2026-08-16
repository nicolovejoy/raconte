import XCTest

/// T7 Mark Voices, issue #56, Task 6 — the mark-voices screen, end to end on a
/// simulator: tap a paragraph to flip its voice and see the detail screen render the
/// change, on both an already-marked entry and one with no markers at all.
///
/// All three fixtures come from `UITestVoiceMarkingSeed` (`RACONTE_UITEST_SEED_MARKER_ENTRY`,
/// same env gate the old marker-correction screen used — CI wiring untouched): the
/// marked entry (`captureID`) opens a `bn` voice at frame 0, the unmarked entry
/// (`unmarkedCaptureID`) has no `markers.jsonl` at all, and `mergeCaptureID` (six words,
/// two voices) exists for the drag test below. `UITestEntrySeed`'s fixture is
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

    /// Open one of the seeded fixtures, **from the library**.
    ///
    /// `UITestVoiceMarkingSeed.seedIfRequested` seeds BOTH fixtures under the one env
    /// gate. The tiebreak in `LibraryScreenModel.mostRecentlyCaptured` (equal `capturedAt`
    /// -> larger `captureID` first) is what orders them: `captureID` ("…TQZ6") sorts
    /// before `unmarkedCaptureID` ("…TQZ2") — see `UITestVoiceMarkingSeed`'s doc comment —
    /// so row 0 is always the marked entry and row 1 the unmarked one.
    ///
    /// This used to read those rows off the capture screen's Recent section. Since
    /// 2026-08-15 that screen shows only the single most recent entry (owner: "just see
    /// the most recent one and then have an obvious link to the Library"), so row 1 is not
    /// there at all. The library lists every entry in the same newest-first order, so the
    /// ordering note above still holds.
    ///
    /// Queried by `library.entryLink` — the identifier on the `NavigationLink` itself. The
    /// row's own `library.row` is NOT queryable: the link merges its label's children into
    /// one accessibility element, the same flattening `capture.recentRow` exists to work
    /// around.
    private func openSeededEntry(_ app: XCUIApplication, row index: Int) {
        let door = app.buttons["capture.libraryDoor"].firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 20), "library route never appeared")
        press(door)

        let rows = app.descendants(matching: .any).matching(identifier: "library.entryLink")
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

    /// Gate-review fix #1 — the frames-identity fix at `VoiceMarkingParagraphBlock`'s
    /// `.id(row.tokens.map(\.id))` (forces SwiftUI to rebuild the block, and reset its
    /// `@State frames` rects, whenever the token set at a row index changes) had ZERO
    /// automated coverage: deleting that line broke nothing in 1176 unit + 2 UI tests,
    /// because neither existing UI test ever drags — both only tap-to-flip a paragraph
    /// that stays a single row for the whole test. This is the only path that can
    /// observe stale `frames`: flip paragraph 0 (bn, words "one two three") into
    /// paragraph 1's voice (ln, "four five six") to force a MERGE into one 6-word row —
    /// the merge changes row 0's token set out from under any `@State` SwiftUI decides
    /// to keep — then drag across a range INSIDE that merged row and confirm only the
    /// dragged words changed voice. Fixture: `UITestVoiceMarkingSeed.mergeCaptureID`,
    /// recent row 2 (its captureID tail sorts last of the three seeded entries).
    func testDragMarksARangeWithinAMergedBlock() throws {
        let app = launchApp()
        openSeededEntry(app, row: 2)
        openMarkVoices(app)

        // Precondition: two paragraphs on open, bn then ln — checked BEFORE the flip,
        // since the flip below is exactly what merges them into one.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.1.ln")
            .firstMatch.waitForExistence(timeout: 15), "precondition: paragraph 1 must already be ln")
        tapParagraph(app, identifier: "voiceMarking.paragraph.0.bn")

        // The tap just now flipped paragraph 0 from bn toward ln — paragraph 1 was
        // ALREADY ln, so this merges them into one 6-word row rather than leaving two.
        waitUntil(15, "flipping paragraph 0 into paragraph 1's voice never merged them into one row") {
            let merged = app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.0.ln")
                .firstMatch
            return merged.exists
                && !app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.1.ln")
                    .firstMatch.exists
        }
        // Every token in the row is its OWN accessibility element sharing the block's
        // identifier (`voiceMarking.paragraph.0.ln` × 6, one per word) — `.firstMatch`
        // above is just "one", a ~30pt-wide element, so a coordinate drag confined to
        // ITS bounds never leaves the first word and reads as a tap, not a range. Anchor
        // the drag on two DISTINCT words by their own text instead — "three" (index 2,
        // last word of the pre-merge paragraph 0) to "four" (index 3, first word of the
        // pre-merge paragraph 1) — which by construction spans the merge seam.
        let three = app.staticTexts["three"].firstMatch
        let four = app.staticTexts["four"].firstMatch
        XCTAssertTrue(three.waitForExistence(timeout: 15), "the merged row's \"three\" token never appeared")
        XCTAssertTrue(four.exists, "the merged row's \"four\" token never appeared")

        let start = three.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = four.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: end)

        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mark as'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "no confirmation dialog appeared after the drag")
        press(confirm)

        // Only the dragged range changed: the merged 6-word ln row must now be THREE
        // rows — ln, bn (the drag), ln — never two (drag didn't register as a range)
        // and never more than three (the drag bled past its own endpoints).
        waitUntil(15, "the drag never produced a 3-row ln/bn/ln split") {
            app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.0.ln").firstMatch.exists
                && app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.1.bn")
                    .firstMatch.exists
                && app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.2.ln")
                    .firstMatch.exists
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "voiceMarking.paragraph.3.ln")
            .firstMatch.exists, "must be exactly 3 rows — a 4th would mean the drag bled onto more words")

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
