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
}
