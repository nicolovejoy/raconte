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

        // Whatever the page does, the switch is not part of it.
        app.scrollViews.firstMatch.swipeUp()
        Thread.sleep(forTimeInterval: 1.5)   // let synthetic audio and any layout settle

        assertFrame(voiceSwitch, equals: before, "voice switch during recording")
        XCTAssertTrue(voiceSwitch.isHittable,
                      "voice switch stopped being hittable during recording — this is the "
                      + "#53 report: it had scrolled out of the viewport")

        press(record)
        waitUntil(20, "never left recording") { record.label != "Stop" }
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
