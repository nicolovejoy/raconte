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
    func start(sink: PCMSink, matching canonical: AudioFormatDescriptor?,
               onLevel: (@Sendable (Float) -> Void)?) throws { isRunning = true }
    func stop() { isRunning = false }
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
}
