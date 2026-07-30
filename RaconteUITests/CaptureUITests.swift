import XCTest

/// Simulator/desktop UI flows over the synthetic-engine harness (UITestSupport.swift):
/// no microphone, no TCC prompts, real disk + real AAC finalize underneath. Each test
/// mints a fresh `RACONTE_UITEST_ID`, which keys the captures root inside the app
/// container; relaunching with the same id sees the same disk (recovery tests).
final class CaptureUITests: XCTestCase {

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

    /// Cross-platform activate: XCUIElement taps on iOS, clicks on macOS.
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func recordButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["capture.record"].firstMatch
    }

    private func finishedRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(identifier: "finished.duration")
    }

    private func recoveryBanner(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["recovery.title"].firstMatch
    }

    /// Poll until `predicate()` or fail. XCTest's expectation API can't watch query
    /// counts, so a simple loop keeps these tests readable.
    private func waitUntil(_ timeout: TimeInterval = 20, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    // MARK: doc test 1/28 (flow) — record → stop → a playable entry appears

    func testRecordStopProducesFinishedEntry() {
        let app = launchApp()
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)                       // Record → recording
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)    // let synthetic audio flow
        press(record)                       // Stop → flush → captured → finalize

        waitUntil(30, "finished entry never appeared") { self.finishedRows(app).count == 1 }
        waitUntil(15, "screen never reset to idle") { record.label == "Record" }
    }

    // MARK: doc tests 6/30 (flow) — kill mid-recording → relaunch recovers

    func testTerminateMidRecordingRecoversOnRelaunch() {
        let app = launchApp()
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15))

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)    // ~2 s of synthetic audio on disk
        app.terminate()                     // kill mid-recording, no clean stop

        let relaunched = launchApp()        // same RACONTE_UITEST_ID → same disk
        let banner = recoveryBanner(relaunched)
        XCTAssertTrue(banner.waitForExistence(timeout: 20),
                      "no recovery banner after mid-recording kill")
        XCTAssertTrue(banner.label.hasPrefix("Recovered recording:"))
    }

    // MARK: doc test 7 (flow) — idle relaunch: no spurious banner, entry kept

    func testIdleRelaunchShowsNoBannerAndKeepsEntry() {
        let app = launchApp()
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15))

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 1)
        press(record)
        waitUntil(30, "finished entry never appeared") { self.finishedRows(app).count == 1 }
        app.terminate()                     // idle now — a clean-ish quit

        let relaunched = launchApp()
        let rows = finishedRows(relaunched)
        waitUntil(20, "entry lost across relaunch") { rows.count == 1 }
        XCTAssertFalse(recoveryBanner(relaunched).exists,
                       "spurious recovery banner on idle relaunch")
    }

    // MARK: doc test 22 (flow) — repeated record/stop cycles, one entry each

    func testRepeatedRecordStopCyclesProduceSeparateEntries() {
        let app = launchApp()
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15))

        for cycle in 1...3 {
            waitUntil(15, "cycle \(cycle): record button not ready") {
                record.label == "Record" && record.isEnabled
            }
            press(record)
            waitUntil(10, "cycle \(cycle): never entered recording") { record.label == "Stop" }
            Thread.sleep(forTimeInterval: 1)
            press(record)
            waitUntil(30, "cycle \(cycle): entry never appeared") {
                self.finishedRows(app).count == cycle
            }
        }
        XCTAssertEqual(finishedRows(app).count, 3)
    }
}
