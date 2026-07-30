import XCTest
import AVFoundation
@testable import Raconte

private let kCaptureID = "01TESTCAPTURE0000000000000"
private let kBytesPerFrame = 4

/// Session whose interruption/resume events the test drives, with controllable
/// permission + activation outcomes.
private final class FakeSession: AudioSessionController, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    var permissionGranted = true
    var activateError: Error?
    private let lock = NSLock()
    private var _activateCount = 0
    private var _deactivateCount = 0
    var activateCount: Int { lock.withLock { _activateCount } }
    var deactivateCount: Int { lock.withLock { _deactivateCount } }

    init() { (events, cont) = AsyncStream<SessionEvent>.makeStream() }
    func requestPermission() async -> Bool { permissionGranted }
    func activate() async throws {
        lock.withLock { _activateCount += 1 }
        if let activateError { throw activateError }
    }
    func deactivate() { lock.withLock { _deactivateCount += 1 } }
    func emit(_ event: SessionEvent) { cont.yield(event) }
}

/// Recorder fed synthetic PCM by the test via `feed`.
private final class FakeRecorder: EngineRecording, @unchecked Sendable {
    var isRunning = false
    var captureFormatDescriptor: AudioFormatDescriptor? =
        AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false)
    var startError: Error?
    private let lock = NSLock()
    private var sink: PCMSink?
    private var _startCount = 0
    var startCount: Int { lock.withLock { _startCount } }

    func start(sink: PCMSink, onLevel: (@Sendable (Float) -> Void)?) throws {
        if let startError { throw startError }
        lock.withLock { self.sink = sink; _startCount += 1 }
        isRunning = true
        onLevel?(0.5)
    }
    func stop() { isRunning = false }

    func feed(frames: Int) {
        let s = lock.withLock { sink }
        s?.receive(PCMChunk(data: Data(count: frames * kBytesPerFrame),
                            frameCount: AVAudioFrameCount(frames), sampleRate: 48000))
    }
}

