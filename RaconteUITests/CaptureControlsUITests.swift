import XCTest

/// Issue #53 — "need the controls to stay put" (owner, after a long reading in which the
/// voice switch left the screen entirely mid-entry, making voice marking impossible).
///
/// These measure RENDERED FRAMES, which is the only honest way to pin a layout fix. The
/// unit tests in `CaptureLayoutModelTests` pin which sections are visible per phase; they
/// cannot detect that a visible control has slid 188 pt down the screen, which is the
/// entire bug.
///
/// The defect's mechanism was structural: the record button, voice switch and paragraph
/// button sat INSIDE the page's one scroll view, below content that grows. So the
/// discriminating question is "can scrolling move them?" — under the old layout, yes;
/// under the fixed layout, never, because they are no longer inside any scroll view.
final class CaptureControlsUITests: XCTestCase {

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

    /// Frames are compared with a small tolerance: sub-point rendering differences are not
    /// what this test is about. The bug moved controls by ~188 pt.
    private func assertFrame(_ element: XCUIElement,
                             equals expected: CGRect,
                             _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = element.frame
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1.0,
                       "\(what): moved vertically, \(expected.minY) → \(actual.minY)",
                       file: file, line: line)
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1.0,
                       "\(what): moved horizontally, \(expected.minX) → \(actual.minX)",
                       file: file, line: line)
    }

    // MARK: - #53

    /// The control bar must not be reachable by scrolling. Under the old single-ScrollView
    /// layout the record button scrolled with the page like any other content; it is now
    /// outside every scroll view, so a scroll gesture cannot touch it.
    func testScrollingThePageDoesNotMoveTheRecordButton() {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        let before = record.frame
        XCTAssertGreaterThan(before.height, 0, "record button has no measurable frame")

        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()

        assertFrame(record, equals: before, "record button after scrolling the page")
    }

    /// The transition into recording is where the layout changes most (the Two-voices
    /// toggle and the Recent list are removed, and the transcript is unleashed). The bar
    /// must not shift as a result — a control that jumps at the moment recording starts is
    /// the same defect wearing a different hat.
    func testRecordButtonDoesNotMoveWhenRecordingStarts() {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        let idleFrame = record.frame

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }

        assertFrame(record, equals: idleFrame, "record button between idle and recording")

        // Leave the capture finalized rather than killing the app mid-recording.
        press(record)
        waitUntil(20, "never left recording") { record.label != "Stop" }
    }

    /// The specific control the owner lost. It only exists while recording (and only with
    /// two-voice mode on), so this pins that once shown it holds still — and, critically,
    /// that it remains hittable, which "scrolled off the bottom of the screen" is not.
    func testVoiceSwitchStaysPutAndHittableWhileRecording() throws {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        let multiVoice = app.switches["capture.multiVoiceToggle"].firstMatch
        guard multiVoice.waitForExistence(timeout: 10) else {
            throw XCTSkip("two-voices toggle not present in this configuration")
        }
        if (multiVoice.value as? String) != "1" { press(multiVoice) }

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }

        let voiceSwitch = app.buttons["capture.voiceSwitch"].firstMatch
        XCTAssertTrue(voiceSwitch.waitForExistence(timeout: 10),
                      "voice switch missing while recording with two voices on")

        let before = voiceSwitch.frame
        XCTAssertTrue(voiceSwitch.isHittable, "voice switch is not hittable when it appears")

        // Whatever the page does, the switch is not part of it. Since approach 2
        // (2026-08-16), no scroll view exists at all while recording until the
        // transcript has content — correctly, per the owner's "I would rather have
        // none [scrollable sections]" — so give the synthetic engine a moment to
        // produce some before swiping; its absence this early is not a failure.
        let scroll = app.scrollViews.firstMatch
        if scroll.waitForExistence(timeout: 5) { scroll.swipeUp() }
        Thread.sleep(forTimeInterval: 1.5)   // let synthetic audio and any layout settle

        assertFrame(voiceSwitch, equals: before, "voice switch during recording")
        XCTAssertTrue(voiceSwitch.isHittable,
                      "voice switch stopped being hittable during recording — this is the "
                      + "#53 report: it had scrolled out of the viewport")

        press(record)
        waitUntil(20, "never left recording") { record.label != "Stop" }
    }

    // MARK: - Approach 2, 2026-08-16 IA discussion
    //
    // Owner: "there are three sections on the iPhone screen... the fact that there's two
    // scrollable sections above [the bar] doesn't make any sense at all to me... I would
    // rather have none, especially during the recording." Before this, the setup band
    // (journal + backdate) was squeezed into a fixed-height box and forced to scroll
    // internally — a second scroll view stacked above the transcript's own. These pin the
    // rendered consequence: only the transcript should scroll while recording, and
    // backdating must stay reachable through the compact summary that replaces it.

    /// The discriminating count. `CaptureLayoutModelTests` pins the visibility rule; only
    /// this can catch a `ScrollView` still wrapping the setup band even if its content
    /// happens to fit without scrolling — the old bug was the scroll view existing, not
    /// merely content overflowing it.
    func testOnlyOneScrollableRegionExistsWhileRecording() {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }

        let summary = app.buttons["capture.backdateSummary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10),
                      "compact backdate summary missing while recording")
        XCTAssertFalse(app.switches["capture.backdateToggle"].firstMatch.exists,
                       "the full inline backdate field is still on screen while recording — "
                       + "it is exactly the content that forced a second scroll view")

        Thread.sleep(forTimeInterval: 2)   // let the synthetic engine grow the transcript
        XCTAssertLessThanOrEqual(app.scrollViews.count, 1,
                                 "more than one scrollable region above the control bar "
                                 + "while recording")

        press(record)
        waitUntil(20, "never left recording") { record.label != "Stop" }
    }

    /// Backdating is bounded content, not removed capability — the compact summary must
    /// still open the real, write-through editor, and opening it must not disturb the
    /// recording underneath.
    func testTappingTheCompactBackdateSummaryOpensTheEditorWithoutInterruptingTheRecording() {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }

        let summary = app.buttons["capture.backdateSummary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "compact backdate summary missing")
        press(summary)

        let toggle = app.switches["capture.backdateToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "tapping the compact summary did not open the backdate editor")

        let done = app.buttons["capture.backdateSheetDone"].firstMatch
        if done.waitForExistence(timeout: 5) { press(done) }
        XCTAssertEqual(record.label, "Stop",
                       "opening the backdate sheet interrupted the recording")

        press(record)
        waitUntil(20, "never left recording") { record.label != "Stop" }
    }

    // MARK: - The post-stop receipt (owner smoke, 2026-08-15)

    /// The stranded-transcript bug, pinned end to end.
    ///
    /// Owner's report, with a screenshot: after Done, the finished transcript stayed on
    /// screen as loose text below a sliced Recent list, unheaded and untappable — "a
    /// really messed up user experience that has not been engineering correctly". The text
    /// was held deliberately (`LiveTranscriptionCoordinator.lastCompletedText` survives so
    /// the panel doesn't blank the instant you stop) and nothing ever cleared it.
    ///
    /// So the discriminating assertion is not "a receipt appeared" — it is that the LIVE
    /// transcript band is gone at the same time. A receipt drawn over a band that is still
    /// there would satisfy a weaker test and leave the defect in place.
    func testStoppingRaisesAReceiptAndClearsTheLiveTranscript() {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)   // let the synthetic engine produce transcript
        press(record)

        let dismiss = app.buttons["capture.receipt.dismiss"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 30),
                      "no receipt after a capture finished")
        XCTAssertTrue(app.staticTexts["capture.receipt.date"].firstMatch.exists,
                      "the receipt does not say which entry it is about")
        XCTAssertFalse(app.descendants(matching: .any)
                        .matching(identifier: "capture.transcript").firstMatch.exists,
                       "the live transcript band is STILL on screen behind the receipt — "
                       + "this is the stranded-text bug the receipt exists to fix")

        // And dismissing returns to a landing screen with neither the receipt nor the
        // stranded text — the state the owner should have been getting all along.
        press(dismiss)
        waitUntil(10, "receipt never dismissed") { !dismiss.exists }
        XCTAssertFalse(app.descendants(matching: .any)
                        .matching(identifier: "capture.transcript").firstMatch.exists,
                       "the finished transcript came back after dismissing the receipt")
        XCTAssertTrue(app.buttons["capture.libraryDoor"].firstMatch.exists,
                      "the landing screen did not come back")
    }

    /// One entry on the landing screen, and a full-width route to the rest.
    ///
    /// Owner: "I'd rather not have too many things scrolling around. Would be better just
    /// to see the most recent one and then have an obvious link to the Library. That's not
    /// just up in the top right."
    func testLandingScreenShowsOneEntryAndAProminentLibraryRoute() {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        let door = app.buttons["capture.libraryDoor"].firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 10), "no library route on the landing screen")
        XCTAssertTrue(door.isHittable, "the library route is not reachable without scrolling")

        // The old top-right "See all" link is gone, not merely moved: leaving both would
        // be two routes to the same place, one of them the one he objected to.
        XCTAssertFalse(app.descendants(matching: .any)
                        .matching(identifier: "capture.seeAllLink").firstMatch.exists,
                       "the top-right See all link is still there")

        // Record twice; the landing screen must still show exactly one entry.
        for _ in 1...2 {
            waitUntil(15, "record button not ready") { record.label == "Record" && record.isEnabled }
            press(record)
            waitUntil(10, "never entered recording") { record.label == "Stop" }
            Thread.sleep(forTimeInterval: 1)
            press(record)
            let dismiss = app.buttons["capture.receipt.dismiss"].firstMatch
            XCTAssertTrue(dismiss.waitForExistence(timeout: 30), "no receipt")
            press(dismiss)
        }

        waitUntil(15, "landing screen never showed the last entry") {
            app.descendants(matching: .any).matching(identifier: "capture.recentRow").count >= 1
        }
        XCTAssertEqual(app.descendants(matching: .any)
                        .matching(identifier: "capture.recentRow").count, 1,
                       "the landing screen is listing more than the single most recent entry")
    }

    // MARK: - The ≤ ⅓ ruling (owner smoke, 2026-08-15)

    /// #53's fix kept the controls still and every one of the tests above passed on a bar
    /// that took 331 pt — 38% of the owner's screen. He rejected it: "the bottom half
    /// stays put but it's so big I can't even see the full backdate interface let alone
    /// Two voices and Recents." The ruling is a proportion, at most a third, and no test
    /// in this file encoded a proportion — which is exactly why it shipped.
    ///
    /// Measured from the elapsed timer — the topmost element of the topmost row — down to
    /// the bottom of the window. Two known inaccuracies, in opposite directions: it
    /// excludes the bar's own top padding (~12 pt), and it includes the bottom safe-area
    /// inset the bar sits above (~34 pt on this device). Net, it over-reports slightly,
    /// which is the safe direction for a ceiling. Measured 190 pt of 874 (22%) against the
    /// 291 pt ceiling; the rejected bar would measure ~353 pt and fail.
    ///
    /// Anchoring on the clock rather than the record button is deliberate: anything that
    /// makes a row above the button taller pushes the clock UP, so this catches a bar that
    /// grew for a reason nobody predicted, not just one whose constants were edited.
    private func assertBarFitsWithinAThird(_ app: XCUIApplication,
                                           _ phase: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let clock = app.staticTexts["capture.clock"].firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 10),
                      "elapsed timer not found — cannot locate the top of the control bar",
                      file: file, line: line)

        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(screen.height, 0, "window has no measurable frame",
                             file: file, line: line)

        let barHeight = screen.maxY - clock.frame.minY
        let ceiling = screen.height / 3

        XCTAssertLessThanOrEqual(
            barHeight, ceiling,
            "\(phase): the control bar measures \(Int(barHeight)) pt of a "
            + "\(Int(screen.height)) pt screen "
            + "(\(Int((barHeight / screen.height * 100).rounded()))%) — the ruling is a "
            + "third at most, i.e. \(Int(ceiling)) pt",
            file: file, line: line)
    }

    /// Idle is what the owner sees before he starts reading, and the state in which the
    /// backdate field, Two voices and Recent all have to be reachable without scrolling.
    func testControlBarTakesAtMostAThirdOfTheScreenWhenIdle() {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        assertBarFitsWithinAThird(app, "idle")
    }

    /// And while recording — the state the mockup was drawn in, and the state where the
    /// bar is at its fullest (live timer, marks shown, Done reserved).
    func testControlBarTakesAtMostAThirdOfTheScreenWhileRecording() {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        let multiVoice = app.switches["capture.multiVoiceToggle"].firstMatch
        if multiVoice.waitForExistence(timeout: 10), (multiVoice.value as? String) != "1" {
            press(multiVoice)
        }

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }

        assertBarFitsWithinAThird(app, "recording")

        press(record)
        waitUntil(20, "never left recording") { record.label != "Stop" }
    }

    /// The horizontal half of "the controls stay put".
    ///
    /// The marks flank the record button with equal spacers, so the record button's
    /// centring depends on the two side slots staying the same width. The voice button's
    /// label changes on every tap — "BN" → "LN", or a journal's own labels, which can be
    /// any length — so intrinsic widths would walk the Stop button sideways mid-reading.
    /// This is #53's failure mode rotated 90°, and nothing else in the suite would see it.
    func testMarkingAVoiceDoesNotMoveTheRecordButtonSideways() throws {
        let app = launchApp()
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        let multiVoice = app.switches["capture.multiVoiceToggle"].firstMatch
        guard multiVoice.waitForExistence(timeout: 10) else {
            throw XCTSkip("two-voices toggle not present in this configuration")
        }
        if (multiVoice.value as? String) != "1" { press(multiVoice) }

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }

        let voiceSwitch = app.buttons["capture.voiceSwitch"].firstMatch
        XCTAssertTrue(voiceSwitch.waitForExistence(timeout: 10), "voice switch missing")

        let recordBefore = record.frame
        let switchBefore = voiceSwitch.frame
        let startingLabel = voiceSwitch.label

        press(voiceSwitch)
        waitUntil(10, "voice never flipped") { voiceSwitch.label != startingLabel }

        assertFrame(record, equals: recordBefore, "record button after a voice mark")
        assertFrame(voiceSwitch, equals: switchBefore, "voice switch after a voice mark")

        press(record)
        waitUntil(20, "never left recording") { record.label != "Stop" }
    }
}
