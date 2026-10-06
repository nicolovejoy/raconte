import XCTest
import AVFAudio
@testable import Raconte

private final class CarryOverFakeSession: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    init() { (events, cont) = AsyncStream<SessionEvent>.makeStream() }
    func requestPermission() async -> Bool { true }
    func activate() async throws {}
    func deactivate() {}
}

private final class CarryOverFakeRecorder: EngineRecording, @unchecked Sendable {
    var isRunning = false
    var captureFormatDescriptor: AudioFormatDescriptor? =
        AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false)
    private let lock = NSLock()
    private var sink: PCMSink?

    func start(sink: PCMSink, matching canonical: AudioFormatDescriptor?,
               onLevel: (@Sendable (Float) -> Void)?) throws {
        lock.withLock { self.sink = sink }
        isRunning = true
    }
    func stop() { isRunning = false }

    func feed(frames: Int) {
        let s = lock.withLock { sink }
        s?.receive(PCMChunk(data: Data(count: frames * 4),
                            frameCount: AVAudioFrameCount(frames), sampleRate: 48000))
    }
}

/// M3 issue #15, second half: a backdate carries over to the next capture *within the
/// same journal*. Reading a paper journal aloud is a sitting of many captures dated near
/// each other; re-dialling the year for each one is the friction being removed.
@MainActor
final class BackdateCarryOverTests: XCTestCase {
    /// Each test's own container: `journals.json` and the captures tree side by side, as
    /// on a device. Without an explicit `journalsContainerRoot` the model derives the
    /// container as the captures root's PARENT — `$TMPDIR` for a bare temp root — so
    /// every test in the process (and every run) shared one registry (#176 finding).
    private var containerRoot: URL!
    /// The captures root, `<containerRoot>/captures`.
    private var root: URL!
    /// One preference store per test, shared by every model in it, so a "relaunch" sees
    /// the selection the previous model stored — like `UserDefaults` on a device, minus
    /// the process-wide state.
    private var prefs: InMemoryJournalPreferenceStore!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackdateCarryOver-\(UUID().uuidString)", isDirectory: true)
        root = AppContainer.capturesRoot(containerRoot: containerRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        prefs = InMemoryJournalPreferenceStore()
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func makeModel() -> CaptureScreenModel {
        CaptureScreenModel(capturesRoot: root,
                           makeSession: { CarryOverFakeSession() },
                           makeRecorder: { CarryOverFakeRecorder() },
                           encoder: FakeAudioEncoder(),
                           journalsContainerRoot: containerRoot,
                           journalPreferenceStore: prefs)
    }

    private func waitUntil(_ predicate: @escaping () -> Bool,
                           timeout: TimeInterval = 5,
                           _ message: String = "condition not met",
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Journal A backdated to 1987-06; toggling backdating on again pre-fills 1987-06.
    func testBackdateCarriesOverWithinAJournal() async throws {
        let model = makeModel()
        await model.bootstrap()
        let a = try XCTUnwrap(model.selectedJournalID)

        model.setBackdateEnabled(true)
        model.setBackdatePrecision(.yearMonth)
        model.setBackdateDate(date(1987, 6, 12))
        XCTAssertEqual(model.carriedBackdate(), PartialDate(year: 1987, month: 6))

        // A later capture in the same journal: toggle off, then on again.
        model.setBackdateEnabled(false)
        XCTAssertEqual(Calendar.gregorianCurrent.component(.year, from: model.backdateDate),
                       Calendar.gregorianCurrent.component(.year, from: Date()),
                       "toggling off still resets to today")

        model.setBackdateEnabled(true)
        XCTAssertEqual(model.backdatePrecision, .yearMonth)
        XCTAssertEqual(PartialDate(from: model.backdateDate, precision: model.backdatePrecision,
                                    calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6))
        XCTAssertEqual(a, model.selectedJournalID)
    }

    /// A different journal is a different sitting — it pre-fills today, not 1987.
    func testCarryOverDoesNotCrossJournals() async throws {
        let model = makeModel()
        await model.bootstrap()

        model.setBackdateEnabled(true)
        model.setBackdateDate(date(1987, 6, 12))
        model.setBackdateEnabled(false)

        let created = await model.createJournal(name: "Other")
        let b = try XCTUnwrap(created)
        XCTAssertEqual(model.selectedJournalID, b.id)
        XCTAssertNil(model.carriedBackdate())

        model.setBackdateEnabled(true)
        XCTAssertEqual(Calendar.gregorianCurrent.component(.year, from: model.backdateDate),
                       Calendar.gregorianCurrent.component(.year, from: Date()))
        XCTAssertEqual(model.backdatePrecision, .day)
    }

    /// The dangerous case: a journal switch with the toggle ON. Journal A's dialled 1987
    /// date must not leak into journal B's next capture — B is settled from B's own state
    /// (no session choice, no history: off at today, #183), and switching back to A
    /// restores A's carry.
    func testCarryOverDoesNotCrossJournalsOnAJournalSwitch() async throws {
        let model = makeModel()
        await model.bootstrap()
        let a = try XCTUnwrap(model.selectedJournalID)

        model.setBackdateEnabled(true)
        model.setBackdateDate(date(1987, 6, 12))
        XCTAssertEqual(model.carriedBackdate(), PartialDate(year: 1987, month: 6, day: 12))

        let created = await model.createJournal(name: "Other")
        let b = try XCTUnwrap(created)
        XCTAssertEqual(model.selectedJournalID, b.id)
        XCTAssertFalse(model.backdateEnabled,
                       "#183 rule 3: B has no history and no session choice, so the toggle follows B — off")
        XCTAssertNil(model.carriedBackdate(), "journal B has no carry of its own yet")
        XCTAssertEqual(Calendar.gregorianCurrent.component(.year, from: model.backdateDate),
                       Calendar.gregorianCurrent.component(.year, from: Date()),
                       "resolves to today, never journal A's 1987 date")
        XCTAssertEqual(model.backdatePrecision, .day)

        model.selectJournal(a)
        XCTAssertTrue(model.backdateEnabled, "A's session choice was on")
        XCTAssertEqual(PartialDate(from: model.backdateDate, precision: model.backdatePrecision,
                                    calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 12),
                       "switching back to A restores A's own carry")
    }

    /// Pre-filled, not locked: the picker still writes through normally afterwards.
    func testPrefilledBackdateIsStillEditable() async throws {
        let model = makeModel()
        await model.bootstrap()

        model.setBackdateEnabled(true)
        model.setBackdateDate(date(1987, 6, 12))
        model.setBackdateEnabled(false)
        model.setBackdateEnabled(true)

        model.setBackdateDate(date(1991, 2, 3))
        XCTAssertEqual(model.carriedBackdate(), PartialDate(year: 1991, month: 2, day: 3))
    }

    /// #183 rule 4 (supersedes #175's "never auto-enabled"): history turns the toggle on,
    /// but an explicit OFF is the owner's choice and sticks for the session, per journal —
    /// a journal switch and back must not flip it on again. A relaunch forgets it.
    func testAnExplicitOffSticksForTheSessionPerJournal() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        let a = try XCTUnwrap(first.selectedJournalID)
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        await waitForSidecar(first, PartialDate(year: 1987, month: 6, day: 12))

        let session = makeModel()
        await session.bootstrap()
        XCTAssertTrue(session.backdateEnabled, "sanity: A's history turns the toggle on")
        session.setBackdateEnabled(false)
        let created = await session.createJournal(name: "Other")
        _ = try XCTUnwrap(created)
        session.selectJournal(a)
        XCTAssertFalse(session.backdateEnabled, "the explicit off outranks A's history this session")
        XCTAssertEqual(session.selectedJournalID, a)

        let relaunched = makeModel()
        await relaunched.bootstrap()
        XCTAssertTrue(relaunched.backdateEnabled, "a relaunch reads history again")
    }

    /// Nothing is remembered while backdating is off — "use the capture's own date" is
    /// not a date to carry.
    func testDisabledBackdateIsNotRemembered() async throws {
        let model = makeModel()
        await model.bootstrap()

        model.setBackdateDate(date(1987, 6, 12))
        XCTAssertNil(model.carriedBackdate())
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.gregorianCurrent.date(from: DateComponents(year: year, month: month, day: day,
                                                            hour: 12))!
    }

    // MARK: next-day advance on commit (#47)

    /// #47: consecutive pages are usually consecutive days. Once a day-precision backdated
    /// capture commits, the dial for the next one reads the day after.
    func testADayPrecisionBackdateAdvancesToTheNextDayAfterACaptureCommits() async throws {
        let recorder = CarryOverFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        model.setBackdateEnabled(true)
        model.setBackdatePrecision(.day)
        model.setBackdateDate(date(1987, 6, 12))

        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")

        XCTAssertEqual(PartialDate(from: model.backdateDate, precision: model.backdatePrecision,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertEqual(model.carriedBackdate(), PartialDate(year: 1987, month: 6, day: 13),
                       "the carry-over is the NEXT entry's date, so toggling off and on pre-fills the advanced day")
    }

    /// Only `.day` advances — a journal covering 1998 does not turn a page per year.
    ///
    /// Asserts the dial itself at DAY resolution, not only the carried value: the carry is
    /// re-derived through `rememberBackdate()`'s own precision-aware constructor, which
    /// truncates any day-level advance away at `.yearMonth` regardless of whether the
    /// `.day`-only guard fired — so `carriedBackdate()`/`backdatePrecision` alone cannot
    /// tell "the guard held" from "the guard was bypassed and the truncation just hid it".
    /// Proven by mutation: widening the guard to fire at any precision left
    /// `carriedBackdate()`/`backdatePrecision` unchanged but moved `backdateDate` from the
    /// 12th to the 13th, which only the day-resolution assertion below catches.
    func testAYearMonthBackdateDoesNotAdvance() async throws {
        let recorder = CarryOverFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        model.setBackdateEnabled(true)
        model.setBackdatePrecision(.yearMonth)
        model.setBackdateDate(date(1987, 6, 12))

        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")

        XCTAssertEqual(PartialDate(from: model.backdateDate, precision: .day, calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 12),
                       "the dial itself must stay on the exact day dialled, not just its yearMonth carry")
        XCTAssertEqual(model.carriedBackdate(), PartialDate(year: 1987, month: 6))
        XCTAssertEqual(model.backdatePrecision, .yearMonth)
    }

    /// Never into the future: a backdate of today stays today.
    func testABackdateOfTodayDoesNotAdvanceIntoTheFuture() async throws {
        let recorder = CarryOverFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let today = PartialDate(from: Date(), precision: .day, calendar: .gregorianCurrent)
        model.setBackdateEnabled(true)
        model.setBackdatePrecision(.day)
        model.setBackdateDate(today.anchorDate(calendar: .gregorianCurrent))

        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")

        XCTAssertEqual(model.carriedBackdate(), today, "tomorrow would be refused at the sidecar — keep today")
    }

    // MARK: seed from the journal's last backdated entry (#175)

    /// Drives one backdated capture to commit on `model`, exactly as the #47 tests do.
    private func commitBackdatedCapture(_ model: CaptureScreenModel,
                                        recorder: CarryOverFakeRecorder,
                                        _ backdate: Date, precision: DatePrecision = .day) async {
        model.setBackdateEnabled(true)
        model.setBackdatePrecision(precision)
        model.setBackdateDate(backdate)
        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")
    }

    private func makeModel(recorder: CarryOverFakeRecorder) -> CaptureScreenModel {
        CaptureScreenModel(capturesRoot: root,
                           makeSession: { CarryOverFakeSession() },
                           makeRecorder: { recorder },
                           encoder: FakeAudioEncoder(),
                           journalsContainerRoot: containerRoot,
                           journalPreferenceStore: prefs)
    }

    /// The journal/backdate sidecar is written by a task `handlePhase()` enqueues, which
    /// `done()` does not await (it only does on the transcript-present path, and these
    /// captures have no transcript). So "the capture finished" does not imply "its
    /// sidecar is on disk" — a relaunch that scans straight away could miss it. Poll the
    /// library until the expected backdate shows up; it normally already has.
    private func waitForSidecar(_ model: CaptureScreenModel, _ expected: PartialDate,
                                timeout: TimeInterval = 5,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            await model.library.rescan()
            if model.library.allEntries.contains(where: { $0.originalDate == expected }) { return }
            if Date() > deadline {
                return XCTFail("the \(expected) capture's sidecar never landed", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The gap #175 closes: a relaunch (a fresh model on the same root) has no in-memory
    /// carry, so turning the toggle on used to open at today. #183 goes one further: the
    /// journal's latest capture is backdated, so the toggle STARTS on, at the day after.
    func testAfterRelaunchTheToggleStartsOnAtTheDayAfterTheLastBackdatedCapture() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        let journal = try XCTUnwrap(first.selectedJournalID)
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        await waitForSidecar(first, PartialDate(year: 1987, month: 6, day: 12))

        let relaunched = makeModel()
        await relaunched.bootstrap()
        XCTAssertEqual(relaunched.selectedJournalID, journal)
        XCTAssertTrue(relaunched.backdateEnabled, "#183 rule 2: the latest capture is backdated")
        XCTAssertEqual(relaunched.backdatePrecision, .day)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertNil(relaunched.carriedBackdate(),
                     "the automatic default is history, not a choice — nothing is carried yet")

        relaunched.setBackdateEnabled(false)
        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13),
                       "off/on repeats the seed (rule 5)")
    }

    /// Coarser precision seeds unchanged, precision included — a 1987-06 sitting must not
    /// come back as a day-precision picker.
    func testAfterRelaunchAYearMonthBackdateSeedsTheSameMonth() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12),
                                     precision: .yearMonth)
        await waitForSidecar(first, PartialDate(year: 1987, month: 6))

        let relaunched = makeModel()
        await relaunched.bootstrap()
        XCTAssertTrue(relaunched.backdateEnabled, "#183: starts on from history")
        XCTAssertEqual(relaunched.backdatePrecision, .yearMonth)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .yearMonth,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6))
    }

    /// An undated capture after the backdated one does not reset the seed to today.
    func testASeedSurvivesAnUndatedCaptureInBetween() async throws {
        // One capture per model instance, each a fresh "launch" over the same `root`. (The
        // flakiness that first prompted this was #176 — a dropped `.recording` sidecar
        // write — not the number of captures per model; the shape stays because it reads
        // as the owner's real sequence of sittings.)
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        await waitForSidecar(first, PartialDate(year: 1987, month: 6, day: 12))

        let second = makeModel(recorder: recorder)
        await second.bootstrap()
        XCTAssertTrue(second.backdateEnabled, "#183: the 1987 capture turns the toggle on at launch")
        second.setBackdateEnabled(false)   // the owner's explicit off: this capture is undated
        let live = second.coordinator
        await second.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await second.done()
        await waitUntil({ second.coordinator !== live }, timeout: 10, "capture never finished")

        let relaunched = makeModel()
        await relaunched.bootstrap()
        XCTAssertFalse(relaunched.backdateEnabled,
                       "#183 rule 3: the latest capture is undated, so the toggle starts off")
        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13),
                       "#183 rule 5: a manual on still seeds from the last backdated capture")
    }

    /// Ruling 4: what was dialled this session outranks what is on disk, even when the
    /// disk holds a NEWER capture from another session on the same root.
    func testInSessionCarryOutranksTheDiskSeed() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))

        let second = makeModel()
        await second.bootstrap()
        second.setBackdateEnabled(true)
        second.setBackdateDate(date(1991, 2, 3))   // dialled by hand this session
        second.setBackdateEnabled(false)
        // Another session writes a newer backdated capture to the same root meanwhile.
        let other = makeModel(recorder: recorder)
        await other.bootstrap()
        await commitBackdatedCapture(other, recorder: recorder, date(2001, 1, 1))
        await waitForSidecar(other, PartialDate(year: 2001, month: 1, day: 1))
        await second.library.rescan()

        second.setBackdateEnabled(true)
        XCTAssertEqual(PartialDate(from: second.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1991, month: 2, day: 3),
                       "the carried 1991 wins over the seed's 2001-01-02")
    }

    /// Journal B's newest entry is invisible when journal A is selected after a relaunch.
    func testSeedDoesNotCrossJournalsAfterRelaunch() async throws {
        // One capture per model instance — see the comment in
        // `testASeedSurvivesAnUndatedCaptureInBetween`.
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        let a = try XCTUnwrap(first.selectedJournalID)
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        await waitForSidecar(first, PartialDate(year: 1987, month: 6, day: 12))

        let second = makeModel(recorder: recorder)
        await second.bootstrap()
        let created = await second.createJournal(name: "Other")
        let b = try XCTUnwrap(created)
        await commitBackdatedCapture(second, recorder: recorder, date(1999, 1, 1))
        XCTAssertEqual(second.selectedJournalID, b.id, "sanity: the 1999 capture filed into B")
        await waitForSidecar(second, PartialDate(year: 1999, month: 1, day: 1))

        let relaunched = makeModel()
        await relaunched.bootstrap()
        relaunched.selectJournal(a)
        XCTAssertTrue(relaunched.backdateEnabled, "#183: A's own history turns it on")
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        // The switch re-decides the toggle from B's own history: on, at B's seed.
        relaunched.selectJournal(b.id)
        XCTAssertTrue(relaunched.backdateEnabled)
        XCTAssertEqual(relaunched.seededBackdate(), PartialDate(year: 1999, month: 1, day: 2),
                       "B's own seed is B's last capture plus one")
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1999, month: 1, day: 2),
                       "a journal switch with the toggle on pre-fills from the seed too")
        XCTAssertNil(relaunched.carriedBackdate(),
                     "the switch path never invents a carry for B (existing rule)")
    }

    /// A journal with no backdated entry still opens at today: no seed, no surprise.
    func testAJournalWithNoBackdatedEntrySeedsNothing() async throws {
        let model = makeModel()
        await model.bootstrap()
        XCTAssertFalse(model.backdateEnabled, "#183 rule 3: nothing to follow, so off")
        XCTAssertNil(model.seededBackdate())
        model.setBackdateEnabled(true)
        XCTAssertEqual(Calendar.gregorianCurrent.component(.year, from: model.backdateDate),
                       Calendar.gregorianCurrent.component(.year, from: Date()))
        XCTAssertEqual(model.backdatePrecision, .day)
    }

    // MARK: capture follows the last-viewed journal (#183 rule 1)

    /// Looking at a journal anywhere in the app makes it the capture journal, and the
    /// choice persists like the picker's own (a relaunch opens on it).
    func testCaptureAdoptsTheLastViewedJournal() async throws {
        let model = makeModel()
        await model.bootstrap()
        let a = try XCTUnwrap(model.selectedJournalID)
        let created = await model.createJournal(name: "Other")
        let b = try XCTUnwrap(created)
        XCTAssertEqual(model.selectedJournalID, b.id, "sanity: creating selects")

        model.adoptViewedJournal(a)
        XCTAssertEqual(model.selectedJournalID, a)

        let relaunched = makeModel()
        await relaunched.bootstrap()
        XCTAssertEqual(relaunched.selectedJournalID, a, "viewing persisted the preference")
    }

    /// The guard: browsing another journal while a reading is under way must leave that
    /// reading — including which journal it is filed in — exactly alone.
    func testViewingAJournalMidRecordingDoesNotRefileTheCapture() async throws {
        let recorder = CarryOverFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let a = try XCTUnwrap(model.selectedJournalID)
        let created = await model.createJournal(name: "Other")
        let b = try XCTUnwrap(created)
        model.selectJournal(a)

        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        model.adoptViewedJournal(b.id)
        XCTAssertEqual(model.selectedJournalID, a, "a live capture is never re-filed by browsing")

        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")
    }

    /// Review finding: `adoptViewedJournal` must go through `selectJournal`, so the
    /// adopted journal's backdate default is settled too — an id-only reimplementation
    /// would show B's name over A's toggle state.
    func testAdoptingAJournalSettlesItsBackdateDefault() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        let a = try XCTUnwrap(first.selectedJournalID)
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        await waitForSidecar(first, PartialDate(year: 1987, month: 6, day: 12))

        let session = makeModel()
        await session.bootstrap()
        let created = await session.createJournal(name: "Other")
        _ = try XCTUnwrap(created)
        XCTAssertFalse(session.backdateEnabled, "sanity: the new journal has no history")

        session.adoptViewedJournal(a)
        XCTAssertTrue(session.backdateEnabled)
        XCTAssertEqual(PartialDate(from: session.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
    }

    /// The composition-root wiring, pinned: a router selection reaches the capture model.
    /// `AppServices.init` itself needs the live stores, so the wiring is a function of
    /// its own that this test can call with a fake-backed model.
    func testTheRouterWiringReachesTheCaptureModel() async throws {
        let model = makeModel()
        await model.bootstrap()
        let a = try XCTUnwrap(model.selectedJournalID)
        let created = await model.createJournal(name: "Other")
        let b = try XCTUnwrap(created)

        let router = AppRouter()
        AppServices.wireJournalFollowing(router: router, capture: model)
        router.select(.journal(a))
        XCTAssertEqual(model.selectedJournalID, a)
        router.select(.journal(b.id))
        XCTAssertEqual(model.selectedJournalID, b.id)
    }

    // MARK: the backdate never moves under a live capture (#183 review findings 1, 2)

    /// The capture picker is live during recording. Switching journals mid-reading
    /// re-files the entry and nothing else: the toggle and date describe THIS reading,
    /// and B's history must not re-date it (or leave the sidecar and header disagreeing).
    func testAJournalSwitchMidRecordingLeavesTheBackdateAlone() async throws {
        let recorder = CarryOverFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        let a = try XCTUnwrap(model.selectedJournalID)
        let created = await model.createJournal(name: "Other")
        let b = try XCTUnwrap(created)
        model.selectJournal(a)
        model.setBackdateEnabled(true)
        model.setBackdateDate(date(1987, 6, 12))

        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        model.selectJournal(b.id)
        XCTAssertEqual(model.selectedJournalID, b.id, "the reading is re-filed into B")
        XCTAssertTrue(model.backdateEnabled, "B's empty history must not turn the toggle off mid-reading")
        XCTAssertEqual(PartialDate(from: model.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 12))

        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")
    }

    /// The mirror: recording undated into A, then switching to B whose history is
    /// backdated, must not write B's automatic seed into this reading's sidecar.
    func testAJournalSwitchMidRecordingDoesNotAutoBackdateTheReading() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        let created = await first.createJournal(name: "Dated")
        let dated = try XCTUnwrap(created)
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        await waitForSidecar(first, PartialDate(year: 1987, month: 6, day: 12))

        let session = makeModel(recorder: recorder)
        await session.bootstrap()
        let plain = await session.createJournal(name: "Plain")
        _ = try XCTUnwrap(plain)
        XCTAssertFalse(session.backdateEnabled, "sanity: Plain has no history")

        let live = session.coordinator
        await session.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        session.selectJournal(dated.id)
        XCTAssertFalse(session.backdateEnabled, "Dated's history must not backdate a reading already under way")

        recorder.feed(frames: 48_000)
        await session.done()
        await waitUntil({ session.coordinator !== live }, timeout: 10, "capture never finished")
    }

    // MARK: session choices expire on commit (#183 rule 4, review finding 3)

    /// An explicit off is "this reading is undated", and it is spent once that reading
    /// commits. If the entry is then backdated elsewhere (the detail screen, spoken-date
    /// detection), history says on, and a stale off must not overrule it.
    func testAnExplicitOffExpiresWhenACaptureCommitsInThatJournal() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        let a = try XCTUnwrap(first.selectedJournalID)
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        await waitForSidecar(first, PartialDate(year: 1987, month: 6, day: 12))

        let session = makeModel(recorder: recorder)
        await session.bootstrap()
        XCTAssertTrue(session.backdateEnabled, "sanity: history turns it on")
        session.setBackdateEnabled(false)
        let live = session.coordinator
        await session.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        let undated = try XCTUnwrap(live.activeCaptureID)
        recorder.feed(frames: 48_000)
        await session.done()
        await waitUntil({ session.coordinator !== live }, timeout: 10, "capture never finished")

        // The owner dates that entry afterwards, from the detail screen.
        await session.library.setBackdate(undated, to: date(1990, 1, 1))
        await waitForSidecar(session, PartialDate(year: 1990, month: 1, day: 1))

        let created = await session.createJournal(name: "Other")
        _ = try XCTUnwrap(created)
        session.selectJournal(a)
        XCTAssertTrue(session.backdateEnabled, "the off was spent at the commit; history now says on")
        XCTAssertEqual(PartialDate(from: session.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1990, month: 1, day: 2))
    }

    /// A hand-set date after an explicit off clears the off: the owner has changed his
    /// mind, and a switch away and back must come back ON at that date.
    func testAHandSetDateAfterAnExplicitOffClearsTheOff() async throws {
        let model = makeModel()
        await model.bootstrap()
        let a = try XCTUnwrap(model.selectedJournalID)
        model.setBackdateEnabled(false)
        model.setBackdateEnabled(true)
        model.setBackdateDate(date(1987, 6, 12))

        let created = await model.createJournal(name: "Other")
        _ = try XCTUnwrap(created)
        model.selectJournal(a)
        XCTAssertTrue(model.backdateEnabled)
        XCTAssertEqual(PartialDate(from: model.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 12))
    }
}