@MainActor
final class CaptureCoordinatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Builders

    private func makeCoordinator(session: FakeSession, recorder: FakeRecorder,
                                 byteCap: Int = .max,
                                 flush: Duration = .zero) -> CaptureCoordinator {
        let root = root!
        return CaptureCoordinator(
            capturesRoot: root,
            session: session,
            makeRecorder: { recorder },
            makeStore: { id, format in
                SegmentStore(capturesRoot: root, captureID: id, format: format,
                             config: .init(rotationDurationSeconds: .infinity, rotationByteCap: byteCap))
            },
            mintCaptureID: { kCaptureID },
            flushInterval: flush)
    }

    private func waitUntil(_ predicate: @escaping () -> Bool,
                           timeout: TimeInterval = 3,
                           _ message: String = "condition not met",
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func decodeManifest(_ captureID: String = kCaptureID) throws -> Manifest {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: captureID)
        let data = try Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: dir))
        return try CaptureCoding.decoder().decode(Manifest.self, from: data)
    }

    private func decodeSidecar(_ index: Int) throws -> SegmentSidecar {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: kCaptureID)
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        let data = try Data(contentsOf: SegmentLayout.sidecarURL(segmentsDirectory: segs, index: index))
        return try CaptureCoding.decoder().decode(SegmentSidecar.self, from: data)
    }

    // MARK: 1 — full lifecycle: record -> chunks -> rotation -> Done -> captured on disk

    func testFullLifecycleProducesCapturedManifestAndSegments() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder, byteCap: 4000)

        await coordinator.record()
        XCTAssertEqual(coordinator.phase, .recording)

        // 6 chunks of 500 frames (2000 B) → rotate at every 2nd chunk → 3 finalized segments.
        for _ in 0..<6 { recorder.feed(frames: 500) }
        await coordinator.done()

        XCTAssertEqual(coordinator.phase, .captured)

        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.segmentCount, 3)
        XCTAssertEqual(manifest.lastKnownFrameOffset, 3000)

        for i in 0..<3 {
            let s = try decodeSidecar(i)
            XCTAssertEqual(s.frameCount, 1000)
            XCTAssertEqual(s.startFrameOffset, i * 1000)
        }
        // Captured recording is handed to the finalizer queue (T8 surface).
        XCTAssertEqual(coordinator.finalizeQueue, [kCaptureID])
    }

    // MARK: 2 — interruption mid-recording closes the live segment, state interrupted

    func testInterruptionClosesSegmentAndEntersInterrupted() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not reach interrupted")

        let s0 = try decodeSidecar(0)
        XCTAssertEqual(s0.frameCount, 750)
        XCTAssertEqual(s0.closedReason, .interruption)

        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.state, .interrupted)
        XCTAssertEqual(manifest.interruptions.count, 1)
        XCTAssertEqual(manifest.interruptions.first?.kind, "interruption")
    }

    // MARK: 3 — resume continues the SAME capture gap-free

    func testResumeContinuesSameCaptureGapFree() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")

        // Interruption ended with shouldResume → auto-resume.
        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ coordinator.phase == .recording }, "did not resume")
        XCTAssertGreaterThanOrEqual(recorder.startCount, 2)   // engine reacquired

        recorder.feed(frames: 250)
        await coordinator.done()
        XCTAssertEqual(coordinator.phase, .captured)

        let s0 = try decodeSidecar(0)
        let s1 = try decodeSidecar(1)
        XCTAssertEqual(s0.frameCount, 750)
        XCTAssertEqual(s0.startFrameOffset, 0)
        XCTAssertEqual(s1.frameCount, 250)
        XCTAssertEqual(s1.startFrameOffset, 750)   // gap-free chain across the resume

        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.segmentCount, 2)
        XCTAssertEqual(manifest.lastKnownFrameOffset, 1000)
    }

    // MARK: 4 — launch recovery of a pre-seeded crashed capture

    func testLaunchRecoveryRebuildsCrashedCapture() async throws {
        // Seed a crashed capture: a bare live .pcm.part (1.0s), no sidecar, no manifest.
        let id = "01RECOVER00000000000000000"
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        let frames = 48000                       // 1.0s @ 48 kHz mono Float32
        let partURL = SegmentLayout.pcmPartURL(segmentsDirectory: segs, index: 0)
        try Data(count: frames * kBytesPerFrame).write(to: partURL)

        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)
        await coordinator.recoverAtLaunch()

        // Banner + finalize queue populated.
        XCTAssertEqual(coordinator.recoveredRecordings.count, 1)
        XCTAssertEqual(coordinator.recoveredRecordings.first?.captureID, id)
        XCTAssertEqual(coordinator.recoveredRecordings.first?.durationSeconds ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.recoveredRecordings.first?.formattedDuration, "0:01")
        XCTAssertTrue(coordinator.finalizeQueue.contains(id))

        // On disk: .part normalized to .pcm + sidecar regenerated + captured manifest.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0).path))
        let manifest = try decodeManifest(id)
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.segmentCount, 1)
        XCTAssertEqual(manifest.lastKnownFrameOffset, frames)
    }

    // MARK: 5 — effect order: manifest before the state-dependent side effect

    func testEffectOrderManifestBeforeSideEffect() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()

        let log = coordinator.executedEffectLog
        let manifestIdx = log.firstIndex {
            if case .writeManifest(let u) = $0, u.state == .preparing { return true }
            return false
        }
        let configureIdx = log.firstIndex { $0 == .requestPermissionAndConfigure }
        XCTAssertNotNil(manifestIdx)
        XCTAssertNotNil(configureIdx)
        // Write-ahead: the preparing manifest is emitted before the configure side effect.
        XCTAssertLessThan(manifestIdx!, configureIdx!)
    }

    // MARK: permission denied returns to idle, nothing on disk

    func testPermissionDeniedReturnsToIdle() async throws {
        let session = FakeSession(); session.permissionGranted = false
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.lastError, "Microphone access denied")
        XCTAssertTrue(coordinator.finalizeQueue.isEmpty)
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: kCaptureID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
