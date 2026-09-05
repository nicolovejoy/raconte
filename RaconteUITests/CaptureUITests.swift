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

    /// Task 6 (#55): the trash affordance moved from an in-body button to a row in the
    /// `⋯` info sheet — open the sheet first, then hand back its trash row, same
    /// identifier as before minus the `.legacy` suffix.
    private func openTrashRow(_ app: XCUIApplication) -> XCUIElement {
        let more = app.buttons["detail.moreButton"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "`⋯` toolbar button missing on detail")
        press(more)
        let trashButton = app.buttons["detail.trashButton"].firstMatch
        XCTAssertTrue(trashButton.waitForExistence(timeout: 10), "Move to Trash row missing from the info sheet")
        return trashButton
    }

    /// Entries as the Library screen lists them.
    ///
    /// The capture screen shows only the single most recent entry now, so counting
    /// distinct entries there is no longer possible — the library is where that question
    /// is answerable.
    private func libraryRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "library.entryLink")
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
        openCapture(app)                    // #108: launch now lands on Home
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)                       // Record → recording
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)    // let synthetic audio flow
        press(record)                       // Stop → flush → captured → finalize

        finishReceipt(app)
        openPlace(app, "sidebar.allEntries")
        // Not a direct `library.row.duration` query: `library.entryLink`
        // (`LibraryView.swift`) is a `NavigationLink`, which merges its label's
        // children into ONE accessibility element, so the nested duration Text is not
        // independently queryable — the row's own doc comment names this as the same
        // flattening `capture.recentRow` existed to work around. Parse the `m:ss` shape
        // out of the link's merged label instead, same technique the old
        // `durationSeconds(in:)` used against a Recent row's label.
        let row = app.descendants(matching: .any).matching(identifier: "library.entryLink").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the finished entry never appeared in the library")
        // Take the LAST m:ss-shaped match, not the first: since #125, a current-week
        // row's date renders with a time-of-day ("Sep 4, 2026 at 8:28 PM"), and the date
        // Text lays out before the duration Text — so the merged label reads "...8:28
        // PM, 0:03, Journal". The first match would be the wall clock, not the duration.
        // `String.range(of:options:)` does NOT support `[.regularExpression,
        // .backwards]` together — verified empirically (a standalone script and this
        // test both showed it silently returns the FIRST match regardless of
        // `.backwards`) — so the last match is found via `NSRegularExpression` directly.
        let nsLabel = row.label as NSString
        let regex = try! NSRegularExpression(pattern: #"\d{1,2}:\d{2}"#)
        let matches = regex.matches(in: row.label, range: NSRange(location: 0, length: nsLabel.length))
        guard let lastMatch = matches.last else {
            XCTFail("the finished entry shows no duration: \(row.label)")
            return
        }
        let matchedDuration = nsLabel.substring(with: lastMatch.range)
        XCTAssertNotNil(Self.seconds(matchedDuration), "duration is not m:ss: \(row.label)")
    }

    // MARK: doc tests 6/30 (flow) — kill mid-recording → relaunch recovers

    func testTerminateMidRecordingRecoversOnRelaunch() {
        let app = launchApp()
        openCapture(app)                    // #108: launch now lands on Home
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15))

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)    // ~2 s of synthetic audio on disk
        app.terminate()                     // kill mid-recording, no clean stop

        // #108: no `openCapture` here — the relaunched app lands on Home, and the
        // banner must be found THERE without ever visiting capture (load-bearing spec
        // claim: recovery does not depend on visiting capture).
        let relaunched = launchApp()        // same RACONTE_UITEST_ID → same disk
        let banner = recoveryBanner(relaunched)
        XCTAssertTrue(banner.waitForExistence(timeout: 20),
                      "no recovery banner after mid-recording kill")
        XCTAssertTrue(banner.label.hasPrefix("Recovered recording:"))
    }

    // MARK: doc test 7 (flow) — idle relaunch: no spurious banner, entry kept

    func testIdleRelaunchShowsNoBannerAndKeepsEntry() {
        let app = launchApp()
        openCapture(app)                    // #108: launch now lands on Home
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15))

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 1)
        press(record)
        finishReceipt(app)
        app.terminate()                     // idle now — a clean-ish quit

        let relaunched = launchApp()
        // No spurious banner: check on Home, where relaunch now lands, before navigating
        // to the library for the entry check below.
        XCTAssertFalse(recoveryBanner(relaunched).exists,
                       "spurious recovery banner on idle relaunch")
        openPlace(relaunched, "sidebar.allEntries")
        waitUntil(20, "entry lost across relaunch") { self.libraryRows(relaunched).count == 1 }
        // Re-check after bootstrap/scan has definitely completed (the entry row
        // wait above proves the scan finished), not just at the racy moment
        // right after relaunch.
        XCTAssertFalse(recoveryBanner(relaunched).exists,
                       "spurious recovery banner on idle relaunch (post-scan check)")
    }

    // MARK: doc test 22 (flow) — repeated record/stop cycles, one entry each

    func testRepeatedRecordStopCyclesProduceSeparateEntries() {
        let app = launchApp()
        openCapture(app)                    // #108: launch now lands on Home
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
            // One receipt per cycle is itself the "each cycle produced its own entry"
            // signal, and a stronger one than a row count: the receipt is built per
            // capture, after that capture's finalizer has run.
            finishReceipt(app, "cycle \(cycle)")
        }

        // Counted in the LIBRARY, not on the capture screen. The capture screen shows only
        // the single most recent entry now (owner: "just see the most recent one and then
        // have an obvious link to the Library"), so three rows can no longer be counted
        // there — and quietly weakening this to "the newest one exists" would drop the
        // separate-entries property this test is named for.
        openPlace(app, "sidebar.allEntries")
        waitUntil(20, "three cycles did not produce three separate entries") {
            self.libraryRows(app).count == 3
        }
    }

    // MARK: issue #6 (flow) — drag the scrubber on a finished entry, from its detail screen

    /// Asserts on the position label, not audibility: a headless simulator may
    /// have no output route, and `endScrubbing` writes `currentTime`
    /// synchronously, so the label is correct with no audio at all.
    ///
    /// Covers the m4a path only — the raw-segment path is unreachable from UI
    /// tests (bootstrap drains the finalize queue at launch), so that one stays
    /// manual in the smoke doc.
    ///
    /// Playback moved from the capture screen's recent row to `EntryDetailView` (M3
    /// T4.5), so this test now taps the recent row to push detail before scrubbing.
    func testScrubbingAFinishedEntryMovesThePosition() throws {
        let app = launchApp()
        openCapture(app)                    // #108: launch now lands on Home
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 3)    // ~3 s so half is unambiguous
        press(record)
        openReceiptEntry(app)

        // The scrubber only exists once playback has been started at least once.
        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "play button never appeared")
        press(play)
        let scrubber = app.sliders["detail.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 15), "scrubber never appeared")

        let total = app.staticTexts["detail.total"].firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 5))
        let totalSeconds = try XCTUnwrap(Self.seconds(total.label), "unreadable total \(total.label)")
        XCTAssertGreaterThan(totalSeconds, 1, "capture too short to scrub meaningfully")

        let position = app.staticTexts["detail.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 5))

        // XCUI's normalized drag is coarse on a narrow slider: a request for 0.5 can land
        // within the end-guard band and fail the run on drag imprecision alone (three
        // first-attempt CI failures, 2026-08-29: 3.54–3.72s of ~4s). The test's claim is
        // "scrubbing moves the position", not "lands at 50%": walk earlier targets until
        // the handle lands inside the assertable band.
        var handleSeconds = 0.0
        for target in [0.5, 0.35, 0.25] {
            scrubber.adjust(toNormalizedSliderPosition: target)
            handleSeconds = try XCTUnwrap(Self.number(scrubber.value),
                                          "unreadable slider value \(String(describing: scrubber.value))")
            if handleSeconds > 0.5 && handleSeconds < totalSeconds - 0.5 { break }
        }
        XCTAssertGreaterThan(handleSeconds, 0.5, "the drag barely moved the handle")
        XCTAssertLessThan(handleSeconds, totalSeconds - 0.5,
                          "the handle must land short of the end, or a still-running "
                          + "playhead could match by accident")

        // `endScrubbing` writes the position synchronously, so the first sample
        // should already match; if it were still playing it would drift out of
        // tolerance faster than the poll interval.
        waitUntil(10, "position never followed the handle to \(handleSeconds)s") {
            guard let seconds = Self.seconds(position.label) else { return false }
            return abs(seconds - handleSeconds) <= 1.0
        }
    }

    // MARK: M3 T5 (flow) — trash → restore, over the real sidecar

    /// Record, trash the entry from its detail screen, confirm it leaves the library and
    /// turns up in the Trash with a countdown, then restore it and confirm it comes back.
    /// The whole round trip is one `entry.json` field, so this is really a check that the
    /// three lists (`items`, `recent`, `trashed`) all republish off one scan.
    func testTrashAndRestoreAnEntry() {
        let app = launchApp()
        openCapture(app)                    // #108: launch now lands on Home
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)
        press(record)
        openReceiptEntry(app)

        let trashButton = openTrashRow(app)
        press(trashButton)
        let confirm = app.buttons["detail.confirmTrash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no trash confirmation")
        press(confirm)

        openPlace(app, "sidebar.allEntries")
        waitUntil(20, "trashed entry still in the library") { self.libraryRows(app).count == 0 }

        openPlace(app, "sidebar.trash")

        let remaining = app.staticTexts["trash.row.remaining"].firstMatch
        XCTAssertTrue(remaining.waitForExistence(timeout: 15), "trashed entry not listed")
        XCTAssertTrue(remaining.label.contains("days left"),
                      "no countdown on the trashed row: \(remaining.label)")

        press(app.buttons["trash.row.restore"].firstMatch)
        waitUntil(20, "the restored entry is still in the trash") {
            app.staticTexts.matching(identifier: "trash.row.remaining").count == 0
        }
    }

    // MARK: #62 (owner smoke 2026-08-16) — trashing the receipt's entry retires the receipt

    /// The owner's exact path: record → stop → the receipt appears → Open the entry from
    /// the receipt → Move to Trash → land back on the capture screen. The receipt must
    /// not still be standing there naming the entry that is now in the trash.
    ///
    /// HONESTY NOTE (stash-probe, 2026-08-16): this test also passes against the
    /// pre-#62 code in the SIMULATOR, because the Open link's `simultaneousGesture`
    /// dismiss fires reliably there — the very gesture that evidently did NOT fire on
    /// the owner's iPhone, which is the only reason #62 was reachable. With the receipt
    /// standing there is no other route to a trash affordance, so no simulator flow can
    /// isolate the reconcile path; the discriminating pins are the three
    /// `reconcileReceipt` unit tests in `CaptureScreenModelTests` (RED-verified against
    /// a no-op). This test pins the end-to-end repro: it fails only if BOTH mechanisms
    /// (gesture dismiss and library reconcile) regress at once — which is exactly the
    /// user-visible bug.
    func testTrashingTheReceiptsEntryRetiresTheReceipt() {
        let app = launchApp()
        openCapture(app)                    // #108: launch now lands on Home
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)
        press(record)

        openReceiptEntry(app)

        let trashButton = openTrashRow(app)
        press(trashButton)
        let confirm = app.buttons["detail.confirmTrash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no trash confirmation")
        press(confirm)

        // Back on the capture screen: the receipt is gone with its entry.
        XCTAssertTrue(record.waitForExistence(timeout: 20), "never landed back on the capture screen")
        waitUntil(15, "the receipt still names the trashed entry") {
            app.descendants(matching: .any).matching(identifier: "capture.receipt.open").firstMatch.exists == false
        }
    }

    // MARK: owner report 2026-08-03 — Trash → Delete Now must actually erase the entry

    /// Record, trash it, then "Delete Now" + confirm from the Trash screen. Asserts the
    /// row disappears from Trash AND the entry never reappears in the Library, then
    /// relaunches the app and checks both hold across a fresh scan — the owner's report
    /// was "I deleted it and it's still there," which a stale in-memory list would not
    /// catch but a relaunch-then-rescan will.
    func testDeleteNowPermanentlyRemovesEntry() {
        let app = launchApp()
        openCapture(app)                    // #108: launch now lands on Home
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)
        press(record)
        openReceiptEntry(app)

        let trashButton = openTrashRow(app)
        press(trashButton)
        let confirmTrash = app.buttons["detail.confirmTrash"].firstMatch
        XCTAssertTrue(confirmTrash.waitForExistence(timeout: 10), "no trash confirmation")
        press(confirmTrash)

        openPlace(app, "sidebar.allEntries")
        waitUntil(20, "trashed entry still in the library") { self.libraryRows(app).count == 0 }

        openPlace(app, "sidebar.trash")

        let remaining = app.staticTexts["trash.row.remaining"].firstMatch
        XCTAssertTrue(remaining.waitForExistence(timeout: 15), "trashed entry not listed")

        press(app.buttons["trash.row.deleteNow"].firstMatch)
        let confirmDelete = app.buttons["trash.confirmDeleteNow"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 10), "no Delete Now confirmation")
        press(confirmDelete)

        waitUntil(20, "entry still listed in Trash after Delete Now") {
            app.staticTexts.matching(identifier: "trash.row.remaining").count == 0
        }
        XCTAssertTrue(app.staticTexts["trash.empty"].waitForExistence(timeout: 10),
                      "Trash not showing empty state after the only entry was deleted")

        // Back to the Library: the entry must not have resurrected there either.
        openPlace(app, "sidebar.allEntries")
        waitUntil(15, "library still shows the permanently-deleted entry") {
            app.staticTexts.matching(identifier: "library.row.duration").count == 0
        }

        // Relaunch and rescan from scratch: the deletion must be on disk, not just
        // in the in-memory list this process happened to be holding.
        app.terminate()
        let relaunched = launchApp()
        openPlace(relaunched, "sidebar.allEntries")
        XCTAssertEqual(libraryRows(relaunched).count, 0,
                       "permanently-deleted entry reappeared after relaunch")

        openPlace(relaunched, "sidebar.trash")
        XCTAssertTrue(relaunched.descendants(matching: .any).matching(identifier: "trash.empty")
                        .firstMatch.waitForExistence(timeout: 15),
                      "trash shows the permanently-deleted entry after relaunch")
    }

    // MARK: owner ask 2026-08-22 — Empty Trash: bulk permanent delete from the Trash screen

    /// Trash two entries, then Empty Trash in one action. Asserts both rows disappear
    /// from Trash, then relaunches and re-checks Trash is empty from a fresh disk scan —
    /// the same disk-truth discipline `testDeleteNowPermanentlyRemovesEntry` uses,
    /// because an in-memory list emptying itself proves nothing about what actually
    /// happened on disk.
    func testEmptyTrashPermanentlyRemovesAllTrashedEntries() {
        let app = launchApp()
        openCapture(app)                    // #108: launch now lands on Home
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        // Record and trash two separate entries.
        for _ in 0..<2 {
            waitUntil(15, "record button not ready") { record.label == "Record" && record.isEnabled }
            press(record)
            waitUntil(10, "never entered recording") { record.label == "Stop" }
            Thread.sleep(forTimeInterval: 2)
            press(record)
            openReceiptEntry(app)

            let trashButton = openTrashRow(app)
            press(trashButton)
            let confirmTrash = app.buttons["detail.confirmTrash"].firstMatch
            XCTAssertTrue(confirmTrash.waitForExistence(timeout: 10), "no trash confirmation")
            press(confirmTrash)
            openCapture(app)
        }

        openPlace(app, "sidebar.trash")
        waitUntil(15, "both trashed entries not listed") {
            app.staticTexts.matching(identifier: "trash.row.remaining").count == 2
        }

        let emptyAll = app.buttons["trash.emptyAll"].firstMatch
        XCTAssertTrue(emptyAll.waitForExistence(timeout: 10), "no Empty Trash button")
        press(emptyAll)
        let confirmEmptyAll = app.buttons["trash.confirmEmptyAll"].firstMatch
        XCTAssertTrue(confirmEmptyAll.waitForExistence(timeout: 10), "no Empty Trash confirmation")
        press(confirmEmptyAll)

        waitUntil(20, "entries still listed in Trash after Empty Trash") {
            app.staticTexts.matching(identifier: "trash.row.remaining").count == 0
        }
        XCTAssertTrue(app.staticTexts["trash.empty"].waitForExistence(timeout: 10),
                      "Trash not showing empty state after Empty Trash")

        // Relaunch and rescan from scratch: disk truth, not just this process's
        // in-memory list.
        app.terminate()
        let relaunched = launchApp()
        openPlace(relaunched, "sidebar.trash")
        XCTAssertTrue(relaunched.staticTexts["trash.empty"].firstMatch.waitForExistence(timeout: 15),
                      "trash shows permanently-deleted entries after relaunch")
    }

    // MARK: owner report 2026-08-03 — Move to Trash while playback is running (device forensics)

    /// Targeted repro attempt for a device failure: the owner's "Move to Trash" from an
    /// entry's detail screen silently no-opped for one entry, and that detail screen had
    /// playback running on it beforehand. Record, open detail, START PLAYBACK, then while
    /// it is still playing tap Move to Trash and confirm — assert the entry actually lands
    /// in Trash. If this fails, it is the repro and root-causing continues from here; if
    /// it passes on the simulator, the failure is environmental/device-specific (same
    /// conclusion `testDeleteNowPermanentlyRemovesEntry` reached for its own bug).
    func testMoveToTrashWhilePlaybackIsRunningStillTrashesTheEntry() {
        let app = launchApp()
        openCapture(app)                    // #108: launch now lands on Home
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 3)
        press(record)
        openReceiptEntry(app)

        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "play button never appeared")
        press(play)
        // Give playback a moment to actually start rather than trashing on the same
        // frame it was requested — the device report was mid-playback, not mid-tap.
        Thread.sleep(forTimeInterval: 1)

        let trashButton = openTrashRow(app)
        press(trashButton)
        let confirmTrash = app.buttons["detail.confirmTrash"].firstMatch
        XCTAssertTrue(confirmTrash.waitForExistence(timeout: 10), "no trash confirmation")
        press(confirmTrash)

        openPlace(app, "sidebar.allEntries")
        waitUntil(20, "trashed entry still in the library") { self.libraryRows(app).count == 0 }

        openPlace(app, "sidebar.trash")

        let remaining = app.staticTexts["trash.row.remaining"].firstMatch
        XCTAssertTrue(remaining.waitForExistence(timeout: 15),
                      "entry not listed in Trash after Move to Trash during playback — the "
                      + "write likely silently failed while playback was running")
    }

    // MARK: #118 §4 — the voice switch is in every recording

    /// There is no Two-voices toggle any more. A recording opens with both marker
    /// controls present, the voice switch reading the main voice, and a tap on it flips
    /// the label — that tap is what makes the entry two-voice.
    func testVoiceSwitchIsPresentInEveryRecording() {
        let app = launchApp()
        openCapture(app)
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")
        XCTAssertFalse(app.switches["capture.multiVoiceToggle"].firstMatch.exists,
                       "the Two-voices toggle is gone (#118 §4)")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }

        let voiceSwitch = app.buttons["capture.voiceSwitch"].firstMatch
        let paragraph = app.buttons["capture.paragraph"].firstMatch
        XCTAssertTrue(voiceSwitch.waitForExistence(timeout: 10), "no voice switch while recording")
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10), "no paragraph button while recording")
        XCTAssertEqual(voiceSwitch.label, "BN", "a recording opens in the main voice")

        Thread.sleep(forTimeInterval: 1)
        press(voiceSwitch)
        waitUntil(10, "the voice never flipped") { voiceSwitch.label == "LN" }

        Thread.sleep(forTimeInterval: 1)
        press(record)
        finishReceipt(app)
    }

    /// `XCUIElement.value` is `Any?`; a SwiftUI slider reports its number as a
    /// string on some platforms and a `Double` on others.
    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-").inverted))
        }
        return nil
    }

    /// Parses the `m:ss` / `mm:ss` shape `CaptureCoordinator.formatDuration` emits.
    private static func seconds(_ label: String) -> Double? {
        let parts = label.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

}
