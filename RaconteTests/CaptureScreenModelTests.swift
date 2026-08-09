import XCTest
import AVFAudio
@testable import Raconte

private final class ModelFakeSession: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    init() { (events, cont) = AsyncStream<SessionEvent>.makeStream() }
    func requestPermission() async -> Bool { true }
    func activate() async throws {}
    func deactivate() {}
}

private final class ModelFakeRecorder: EngineRecording, @unchecked Sendable {
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

@MainActor
final class CaptureScreenModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureScreenModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
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

    /// Regression (macOS smoke run 8): finalize must run in-session after Done. The
    /// old wiring keyed off the phase flipping to `.captured`, which happens BEFORE
    /// the commit effects fill `finalizeQueue` — the drain no-op'd and the m4a only
    /// ever appeared via next-launch recovery. `handleFinalizeQueue` keys off the
    /// queue itself.
    func testDoneFinalizesInSessionWithoutRelaunch() async throws {
        let recorder = ModelFakeRecorder()
        let encoder = FakeAudioEncoder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: encoder)
        await model.bootstrap()
        let liveCoordinator = model.coordinator

        await model.record()
        recorder.feed(frames: 1000)
        await model.done()

        // The flush window commits the capture, then enqueueFinalize fills the queue.
        await waitUntil({ liveCoordinator.finalizeQueue.isEmpty == false },
                        "capture never committed to finalizeQueue")

        // Simulate the view's onChange(of: finalizeQueue) relay.
        model.handleFinalizeQueue()

        await waitUntil({ model.library.items.isEmpty == false }, "library never refreshed")
        XCTAssertEqual(encoder.calls.count, 1, "encoder must run in-session, not at next launch")
        XCTAssertTrue(model.coordinator !== liveCoordinator,
                      "model should reset to a fresh idle coordinator after the commit")

