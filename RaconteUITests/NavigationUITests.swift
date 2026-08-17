import XCTest

/// Pins the navigation-redesign container swap (nav T4/T5): `NavigationSplitView` with a
/// non-nil sidebar selection, collapsed to a stack on iPhone, and the real `SidebarView`
/// of places (journals, All Entries, Trash, Debug) that replaces the library door, the
/// toolbar library button and the Debug sheet.
final class NavigationUITests: XCTestCase {

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

    private func recordButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["capture.record"].firstMatch
    }

    /// Cross-platform activate: XCUIElement taps on iOS, clicks on macOS.
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

    /// Wait for the post-stop receipt and dismiss it. Local copy, not shared (R6):
    /// `CaptureUITests.finishReceipt` is behaviorally identical but this class's
    /// `press`/`waitUntil`/`launchApp` are already local per Task 5's ruling — the four
    /// classes' helpers are not all byte-identical (`launchApp` diverges on seed env
    /// vars), so `UITestNavigation.swift` carries only `openPlace`/`openCapture` and each
    /// class keeps its own local copies of everything else.
    private func finishReceipt(_ app: XCUIApplication, _ what: String = "recording",
                               file: StaticString = #filePath, line: UInt = #line) {
        let dismiss = app.buttons["capture.receipt.dismiss"].firstMatch
        guard dismiss.waitForExistence(timeout: 30) else {
            XCTFail("\(what): the post-stop receipt never appeared", file: file, line: line)
            return
        }
        press(dismiss)
    }

    /// Rows in the capture screen's "Recent" section — see `CaptureUITests.recentRows`
    /// for why this queries the `NavigationLink`'s own `capture.recentRow` identifier
    /// rather than anything nested inside it. Local copy, same reasoning as
    /// `finishReceipt` above.
    private func recentRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "capture.recentRow")
    }

    /// Reveal the sidebar (if collapsed) and tap the first element whose label BEGINS
    /// WITH `prefix`. For journal rows, whose accessibility identifier carries a disk-
    /// generated id the test cannot predict — the row's spoken label ("<name>" or
    /// "<name>, <date range>") is the only address available. `openPlace` (shared
    /// helper) is used everywhere an identifier IS known; this is only for the one place
    /// it structurally cannot be.
    ///
    /// Matched on `identifier BEGINSWITH 'sidebar.journal.'` as well as the label — label
    /// alone is not unique: creating a journal auto-selects it
    /// (`CaptureScreenModel.createJournal`), so the capture screen's OWN journal-picker
    /// button label becomes the new journal's name too, and a label-only predicate matches
    /// that button before the sidebar is ever revealed (found empirically — the "reveal"
    /// step never ran, and the tap landed on the picker, not a sidebar row). The identifier
    /// prefix is the only address the sidebar row itself carries that the picker button does
    /// not; the row's numeric suffix is still unknown, so this stays a prefix match.
    private func openSidebarRow(_ app: XCUIApplication, labelBeginsWith prefix: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier BEGINSWITH 'sidebar.journal.'",
                                  prefix)).firstMatch
        if !row.waitForExistence(timeout: 3) {
            if app.buttons["sidebar.toggle"].firstMatch.exists {
                app.buttons["sidebar.toggle"].firstMatch.tap()
            } else if app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "could not reach a sidebar row beginning \"\(prefix)\"", file: file, line: line)
        press(row)
    }

    /// Reveal the bare sidebar WITHOUT selecting anything — the system Back button
    /// clears the `List`'s own selection to show the places list with nothing pre-picked.
    /// `openPlace`/`openCapture` always end by tapping a row; this stops one step short,
    /// so a test can set up "the sidebar is bare, tap something from here" scenarios.
    private func revealSidebar(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if app.buttons["sidebar.toggle"].firstMatch.exists {
            app.buttons["sidebar.toggle"].firstMatch.tap()
        } else if app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sidebar.allEntries")
                        .firstMatch.waitForExistence(timeout: 15),
                      "the bare sidebar never appeared", file: file, line: line)
    }

    // MARK: - Re-selection after backing out (task review, Critical 1)
    //
    // Round-1 fix (the sidebar's binding setter ignoring `nil` instead of coalescing it
    // to `.capture`) traded one bug for a worse one. The `List`'s OWN selection is
    // cleared by the system when Back reveals the bare sidebar, but a naive
    // `Binding(get: { router.place }, ...)` getter keeps reporting the OLD place — so
    // re-tapping the SAME row you just left writes a value SwiftUI already believes is
    // selected, which it silently drops as a no-op. Nothing navigates. These two tests
    // are the permanent pins for that scenario (nothing before this covered
    // re-selection at all).

    /// The general case: leave a place, come back to the bare sidebar, tap that SAME
    /// place again — it must reopen, not silently no-op.
    func testReselectingThePlaceYouJustLeftReopensIt() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")
        openPlace(app, "sidebar.allEntries")
        XCTAssertTrue(app.navigationBars["All Entries"].firstMatch.waitForExistence(timeout: 15),
                      "selecting All Entries did not show the library screen")

        revealSidebar(app)
        let allEntriesRow = app.descendants(matching: .any)
            .matching(identifier: "sidebar.allEntries").firstMatch
        XCTAssertTrue(allEntriesRow.waitForExistence(timeout: 15))
        press(allEntriesRow)

        XCTAssertTrue(app.navigationBars["All Entries"].firstMatch.waitForExistence(timeout: 15),
                      "re-tapping the place you just left from the bare sidebar did nothing")
    }

    /// The Capture-specific case, and the one the review called out as user-stranding:
    /// Capture is the ONE place with no OTHER route back to it once left (every other
    /// place still has its own row to fall back on; a stuck Capture selection has no
    /// exit at all).
    func testTappingCaptureFromTheBareSidebarReturnsToCapture() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")

        // Straight from Capture — the launch place — to the bare sidebar, with NO
        // intermediate place change in between. `router.place` never left `.capture`,
        // so tapping the Capture row writes the exact value a naive binding's getter
        // already reports as selected — this is what makes Capture uniquely stranded
        // (every other place still has a DIFFERENT row to fall back on first; going via
        // one of those and back is not the same defect, since it makes a real value
        // change along the way — see `testReselectingThePlaceYouJustLeftReopensIt` for
        // that general case, exercised through All Entries).
        revealSidebar(app)
        let captureRow = app.descendants(matching: .any).matching(identifier: "sidebar.capture").firstMatch
        XCTAssertTrue(captureRow.waitForExistence(timeout: 15))
        press(captureRow)

        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15),
                      "tapping Capture from the bare sidebar did not return to the capture screen")
    }

    // MARK: - The load-bearing platform claim

    /// `NavigationSplitView` with a non-nil sidebar selection, collapsed to a stack on
    /// iPhone, must show the DETAIL column at launch — not the places list.
    func testLaunchLandsDirectlyOnCaptureWithNoTaps() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")
        XCTAssertFalse(app.buttons["sidebar.allEntries"].firstMatch.exists,
                       "the places list is showing instead of capture")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sidebar.capture")
                          .firstMatch.exists,
                       "the sidebar column is showing instead of the detail column")
    }

    /// The existing entry-list-in-the-detail-column flow, exercised through the real
    /// sidebar now that `capture.libraryButton`/`RootDestination` are retired: selecting
    /// All Entries must show the library screen inside the detail column, not a blank one.
    func testSelectingAllEntriesShowsTheLibraryInTheDetailColumn() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "the app did not launch into the capture screen")
        openPlace(app, "sidebar.allEntries")
        XCTAssertTrue(app.navigationBars["All Entries"].firstMatch.waitForExistence(timeout: 15),
                      "selecting All Entries did not show the library screen in the detail column")
    }

    // MARK: - Design §3: the sidebar no longer hides the exits

    func testTheSidebarIsReachableWhileRecording() {
        // Design §3: the Debug/library routes used to exist only in the IDLE branch of the
        // setup band, which is why the owner failed to find the Library door twice and why
        // the Debug modal trapped the app. Reachability must no longer depend on capture
        // phase.
        let app = launchApp()
        press(recordButton(app))
        openPlace(app, "sidebar.allEntries")
        XCTAssertTrue(app.descendants(matching: .any)
                        .matching(identifier: "library.list").firstMatch.waitForExistence(timeout: 15)
                      || app.descendants(matching: .any)
                        .matching(identifier: "library.empty").firstMatch.waitForExistence(timeout: 15))
    }

    func testTheSidebarIsReachableWhileAReceiptIsUp() {
        // Design §3: "it no longer hides the exits." A just-finished capture used to leave
        // the receipt owning the whole screen with no route out except dismissing it first.
        let app = launchApp()
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 1)
        press(record)

        XCTAssertTrue(app.buttons["capture.receipt.dismiss"].firstMatch.waitForExistence(timeout: 30),
                      "no receipt after a capture finished")

        openPlace(app, "sidebar.allEntries")
        XCTAssertTrue(app.descendants(matching: .any)
                        .matching(identifier: "library.list").firstMatch.waitForExistence(timeout: 15),
                      "the sidebar did not reach the library while the receipt was still up")
    }

    func testTheDebugPlaceIsAScreenNotAModal() {
        let app = launchApp()
        openPlace(app, "sidebar.debug")
        XCTAssertTrue(app.descendants(matching: .any)
                        .matching(identifier: "debug.list").firstMatch.waitForExistence(timeout: 15))
        openCapture(app)      // must be possible: a modal sheet would make this impossible
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15))
    }

    /// Design §6 (nav T7): "Build info promoted to the top... it is the row the owner
    /// actually visits." A rendered-frame assertion, not a source scan — the repo's own
    /// `CaptureControlsUITests` precedent, and the only honest pin for "above".
    func testDebugPlaceShowsBuildInfoAboveTheHarness() {
        let app = launchApp()
        openPlace(app, "sidebar.debug")
        let build = app.descendants(matching: .any).matching(identifier: "debug.buildInfo").firstMatch
        let kill = app.descendants(matching: .any).matching(identifier: "debug.killNow").firstMatch
        XCTAssertTrue(build.waitForExistence(timeout: 15))
        XCTAssertTrue(kill.waitForExistence(timeout: 15))
        XCTAssertLessThan(build.frame.minY, kill.frame.minY,
                          "build info must sit above the harness — it is the row the owner visits")

        // `debug.buildInfo` exists in BOTH the placeholder and populated states (same
        // Text, different content), so existence alone pins nothing about the one line
        // this task rewired (sync -> async call site). Wait for the real string —
        // `.task` never populating is exactly the regression this line exists to catch.
        waitUntil(15, "buildInfo never populated from the async call — label reads "
                      + "\"\(build.label)\"") {
            build.label.contains("Binary file date")
        }
    }

    // MARK: - Journal scoping

    /// Record into the default journal, create a second journal, select it in the
    /// sidebar, assert the list is empty; select the first, assert one row. Cardinality
    /// ≥ 2 journals — a single-journal fixture cannot distinguish "the list is scoped"
    /// from "the list always shows everything".
    func testSelectingAJournalPlaceScopesTheEntryList() {
        let app = launchApp()
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 1)
        press(record)
        let dismiss = app.buttons["capture.receipt.dismiss"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 30), "no receipt after a capture finished")
        press(dismiss)

        // A second journal, named distinctly from the auto-created default "Journal".
        //
        // Queries `capture.journalHeader`, not the Menu's own `capture.journalPicker`
        // (`JournalHeaderView`, out of scope here — capture-screen internals, design
        // invariant 8): the accessibility hierarchy at failure showed BOTH the caption
        // Text and the Menu's synthesized Button carrying the ENCLOSING VStack's
        // `capture.journalHeader` identifier instead of the Menu's own — a pre-existing
        // identifier-flattening bug this task's new test is the first to reach (no prior
        // UI test ever queried `capture.journalPicker`). `capture.journalHeader` is what
        // actually resolves to the button; filtered to `.buttons` so it cannot also match
        // the caption's StaticText.
        let journalPicker = app.buttons["capture.journalHeader"].firstMatch
        XCTAssertTrue(journalPicker.waitForExistence(timeout: 15), "no journal picker on the landing screen")
        press(journalPicker)
        let newJournalItem = app.buttons["New Journal…"].firstMatch
        XCTAssertTrue(newJournalItem.waitForExistence(timeout: 10), "no New Journal menu item")
        press(newJournalItem)
        // Not queried by `capture.newJournalNameField`: a SwiftUI `.accessibilityIdentifier`
        // on an `.alert`'s `TextField` does not bridge onto the native `UIAlertController`
        // text field it becomes — confirmed in the accessibility hierarchy at the point of
        // failure, which showed the field present, focused, and carrying no identifier at
        // all. It is the only text field on screen at this point, so `app.textFields.firstMatch`
        // is unambiguous.
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "no New Journal name field")
        press(nameField)
        nameField.typeText("Second Journal")
        press(app.buttons["Create"].firstMatch)

        // `LibraryScreenModel.journals` (what the sidebar reads) and
        // `CaptureScreenModel.journals` (what `createJournal` just appended to, for the
        // picker) are separate arrays that only reconcile through a rescan —
        // `selectJournalScope` runs one, and `ContentView`'s `.onChange(of:
        // services.router.place)` fires it whenever a `.allEntries`/`.journal` place is
        // selected. The sidebar itself does not trigger this on its own, so the new
        // journal cannot appear as a row until SOME such place has been selected once.
        // Selecting All Entries is that trigger and a stable, already-existing route.
        openPlace(app, "sidebar.allEntries")

        // The new (empty) journal: selecting it shows no entries.
        openSidebarRow(app, labelBeginsWith: "Second Journal")
        waitUntil(15, "the new journal's library content never settled") {
            app.descendants(matching: .any).matching(identifier: "library.list").firstMatch.exists
            || app.descendants(matching: .any).matching(identifier: "library.empty").firstMatch.exists
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "library.entryLink").count, 0,
                       "a brand-new journal is not empty")

        // The default journal: selecting it shows the one entry recorded into it.
        openSidebarRow(app, labelBeginsWith: "Journal")
        waitUntil(15, "the default journal never showed its one recorded entry") {
            app.descendants(matching: .any).matching(identifier: "library.entryLink").count == 1
        }
    }

    // MARK: - Design §5: recording survives navigation

    /// The sidebar's live indicator (`CaptureSidebarRow`, T6) is the visibility guarantee
    /// design §5 promises: "the coordinator already lives in `CaptureScreenModel`, owned
    /// at the app root; unmounting the capture view must not touch it." Start a recording,
    /// leave for All Entries, come back — the same recording, still running, elapsed time
    /// advanced.
    ///
    /// TWO deviations from the brief's snippet, both found empirically
    /// (`app.debugDescription` dumps against a failing run) and both about the iPhone
    /// (compact-width) collapsed `NavigationSplitView`, not about `CaptureSidebarRow`
    /// itself:
    ///
    /// 1. The brief's snippet checks `live.waitForExistence` immediately after
    ///    `openPlace(app, "sidebar.allEntries")`, with no reveal step. On iPhone the
    ///    split view collapses to a STACK — selecting All Entries PUSHES the detail
    ///    column over the sidebar, which leaves the accessibility tree entirely (a
    ///    `debugDescription` dump confirmed it: only the "All Entries" nav bar + its
    ///    content remain, no `sidebar.*` element anywhere). The sidebar is not
    ///    simultaneously visible with a place's content on this width class; it must be
    ///    revealed, via the same back-navigation gesture `openPlace`/`openCapture`
    ///    already use internally. This IS exactly what owner-smoke step 3b (Gate A)
    ///    describes: "while it is recording, reveal the sidebar again" — the guarantee is
    ///    "always re-checkable", not "always on screen at once".
    /// 2. The brief's snippet captures `first = live.label` (format "Recording, M:SS")
    ///    and, in its iPhone fallback branch, compares it against `capture.elapsed`'s
    ///    label (format "M:SS" — no "Recording, " prefix, no comma). Those two formats
    ///    can never be equal, so `!= first` is true on the very first check — the
    ///    elapsed-advance wait would pass immediately without ever proving elapsed time
    ///    moved, on the one platform (iPhone) where that branch actually runs. Fixed by
    ///    reading `capture.elapsed` TWICE (before/after `waitUntil`), the same identifier
    ///    both times — no cross-element format bridging.
    func testARecordingSurvivesNavigatingAwayAndComingBack() {
        let app = launchApp()
        press(recordButton(app))
        Thread.sleep(forTimeInterval: 1.5)   // let the phase reach .recording before leaving

        openPlace(app, "sidebar.allEntries")

        // Deviation 1: reveal the sidebar before checking — see doc comment above.
        revealSidebar(app)
        let live = app.descendants(matching: .any).matching(identifier: "sidebar.capture.live").firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 15),
                      "a recording is invisible from everywhere but the capture screen")
        XCTAssertTrue(live.label.hasPrefix("Recording, "),
                      "the live indicator exists but its label reads \"\(live.label)\", not a recording readout")

        openCapture(app)
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15))

        // Deviation 2: same-identifier before/after comparison — see doc comment above.
        let elapsedText = app.staticTexts.matching(identifier: "capture.elapsed").firstMatch
        XCTAssertTrue(elapsedText.waitForExistence(timeout: 10), "no elapsed reading on the capture screen")
        let beforeWait = elapsedText.label
        waitUntil(20, "elapsed time did not advance — the coordinator was torn down") {
            elapsedText.label != beforeWait
        }
        press(recordButton(app))     // stop
        finishReceipt(app)
        XCTAssertEqual(recentRows(app).count, 1, "the recording did not commit")
    }
}
