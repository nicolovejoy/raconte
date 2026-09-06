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
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
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
}
