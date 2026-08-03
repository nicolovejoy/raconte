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
    private var _lastMatching: AudioFormatDescriptor??
    private var _fedFrames = 0
    var startCount: Int { lock.withLock { _startCount } }
    /// The `matching` argument of the most recent `start` (outer nil = never started).
    var lastMatching: AudioFormatDescriptor?? { lock.withLock { _lastMatching } }

    func start(sink: PCMSink, matching canonical: AudioFormatDescriptor?,
               onLevel: (@Sendable (Float) -> Void)?) throws {
        if let startError { throw startError }
        lock.withLock { self.sink = sink; _startCount += 1; _lastMatching = canonical }
        isRunning = true
        onLevel?(0.5)
    }
    func stop() { isRunning = false }

    /// A nonzero, position-dependent byte pattern. All-zero data would make
    /// every sidecar `sha256Prefix` identical, so byte-identity assertions would
    /// pass vacuously.
    func feed(frames: Int) {
        let s = lock.withLock { sink }
        let start = lock.withLock { () -> Int in let f = _fedFrames; _fedFrames += frames; return f }
        var bytes = [UInt8](repeating: 0, count: frames * kBytesPerFrame)
        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: start &* kBytesPerFrame &+ i) }
        s?.receive(PCMChunk(data: Data(bytes),
                            frameCount: AVAudioFrameCount(frames), sampleRate: 48000))
    }
}

