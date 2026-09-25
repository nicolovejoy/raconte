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
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackdateCarryOver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // `makeModel()`/`makeModel(recorder:)` build `CaptureScreenModel` with its default
        // `journalPreferenceStore`, `UserDefaultsJournalPreferenceStore()` — real
        // `UserDefaults.standard`, unscoped to `root`. The #175 relaunch/seed tests are the
        // first in this file to run TWO models over DIFFERENT roots in the same process
        // (this test's "first"/"second"/"other" plus a later test's own), so a stale
        // `currentJournalID` written by an earlier test's root can leak into this one's
        // `resolveCurrentJournal()` and select a journal that doesn't exist here. Clearing
        // the key before every test keeps each one's "device" starting cold, same as it
        // would after this file's very first test — not a behavior change for any single
        // test, just cross-test isolation.
        UserDefaults.standard.removeObject(forKey: CurrentJournal.defaultsKey)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        // Leave the test host's real UserDefaults clean too, not just the next test's.
        UserDefaults.standard.removeObject(forKey: CurrentJournal.defaultsKey)
    }

    private func makeModel() -> CaptureScreenModel {
        CaptureScreenModel(capturesRoot: root,
                           makeSession: { CarryOverFakeSession() },
                           makeRecorder: { CarryOverFakeRecorder() },
                           encoder: FakeAudioEncoder())
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

    /// The dangerous case: the toggle stays ON across a journal switch. Journal A's
    /// dialled 1987 date must not leak into journal B's next capture — B gets its own
    /// carry (none yet, so today/.day), and switching back to A restores A's.
    func testCarryOverDoesNotCrossJournalsWhileToggleStaysOn() async throws {
        let model = makeModel()
        await model.bootstrap()
        let a = try XCTUnwrap(model.selectedJournalID)

        model.setBackdateEnabled(true)
        model.setBackdateDate(date(1987, 6, 12))
        XCTAssertEqual(model.carriedBackdate(), PartialDate(year: 1987, month: 6, day: 12))

        let created = await model.createJournal(name: "Other")
        let b = try XCTUnwrap(created)
        XCTAssertEqual(model.selectedJournalID, b.id)
        XCTAssertTrue(model.backdateEnabled, "the toggle itself is untouched by the switch")
        XCTAssertNil(model.carriedBackdate(), "journal B has no carry of its own yet")
        XCTAssertEqual(Calendar.gregorianCurrent.component(.year, from: model.backdateDate),
                       Calendar.gregorianCurrent.component(.year, from: Date()),
                       "resolves to today, never journal A's 1987 date")
        XCTAssertEqual(model.backdatePrecision, .day)

        model.selectJournal(a)
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

    /// The toggle is never flipped on for him. Pre-filling a field he opened is help;
    /// opening it is a decision he did not make.
    func testCarryOverNeverAutoEnablesTheToggle() async throws {
        let model = makeModel()
        await model.bootstrap()

        model.setBackdateEnabled(true)
        model.setBackdateDate(date(1987, 6, 12))
        model.setBackdateEnabled(false)

        XCTAssertFalse(model.backdateEnabled)
        let second = makeModel()
        await second.bootstrap()
        XCTAssertFalse(second.backdateEnabled)
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
        let model = CaptureScreenModel(capturesRoot: root,
                                       makeSession: { CarryOverFakeSession() },
                                       makeRecorder: { recorder },
                                       encoder: FakeAudioEncoder())
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
        let model = CaptureScreenModel(capturesRoot: root,
                                       makeSession: { CarryOverFakeSession() },
                                       makeRecorder: { recorder },
                                       encoder: FakeAudioEncoder())
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
        let model = CaptureScreenModel(capturesRoot: root,
                                       makeSession: { CarryOverFakeSession() },
                                       makeRecorder: { recorder },
                                       encoder: FakeAudioEncoder())
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
                           encoder: FakeAudioEncoder())
    }

    /// The pendingMetadataWrite chain that lands a backdate in the sidecar is a detached
    /// Task `done()` does not await when the capture has no transcript (fake recorder,
    /// this whole file) — `detectSpokenDate` only awaits it on the transcript-present
    /// path. So `library.rescan()` right after `done()` can race the write landing on
    /// disk. Poll with a fresh rescan each iteration (not a static `allEntries` read,
    /// which never changes once taken) until the expected backdate shows up.
    private func waitForSidecar(_ model: CaptureScreenModel, _ expected: PartialDate,
                                attempts: Int = 15,
                                file: StaticString = #filePath, line: UInt = #line) async {
        // A generous sleep BEFORE each rescan, not a tight poll: the pendingMetadataWrite
        // chain (a detached Task `done()` does not await when there is no transcript) and
        // this method's own `library.rescan()` both go through the same actor-backed
        // `entryMetadataStore`, and hammering it with rescans starves the pending write of
        // its turn rather than letting it land sooner.
        for _ in 0..<attempts {
            try? await Task.sleep(for: .seconds(2))
            await model.library.rescan()
            if model.library.allEntries.contains(where: { $0.originalDate == expected }) { return }
        }
        XCTFail("the \(expected) capture's sidecar never landed", file: file, line: line)
    }

    /// The gap #175 closes: a relaunch (a fresh model on the same root) has no in-memory
    /// carry, so turning the toggle on used to open at today. It now opens at the day
    /// after the last backdated capture in this journal.
    func testAfterRelaunchTheToggleSeedsTheDayAfterTheLastBackdatedCapture() async throws {
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        let journal = try XCTUnwrap(first.selectedJournalID)
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        await waitForSidecar(first, PartialDate(year: 1987, month: 6, day: 12))

        let relaunched = makeModel()
        await relaunched.bootstrap()
        XCTAssertEqual(relaunched.selectedJournalID, journal)
        XCTAssertNil(relaunched.carriedBackdate(), "sanity: a fresh model carries nothing")
        XCTAssertFalse(relaunched.backdateEnabled, "the seed never flips the toggle on")

        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(relaunched.backdatePrecision, .day)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertEqual(relaunched.carriedBackdate(), PartialDate(year: 1987, month: 6, day: 13),
                       "the seed becomes this session's carry, so off/on repeats it")
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
        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(relaunched.backdatePrecision, .yearMonth)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .yearMonth,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6))
    }

    /// An undated capture after the backdated one does not reset the seed to today.
    func testASeedSurvivesAnUndatedCaptureInBetween() async throws {
        // One capture per model instance (fix round 1): the pendingMetadataWrite chain for
        // a SECOND capture on the same model was intermittently slow to land under
        // whole-class load. Each capture below goes through its own fresh model over the
        // same `root`, exactly the shape the reliable single-capture relaunch tests use.
        let recorder = CarryOverFakeRecorder()
        let first = makeModel(recorder: recorder)
        await first.bootstrap()
        await commitBackdatedCapture(first, recorder: recorder, date(1987, 6, 12))
        await waitForSidecar(first, PartialDate(year: 1987, month: 6, day: 12))

        let second = makeModel(recorder: recorder)
        await second.bootstrap()
        XCTAssertFalse(second.backdateEnabled, "sanity: the undated capture below is genuinely undated")
        let live = second.coordinator
        await second.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await second.done()
        await waitUntil({ second.coordinator !== live }, timeout: 10, "capture never finished")

        let relaunched = makeModel()
        await relaunched.bootstrap()
        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
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
        await second.library.rescan()

        second.setBackdateEnabled(true)
        XCTAssertEqual(PartialDate(from: second.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1991, month: 2, day: 3),
                       "the carried 1991 wins over the seed's 2001-01-02")
    }

    /// Journal B's newest entry is invisible when journal A is selected after a relaunch.
    func testSeedDoesNotCrossJournalsAfterRelaunch() async throws {
        // One capture per model instance (fix round 1) — see the comment in
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
        relaunched.setBackdateEnabled(true)
        XCTAssertEqual(PartialDate(from: relaunched.backdateDate, precision: .day,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        // The toggle stays on across the switch: B is pre-filled from B's own history.
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
        XCTAssertNil(model.seededBackdate())
        model.setBackdateEnabled(true)
        XCTAssertEqual(Calendar.gregorianCurrent.component(.year, from: model.backdateDate),
                       Calendar.gregorianCurrent.component(.year, from: Date()))
        XCTAssertEqual(model.backdatePrecision, .day)
    }
}
