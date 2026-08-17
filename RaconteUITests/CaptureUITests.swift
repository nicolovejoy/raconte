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

    /// Rows in the capture screen's "Recent" section (M3 T4.5) — each a `NavigationLink`
    /// wrapping a `LibraryEntryRow`. Queried by the link's own `capture.recentRow`
    /// identifier, not the row's nested `library.row.duration` text: a `NavigationLink`,
    /// like `Button`, merges its label's children into ONE accessibility element, so the
    /// nested identifier is not independently queryable — only the link's own is.
    private func recentRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "capture.recentRow")
    }

    /// Wait for the post-stop receipt and dismiss it.
    ///
    /// Added 2026-08-15. Finishing a capture used to drop straight back to the landing
    /// screen, so "a recording completed" could be read off a Recent row appearing. It now
    /// raises a receipt that owns the screen until dismissed (owner ruling: the finished
    /// transcript was being left stranded on the landing screen with nothing owning it),
    /// so every test that records something needs this one step — the same step a person
    /// takes. The receipt appearing is also a STRONGER completion signal than a row was:
    /// it is only built after the finalizer, the transcript ref and the rescan have all
    /// run, whereas a row could appear off a scan alone.
    private func finishReceipt(_ app: XCUIApplication, _ what: String = "recording",
                               file: StaticString = #filePath, line: UInt = #line) {
        let dismiss = app.buttons["capture.receipt.dismiss"].firstMatch
        guard dismiss.waitForExistence(timeout: 30) else {
            XCTFail("\(what): the post-stop receipt never appeared", file: file, line: line)
            return
        }
        press(dismiss)
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
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)                       // Record → recording
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)    // let synthetic audio flow
        press(record)                       // Stop → flush → captured → finalize

        finishReceipt(app)
        waitUntil(30, "finished entry never appeared") { self.recentRows(app).count == 1 }
        waitUntil(15, "screen never reset to idle") { record.label == "Record" }

        let row = recentRows(app).firstMatch
        XCTAssertNotNil(Self.durationSeconds(in: row.label),
                        "recent row shows no duration: \(row.label)")
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
        finishReceipt(app)
        waitUntil(30, "finished entry never appeared") { self.recentRows(app).count == 1 }
        app.terminate()                     // idle now — a clean-ish quit

        let relaunched = launchApp()
        let rows = recentRows(relaunched)
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
        press(app.buttons["capture.libraryDoor"].firstMatch)
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
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 3)    // ~3 s so half is unambiguous
        press(record)
        finishReceipt(app)
        waitUntil(30, "finished entry never appeared") { self.recentRows(app).count == 1 }
        waitUntil(15, "screen never reset to idle") { record.label == "Record" }

        let recentRow = recentRows(app).firstMatch
        XCTAssertTrue(recentRow.waitForExistence(timeout: 10), "recent row never appeared")
        press(recentRow)

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

        scrubber.adjust(toNormalizedSliderPosition: 0.5)

        // Where the handle actually landed — XCUI's normalized drag is coarse on a
        // narrow slider, so assert the label tracks the handle, not the midpoint.
        let handleSeconds = try XCTUnwrap(Self.number(scrubber.value),
                                          "unreadable slider value \(String(describing: scrubber.value))")
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
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)
        press(record)
        finishReceipt(app)
        waitUntil(30, "finished entry never appeared") { self.recentRows(app).count == 1 }
        waitUntil(15, "screen never reset to idle") { record.label == "Record" }

        press(recentRows(app).firstMatch)

        let trashButton = app.buttons["detail.trashButton"].firstMatch
        XCTAssertTrue(trashButton.waitForExistence(timeout: 10), "no Move to Trash button")
        press(trashButton)
        let confirm = app.buttons["detail.confirmTrash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no trash confirmation")
        press(confirm)

        // Back on the capture screen: the entry is gone from Recent.
        waitUntil(20, "trashed entry still in Recent") { self.recentRows(app).count == 0 }

        press(app.buttons["capture.libraryButton"].firstMatch)
        let trashLink = app.buttons["library.trashLink"].firstMatch
        XCTAssertTrue(trashLink.waitForExistence(timeout: 15), "no Trash link in the library")
        waitUntil(15, "trash count never showed the entry") { trashLink.label.contains("1") }
        press(trashLink)

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
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)
        press(record)

        let open = app.descendants(matching: .any)
            .matching(identifier: "capture.receipt.open").firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30), "the post-stop receipt never appeared")
        press(open)

        let trashButton = app.buttons["detail.trashButton"].firstMatch
        XCTAssertTrue(trashButton.waitForExistence(timeout: 10), "no Move to Trash button")
        press(trashButton)
        let confirm = app.buttons["detail.confirmTrash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no trash confirmation")
        press(confirm)

        // Back on the capture screen: the receipt is gone with its entry, and so is
        // the Recent row (the row half already worked — trashEntry rescans).
        XCTAssertTrue(record.waitForExistence(timeout: 20), "never landed back on the capture screen")
        waitUntil(15, "the receipt still names the trashed entry") {
            app.buttons["capture.receipt.dismiss"].firstMatch.exists == false
        }
        waitUntil(15, "trashed entry still in Recent") { self.recentRows(app).count == 0 }
    }

    // MARK: owner report 2026-08-03 — Trash → Delete Now must actually erase the entry

    /// Record, trash it, then "Delete Now" + confirm from the Trash screen. Asserts the
    /// row disappears from Trash AND the entry never reappears in the Library, then
    /// relaunches the app and checks both hold across a fresh scan — the owner's report
    /// was "I deleted it and it's still there," which a stale in-memory list would not
    /// catch but a relaunch-then-rescan will.
    func testDeleteNowPermanentlyRemovesEntry() {
        let app = launchApp()
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 2)
        press(record)
        finishReceipt(app)
        waitUntil(30, "finished entry never appeared") { self.recentRows(app).count == 1 }
        waitUntil(15, "screen never reset to idle") { record.label == "Record" }

        press(recentRows(app).firstMatch)

        let trashButton = app.buttons["detail.trashButton"].firstMatch
        XCTAssertTrue(trashButton.waitForExistence(timeout: 10), "no Move to Trash button")
        press(trashButton)
        let confirmTrash = app.buttons["detail.confirmTrash"].firstMatch
        XCTAssertTrue(confirmTrash.waitForExistence(timeout: 10), "no trash confirmation")
        press(confirmTrash)

        waitUntil(20, "trashed entry still in Recent") { self.recentRows(app).count == 0 }

        press(app.buttons["capture.libraryButton"].firstMatch)
        let trashLink = app.buttons["library.trashLink"].firstMatch
        XCTAssertTrue(trashLink.waitForExistence(timeout: 15), "no Trash link in the library")
        waitUntil(15, "trash count never showed the entry") { trashLink.label.contains("1") }
        press(trashLink)

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
        app.navigationBars.buttons.firstMatch.tap()
        waitUntil(15, "library still shows the permanently-deleted entry") {
            app.staticTexts.matching(identifier: "library.row.duration").count == 0
        }

        // Relaunch and rescan from scratch: the deletion must be on disk, not just
        // in the in-memory list this process happened to be holding.
        app.terminate()
        let relaunched = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15)
                      || relaunched.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(recentRows(relaunched).count, 0,
                       "permanently-deleted entry reappeared in Recent after relaunch")

        press(relaunched.buttons["capture.libraryButton"].firstMatch)
        let trashLinkAfter = relaunched.buttons["library.trashLink"].firstMatch
        if trashLinkAfter.waitForExistence(timeout: 10) {
            XCTAssertFalse(trashLinkAfter.label.contains("1"),
                           "trash count shows the permanently-deleted entry after relaunch")
        }
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
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 3)
        press(record)
        finishReceipt(app)
        waitUntil(30, "finished entry never appeared") { self.recentRows(app).count == 1 }
        waitUntil(15, "screen never reset to idle") { record.label == "Record" }

        press(recentRows(app).firstMatch)

        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "play button never appeared")
        press(play)
        // Give playback a moment to actually start rather than trashing on the same
        // frame it was requested — the device report was mid-playback, not mid-tap.
        Thread.sleep(forTimeInterval: 1)

        let trashButton = app.buttons["detail.trashButton"].firstMatch
        XCTAssertTrue(trashButton.waitForExistence(timeout: 10), "no Move to Trash button")
        press(trashButton)
        let confirmTrash = app.buttons["detail.confirmTrash"].firstMatch
        XCTAssertTrue(confirmTrash.waitForExistence(timeout: 10), "no trash confirmation")
        press(confirmTrash)

        waitUntil(20, "trashed entry still in Recent") { self.recentRows(app).count == 0 }

        press(app.buttons["capture.libraryButton"].firstMatch)
        let trashLink = app.buttons["library.trashLink"].firstMatch
        XCTAssertTrue(trashLink.waitForExistence(timeout: 15), "no Trash link in the library")
        waitUntil(15, "trash count never showed the entry — the Move to Trash write likely "
                      + "silently failed while playback was running") {
            trashLink.label.contains("1")
        }
        press(trashLink)

        let remaining = app.staticTexts["trash.row.remaining"].firstMatch
        XCTAssertTrue(remaining.waitForExistence(timeout: 15),
                      "entry not listed in Trash after Move to Trash during playback")
    }

    // MARK: T6 §14 design §8 (flow) — the Two-voices toggle gates the voice switch

    /// Record twice over the synthetic engine: once with "Two voices" on, once off.
    /// With it on, both marker controls are present while recording; with it off, the
    /// paragraph button is still there (owner decision 7 — paragraphs are independent
    /// of the voice toggle) and the voice switch is gone.
    ///
    /// The explicit toggle-*off* in the second half is part of what's being tested:
    /// multi-voice carry-over auto-arms the toggle from the just-recorded entry, which
    /// is the deliberate divergence from backdate carry-over (design §2).
    ///
    /// There is no `capture.done` button while recording (`RecordControlModel` offers
    /// Done only from `.interrupted`), so captures are stopped the way every other test
    /// here stops them: press `capture.record` again and poll its label.
    func testVoiceControlsFollowTheMultiVoiceToggle() {
        let app = launchApp()
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        let multiVoice = app.switches["capture.multiVoiceToggle"].firstMatch
        XCTAssertTrue(multiVoice.waitForExistence(timeout: 10), "no Two voices toggle")
        setToggle(multiVoice, on: true)

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }

        let voiceSwitch = app.buttons["capture.voiceSwitch"].firstMatch
        let paragraph = app.buttons["capture.paragraph"].firstMatch
        XCTAssertTrue(voiceSwitch.waitForExistence(timeout: 10),
                      "no voice switch while recording with Two voices on")
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10),
                      "no paragraph button while recording")
        XCTAssertEqual(voiceSwitch.label, "BN",
                       "a multi-voice capture opens in bn, so the switch shows BN")

        Thread.sleep(forTimeInterval: 1)
        press(record)
        finishReceipt(app)
        waitUntil(30, "finished entry never appeared") { self.recentRows(app).count == 1 }
        waitUntil(15, "screen never reset to idle") { record.label == "Record" }

        // Carry-over will have armed it from the entry just recorded — turn it off by hand.
        setToggle(multiVoice, on: false)

        press(record)
        waitUntil(10, "never entered recording (second capture)") { record.label == "Stop" }
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10),
                      "the paragraph button must survive Two voices being off")
        XCTAssertFalse(voiceSwitch.exists,
                       "voice switch shown while recording with Two voices off")

        Thread.sleep(forTimeInterval: 1)
        press(record)
        finishReceipt(app, "second recording")
    }

    /// Drive a SwiftUI `Toggle` to a known state and confirm it landed there — the
    /// switch reports "0"/"1" through `value`, and tapping an already-correct toggle
    /// would silently invert the thing under test.
    private func setToggle(_ toggle: XCUIElement, on: Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let wanted = on ? "1" : "0"
        if (toggle.value as? String) != wanted {
            press(toggle)
        }
        waitUntil(5, "toggle never reached \(on ? "on" : "off")", file: file, line: line) {
            (toggle.value as? String) == wanted
        }
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

    /// A `NavigationLink`-wrapped `LibraryEntryRow`'s accessibility label is every child
    /// `Text`'s label concatenated by SwiftUI (date, duration, snippet, journal) — so the
    /// duration check searches for the `m:ss` shape rather than parsing the whole label.
    private static func durationSeconds(in label: String) -> Double? {
        guard let range = label.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return seconds(String(label[range]))
    }
}
