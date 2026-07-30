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

        await waitUntil({ model.finished.isEmpty == false }, "finished list never refreshed")
        XCTAssertEqual(encoder.calls.count, 1, "encoder must run in-session, not at next launch")
        XCTAssertTrue(model.coordinator !== liveCoordinator,
                      "model should reset to a fresh idle coordinator after the commit")

        let captureID = liveCoordinator.finalizeQueue[0]
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: captureID)
        let m4a = SegmentLayout.finalRecordingURL(captureDirectory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path),
                      "final m4a missing — live finalize did not complete")
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
}