        let captureID = liveCoordinator.finalizeQueue[0]
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: captureID)
        let m4a = SegmentLayout.finalRecordingURL(captureDirectory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path),
                      "final m4a missing — live finalize did not complete")
    }

    /// Doc test 22 (rapid start/stop cycles): every cycle must land as its own
    /// finalized entry — none merged, none dropped, no stuck non-idle state after.
    ///
    /// Investigated as a suspected #4/#22/08-07-family flake ("cycle 4 never
    /// committed", 733/734 in a full-suite CI run). Unlike that family, this loop
    /// already polls the correct terminal signal (`finalizeQueue`, not `phase`), and
    /// `finalizeQueue.append` runs in the SAME MainActor continuation as its own
    /// trigger (`completeCapture()` has no `await` before the append) — there is no
    /// competing task that can observe a "done" marker before this one lands, unlike
    /// the confirmed race in `testFailedResumeDiskWriteReturnsToInterruptedNotRecording`
    /// below. Reproduction attempts (24-spinner CPU load, a full 771-test suite run
    /// under that load, and reading every intermediate await in the `.done` →
    /// `.tailDrained` → `drainAndFinish` chain) found no wrong-value read — only that
    /// each cycle pays a real, unavoidable ~300ms `flushInterval` sleep plus real
    /// `SegmentStore` disk I/O (this test uses the real store, not a fake), so the
    /// per-cycle budget genuinely has less headroom than the family's microsecond-
    /// scale races. Widened from the default 5s accordingly — a right-sized bound for
    /// confirmed-non-racy real I/O, not a blind timeout bump.
    func testRapidRecordDoneCyclesProduceTenSeparateEntries() async throws {
        let recorder = ModelFakeRecorder()
        let encoder = FakeAudioEncoder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: encoder)
        await model.bootstrap()

        for cycle in 1...10 {
            let live = model.coordinator
            await model.record()
            recorder.feed(frames: 100)
            await model.done()
            await waitUntil({ live.finalizeQueue.isEmpty == false }, timeout: 15,
                            "cycle \(cycle) never committed")
            model.handleFinalizeQueue()   // the view's onChange relay
            await waitUntil({ model.library.items.count == cycle && model.coordinator !== live }, timeout: 15,
                            "cycle \(cycle) did not finalize + respawn")
        }

        XCTAssertEqual(model.library.items.count, 10)
        XCTAssertEqual(Set(model.library.items.map(\.captureID)).count, 10, "entries must be distinct")
        XCTAssertEqual(encoder.calls.count, 10)
        XCTAssertEqual(model.coordinator.phase, .idle, "stuck non-idle state after last cycle")
    }

    /// Doc test 7 (idle relaunch): a fresh launch over a root holding only complete
    /// captures shows no spurious recovery banner and keeps the entries playable.
    func testIdleRelaunchShowsNoSpuriousRecoveryBannerAndKeepsRecordings() async throws {
        let recorder = ModelFakeRecorder()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder())
        await model.bootstrap()
        let live = model.coordinator
        await model.record()
        recorder.feed(frames: 1000)
        await model.done()
        await waitUntil({ live.finalizeQueue.isEmpty == false }, "capture never committed")
        model.handleFinalizeQueue()
        await waitUntil({ model.library.items.count == 1 }, "capture never finalized")

        // "Relaunch": a brand-new model over the same root.
        let relaunch = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder())
        await relaunch.bootstrap()

        XCTAssertTrue(relaunch.visibleRecovered.isEmpty, "spurious recovery banner")
        XCTAssertEqual(Set(relaunch.library.items.map(\.captureID)),
                       Set(model.library.items.map(\.captureID)))
    }

    /// Launch-recovery fills the queue while the phase is idle — the onChange relay
    /// must NOT respawn the coordinator then (bootstrap drains that queue itself).
    func testLaunchRecoveryQueueDoesNotRespawnCoordinator() async throws {
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: FakeAudioEncoder())
        await model.bootstrap()
        let coordinator = model.coordinator
        model.handleFinalizeQueue()   // queue empty and/or phase idle → no-op
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.coordinator === coordinator)
    }

    // MARK: - T6c: finalize wiring promotes revision zero

    /// The finalize call-site wiring (design §5's brief, step 4.6): after a capture
    /// finalizes with a real transcript, it must end up with exactly one canonical
    /// revision whose `coverageFrames` is non-nil — non-nil specifically PROVES
    /// promotion ran after `recordTranscriptRef` wrote `manifest.transcript`, not
    /// before it (the mutation check below).
    ///
    /// Drives a real `LiveTranscriptionCoordinator` over a `ScriptedTranscriptionEngine`
    /// (no models, no hardware — same fake `TranscriptionSessionTests` uses) so
    /// `recordTranscriptRef` has a real `TranscriptRef` to write, exactly as it would
    /// on device.
    func testFinalizePromotesRevisionZeroWithNonNilCoverageAfterTranscriptRefIsRecorded() async throws {
        let recorder = ModelFakeRecorder()
        let engine = ScriptedTranscriptionEngine()
        let transcription = LiveTranscriptionCoordinator(capturesRoot: root, makeEngine: { engine })
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: FakeAudioEncoder(),
            makeSecondarySink: { [weak transcription] id in transcription?.begin(captureID: id) },
            transcription: transcription)
        await model.bootstrap()

        await model.record()
        model.handlePhase()   // the view's onChange(of: phase) relay — activates transcription
        let captureID = try XCTUnwrap(model.coordinator.activeCaptureID)

        await waitUntil({ engine.calls.contains(.start) }, "transcription engine never started")

        recorder.feed(frames: 4_800)
        engine.emit(TranscriptResult(text: "hello", range: FrameRange(start: 0, end: 4_800),
                                     isVolatile: false, confidence: nil))

        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: captureID)
        await waitUntil({ !LiveTranscriptReader.load(captureDirectory: dir).records.isEmpty },
                        "committed result never reached live.jsonl")

        await model.done()
        await waitUntil({ model.coordinator.finalizeQueue.isEmpty == false },
                        "capture never committed to finalizeQueue")
        model.handleFinalizeQueue()

        await waitUntil({ model.library.items.contains { $0.captureID == captureID } },
                        "library never refreshed after finalize")

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: dir)
        XCTAssertEqual(chain?.revisions.count, 1, "exactly one canonical revision after finalize")
        let revision = try XCTUnwrap(chain?.revisions.first)
        XCTAssertEqual(revision.source, .machineLive)
        XCTAssertNotNil(revision.coverageFrames,
                        "coverageFrames must be copied from the manifest.transcript ref "
                        + "recordTranscriptRef just wrote — proves promotion ran AFTER it")
    }
}
