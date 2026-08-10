import XCTest

/// T7 Task 4.6 — the editor, end to end on a simulator: open an entry, edit its transcript,
/// press Done, and see the detail screen showing what was typed.
///
/// The entry comes from `UITestEntrySeed` (`RACONTE_UITEST_SEED_ENTRY`) rather than from a
/// synthetic recording: the harness installs `NoOpPCMSink` as the tee branch, so nothing is
/// ever transcribed under UI test and a recorded entry has no chain to edit at all.
final class TranscriptEditorUITests: XCTestCase {

    private var testID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        testID = UUID().uuidString
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = testID
        app.launchEnvironment["RACONTE_UITEST_SEED_ENTRY"] = "1"
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

    /// Review finding 2, view side: the editor is a pushed destination, so system Back is
    /// always available — and it used to take neither the flush nor the close path. Typing and
    /// then backing out inside the 2 s debounce window dropped the keystrokes entirely and
    /// re-rendered the pre-edit transcript. Only reachable from a UI test: nothing in
    /// `RaconteTests` can press a navigation bar's Back button.
    func testBackingOutOfTheEditorKeepsTheEditAndShowsItOnTheDetailScreen() throws {
        let app = launchApp()
        openSeededEntry(app)

        let edit = app.buttons["detail.editButton"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        press(edit)

        let textView = app.textViews["editor.text"].firstMatch
        XCTAssertTrue(textView.waitForExistence(timeout: 15), "editor never appeared")
        waitUntil(15, "editor never loaded the current text") {
            textView.value as? String == "the machine heard these words"
        }
        press(textView)
        textView.typeText(" — kept on the way out")

        // Straight out via Back, well inside the 2 s window, with no Done anywhere.
        let back = app.navigationBars["Edit transcript"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back button on the editor")
        press(back)

        waitUntil(25, "backing out dropped the edit") {
            let current = app.staticTexts["detail.transcript.text"].firstMatch
            return current.exists && current.label.contains("kept on the way out")
        }
    }

    private func openSeededEntry(_ app: XCUIApplication) {
        let recentRow = app.descendants(matching: .any)
            .matching(identifier: "capture.recentRow").firstMatch
        XCTAssertTrue(recentRow.waitForExistence(timeout: 20), "seeded entry never appeared")
        press(recentRow)
    }

    func testEditTranscriptThenDoneShowsTheEditedTextOnTheDetailScreen() throws {
        let app = launchApp()
        openSeededEntry(app)

        let transcript = app.staticTexts["detail.transcript.text"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15), "transcript never rendered")
        XCTAssertTrue(transcript.label.contains("the machine heard these words"),
                      "unexpected seeded transcript: \(transcript.label)")

        let edit = app.buttons["detail.editButton"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "no Edit affordance on the detail screen")
        press(edit)

        let textView = app.textViews["editor.text"].firstMatch
        XCTAssertTrue(textView.waitForExistence(timeout: 15), "editor never appeared")
        waitUntil(15, "editor never loaded the current text") {
            textView.value as? String == "the machine heard these words"
        }

        press(textView)
        textView.typeText(" — and I corrected them")

        let done = app.buttons["editor.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "no Done button")
        press(done)

        // Back on the detail screen, showing what was typed. The Done path awaits the write
        // before dismissing, so the text is on disk by the time this can pass.
        waitUntil(25, "the detail screen never showed the edited text") {
            let current = app.staticTexts["detail.transcript.text"].firstMatch
            return current.exists && current.label.contains("and I corrected them")
        }
    }
}