/// Settable test clock for the coordinator's injected `now`.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date { lock.withLock { _now } }
    func advance(by seconds: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(seconds) }
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
                                 flush: Duration = .zero,
                                 capturesRoot: URL? = nil,
                                 machine: CaptureMachine = CaptureMachine(),
                                 resumeBackoff: Duration = .milliseconds(500),
                                 makeSecondarySink: SecondarySinkFactory? = nil,
                                 now: @escaping @Sendable () -> Date = Date.init) -> CaptureCoordinator {
        let root = capturesRoot ?? root!
        return CaptureCoordinator(
            capturesRoot: root,
            session: session,
            makeRecorder: { recorder },
            makeStore: { id, format in
                SegmentStore(capturesRoot: root, captureID: id, format: format,
                             config: .init(rotationDurationSeconds: .infinity, rotationByteCap: byteCap))
            },
            mintCaptureID: { kCaptureID },
            now: now,
            machine: machine,
            flushInterval: flush,
            resumeBackoff: resumeBackoff,
            makeSecondarySink: makeSecondarySink)
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

    private func decodeManifest(_ captureID: String = kCaptureID,
                                root: URL? = nil) throws -> Manifest {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root ?? self.root, captureID: captureID)
        let data = try Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: dir))
        return try CaptureCoding.decoder().decode(Manifest.self, from: data)
    }

    private func decodeSidecar(_ index: Int, root: URL? = nil) throws -> SegmentSidecar {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root ?? self.root, captureID: kCaptureID)
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
        // `send` publishes the phase before realizing disk effects, so the manifest
        // write can still be in flight when the phase flips — wait for the disk too.
        await waitUntil({ [self] in (try? decodeManifest())?.state == .interrupted },
                        "manifest not interrupted on disk")

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
        // Issue #9: the interruption entry must close, not stay open forever.
        XCTAssertEqual(manifest.interruptions.count, 1)
        XCTAssertNotNil(manifest.interruptions[0].endedAt)
        XCTAssertEqual(manifest.interruptions[0].resumed, true)
    }

    // MARK: issue #9 — stopping from `interrupted` closes the entry as not resumed

    func testStopFromInterruptedClosesInterruptionAsNotResumed() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")

        await coordinator.done()
        XCTAssertEqual(coordinator.phase, .captured)

        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.interruptions.count, 1)
        XCTAssertNotNil(manifest.interruptions[0].endedAt,
                        "row 14 (interrupted -> done) must close the open entry")
        XCTAssertEqual(manifest.interruptions[0].resumed, false)
    }

    /// Reacquire keeps failing until the resume-retry budget is exhausted (rows
    /// 10/11): the machine gives up straight to `captured` without ever resuming.
    /// That interruption never ended either, so it closes the same way a user's
    /// explicit stop-from-interrupted does.
    func testReacquireBudgetExhaustedClosesInterruptionAsNotResumed() async throws {
        let session = FakeSession()
        let recorder = FakeRecorder()
        // A budget of 1 plus a short backoff keeps this test from waiting on the
        // default 3-retry x 500ms schedule: the automatic backoff resume (scheduled
        // by `scheduleResumeBackoff` after every failed reacquire) alone drives the
        // machine straight to giving up.
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          machine: CaptureMachine(resumeRetryBudget: 1),
                                          resumeBackoff: .milliseconds(20))

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")

        // Only now start failing `activate()` — the initial `record()` above must
        // succeed, or the capture never reaches `recording` in the first place.
        session.activateError = CocoaError(.fileWriteUnknown)
        await coordinator.resume()
        await waitUntil({ coordinator.phase == .captured },
                        "budget exhaustion did not reach captured")

        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.interruptions.count, 1)
        XCTAssertNotNil(manifest.interruptions[0].endedAt,
                        "rows 10/11 give-up must close the open entry")
        XCTAssertEqual(manifest.interruptions[0].resumed, false)
    }

    // MARK: 3b — route loss auto-resumes onto the new device (issue #5)

    func testRouteLostAutoResumesOntoNewDevice() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        // macOS device switch / iOS unplug: .routeLost with no resumeAvailable ever
        // following. The coordinator must resume on its own.
        session.emit(.routeLost)
        await waitUntil({ coordinator.phase == .recording && recorder.startCount >= 2 },
                        "did not auto-resume after route loss")
        // Resume pins the engine to the capture's canonical format (new device's
        // rate may differ; segments must stay at one rate).
        XCTAssertEqual(recorder.lastMatching, recorder.captureFormatDescriptor)

        recorder.feed(frames: 250)
        await coordinator.done()
        XCTAssertEqual(coordinator.phase, .captured)

        let s0 = try decodeSidecar(0)
        let s1 = try decodeSidecar(1)
        XCTAssertEqual(s0.frameCount, 750)
        XCTAssertEqual(s0.closedReason, .interruption)
        XCTAssertEqual(s1.frameCount, 250)
        XCTAssertEqual(s1.startFrameOffset, 750)   // gap-free across the switch

        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.interruptions.first?.kind, "routeChange")
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

    // MARK: doc test 20 — capture spanning midnight stays one continuous entry

    func testMidnightCrossingStaysOneContinuousCapture() async throws {
        // 23:59:00 UTC on an arbitrary day; nothing in the pipeline is calendar-keyed,
        // this pins that property (no date-based splitting, sane duration math).
        let clock = MutableClock(Date(timeIntervalSince1970: 20_000 * 86_400 - 60))
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          now: { clock.now })

        await coordinator.record()
        recorder.feed(frames: 750)
        clock.advance(by: 120)          // cross midnight
        recorder.feed(frames: 250)
        await coordinator.done()

        XCTAssertEqual(coordinator.phase, .captured)
        XCTAssertEqual(coordinator.elapsed, 120, accuracy: 0.01)

        // One capture directory, one continuous segment chain — no split at the day
        // boundary.
        let dirs = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(dirs.count, 1)
        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.lastKnownFrameOffset, 1000)
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

    // MARK: M2 T1 — the tee is invisible to the disk path

    /// Counts chunks and frames, optionally doing slow or self-failing work.
    private final class CountingSink: PCMSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _chunks = 0
        private var _frames = 0
        private let body: (@Sendable () -> Void)?

        init(body: (@Sendable () -> Void)? = nil) { self.body = body }

        var chunks: Int { lock.withLock { _chunks } }
        var frames: Int { lock.withLock { _frames } }

        nonisolated func receive(_ chunk: PCMChunk) {
            lock.withLock { _chunks += 1; _frames += Int(chunk.frameCount) }
            body?()
        }
    }

    /// Drive an identical capture script over `root`, with whatever second branch
    /// the caller supplies. `FakeRecorder.feed` is synchronous, so this is
    /// deterministic rather than timing-dependent.
    private func runIdenticalScript(root: URL, secondary: SecondarySinkFactory?) async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          byteCap: 4000, capturesRoot: root,
                                          makeSecondarySink: secondary)
        await coordinator.record()
        recorder.feed(frames: 500)
        recorder.feed(frames: 500)
        recorder.feed(frames: 500)
        await coordinator.done()
        XCTAssertEqual(coordinator.phase, .captured)
    }

    private func makeRoot(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The bytes on disk must not depend on what else is hanging off the tee —
    /// including a branch that sleeps or fails internally.
    func testSecondBranchDoesNotChangeTheBytesOnDisk() async throws {
        let baselineRoot = try makeRoot("baseline")
        try await runIdenticalScript(root: baselineRoot, secondary: nil)

        let variants: [(String, SecondarySinkFactory)] = [
            ("noop", { _ in CountingSink() }),
            ("slow", { _ in CountingSink(body: { Thread.sleep(forTimeInterval: 0.05) }) }),
            ("failing", { _ in CountingSink(body: {
                do { throw CocoaError(.fileWriteNoPermission) } catch { /* absorbed */ }
            }) }),
        ]

        for (name, factory) in variants {
            let variantRoot = try makeRoot(name)
            try await runIdenticalScript(root: variantRoot, secondary: factory)

            let baseManifest = try decodeManifest(root: baselineRoot)
            let manifest = try decodeManifest(root: variantRoot)
            XCTAssertEqual(manifest.state, baseManifest.state, name)
            XCTAssertEqual(manifest.segmentCount, baseManifest.segmentCount, name)
            XCTAssertEqual(manifest.lastKnownFrameOffset, baseManifest.lastKnownFrameOffset, name)
            XCTAssertGreaterThan(manifest.segmentCount, 1, "\(name): script should rotate")

            for index in 0..<manifest.segmentCount {
                let baseSidecar = try decodeSidecar(index, root: baselineRoot)
                let sidecar = try decodeSidecar(index, root: variantRoot)
                XCTAssertEqual(sidecar.frameCount, baseSidecar.frameCount, "\(name) seg \(index)")
                XCTAssertEqual(sidecar.startFrameOffset, baseSidecar.startFrameOffset, "\(name) seg \(index)")
                XCTAssertEqual(sidecar.byteCount, baseSidecar.byteCount, "\(name) seg \(index)")
                XCTAssertEqual(sidecar.closedReason, baseSidecar.closedReason, "\(name) seg \(index)")
                XCTAssertEqual(sidecar.format, baseSidecar.format, "\(name) seg \(index)")
                // The nonzero feed pattern makes this a real check, not a
                // constant-hash comparison.
                XCTAssertEqual(sidecar.sha256Prefix, baseSidecar.sha256Prefix, "\(name) seg \(index)")
                XCTAssertNotEqual(sidecar.sha256Prefix, "", "\(name) seg \(index)")

                XCTAssertEqual(try pcmBytes(root: variantRoot, index: index),
                               try pcmBytes(root: baselineRoot, index: index),
                               "\(name): segment \(index) bytes differ")
            }
        }
    }

    private func pcmBytes(root: URL, index: Int) throws -> Data {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: kCaptureID)
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        return try Data(contentsOf: SegmentLayout.pcmURL(segmentsDirectory: segs, index: index))
    }

    /// The regression that matters: the resume `recorder.start` must install the
    /// SAME tee. Wire the second branch only at `configureAndStart` and this fails
    /// at 750 frames while every on-disk assertion stays green.
    func testSecondBranchSurvivesInterruptionResume() async throws {
        let counter = CountingSink()
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          makeSecondarySink: { _ in counter })

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")

        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ coordinator.phase == .recording }, "did not resume")

        recorder.feed(frames: 250)
        await coordinator.done()
        XCTAssertEqual(coordinator.phase, .captured)

        XCTAssertEqual(counter.frames, 1000,
                       "second branch missed the post-resume audio — the resume start "
                       + "is not passing the tee")
        XCTAssertEqual(counter.chunks, 2)
    }

    func testSecondBranchSurvivesRouteLossResume() async throws {
        let counter = CountingSink()
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          makeSecondarySink: { _ in counter })

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.routeLost)
        await waitUntil({ coordinator.phase == .recording && recorder.startCount >= 2 },
                        "did not auto-resume after route loss")

        recorder.feed(frames: 250)
        await coordinator.done()
        XCTAssertEqual(counter.frames, 1000, "second branch died at the route switch")
    }

    // MARK: M2 T1 — factory + published active IDs

    func testSecondarySinkFactoryIsCalledOncePerCaptureWithTheCaptureID() async throws {
        let box = FactoryLog()
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          makeSecondarySink: { id in
                                              box.note(id); return CountingSink()
                                          })
        await coordinator.record()
        recorder.feed(frames: 100)
        await coordinator.done()

        XCTAssertEqual(box.ids, [kCaptureID], "factory must run once per capture, not per start")
    }

    func testSecondarySinkFactoryIsNotCalledWhenPermissionIsDenied() async throws {
        let box = FactoryLog()
        let session = FakeSession(); session.permissionGranted = false
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          makeSecondarySink: { id in
                                              box.note(id); return CountingSink()
                                          })
        await coordinator.record()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(box.ids.isEmpty, "no sink should be built for a capture that never starts")
    }

    private final class FactoryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        func note(_ id: String) { lock.withLock { _ids.append(id) } }
        var ids: [String] { lock.withLock { _ids } }
    }

    func testActiveCaptureIDAndFormatLifecycle() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        XCTAssertNil(coordinator.activeCaptureID)
        XCTAssertNil(coordinator.activeFormat)

        await coordinator.record()
        XCTAssertEqual(coordinator.activeCaptureID, kCaptureID)
        XCTAssertEqual(coordinator.activeFormat, recorder.captureFormatDescriptor)

        recorder.feed(frames: 100)
        await coordinator.done()

        // Cleared with the rest of the wiring at `captured` — an owner that needs
        // the ID has to latch it at the preparing->recording edge.
        XCTAssertNil(coordinator.activeCaptureID)
        XCTAssertNil(coordinator.activeFormat)
        XCTAssertEqual(coordinator.finalizeQueue, [kCaptureID])
    }

    /// `activeFormat` is pinned for the life of the capture: resume passes
    /// `matching:` and the tap resamples, so a derived consumer keeps one axis.
    func testActiveFormatIsNotResetOnResume() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        let initial = coordinator.activeFormat
        recorder.feed(frames: 100)
        session.emit(.routeLost)
        await waitUntil({ coordinator.phase == .recording && recorder.startCount >= 2 },
                        "did not auto-resume")
        XCTAssertEqual(coordinator.activeFormat, initial)
        XCTAssertEqual(recorder.lastMatching, initial)
    }
}
