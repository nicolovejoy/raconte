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
        XCTAssertNotNil(manifest.interruptions[0].closedAt)
        XCTAssertEqual(manifest.interruptions[0].resumed, true)
        // Issue #19: `resumeAvailable` IS a system-reported end signal, so `endedAt`
        // must be known here too, not just `closedAt`.
        XCTAssertNotNil(manifest.interruptions[0].endedAt,
                        "resumeAvailable is a known system end signal")
    }

    /// Issue #19: `endedAt` must be the moment `resumeAvailable` was received, not
    /// the (potentially much later) moment reacquire actually finishes and closes
    /// the entry. A mocked coordinator clock pins `endedAt` to an arbitrary fixed
    /// instant unrelated to wall-clock "now"; the store's own `closedAt` stamp (real
    /// `.live` clock, since this test's `makeStore` closure injects none) lands at
    /// the real current time — so the two are provably different values, proving
    /// `endedAt` was actually threaded through rather than re-derived from `closedAt`.
    func testResumeAvailableEndedAtIsTheReceiptMomentNotTheReacquireMoment() async throws {
        let mockedInstant = Date(timeIntervalSince1970: 20_000 * 86_400)
        let clock = MutableClock(mockedInstant)
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          now: { clock.now })

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")

        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ coordinator.phase == .recording }, "did not resume")

        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.interruptions.count, 1)
        XCTAssertEqual(manifest.interruptions[0].endedAt, mockedInstant,
                       "endedAt must be the mocked clock's value at resumeAvailable receipt")
        let closedAt = try XCTUnwrap(manifest.interruptions[0].closedAt)
        XCTAssertNotEqual(closedAt, mockedInstant,
                          "closedAt is the store's own real-clock stamp, independent of endedAt")
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
        XCTAssertNotNil(manifest.interruptions[0].closedAt,
                        "row 14 (interrupted -> done) must close the open entry")
        XCTAssertEqual(manifest.interruptions[0].resumed, false)
        // Issue #19: the Done tap is not a system signal for when the interruption
        // actually ended — that must stay honestly nil, not the tap's own moment.
        XCTAssertNil(manifest.interruptions[0].endedAt,
                    "the owner's Done tap must not be fabricated as the interruption's true end")
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
        // `send()` publishes the phase before the commit effects reach disk (the
        // issue #4 race, which was fixed in the sibling tests above but not here):
        // gating on `.captured` alone reads the manifest with the interruption
        // still open. Poll the artifact this test is actually asserting on.
        await waitUntil({ [self] in
            (try? decodeManifest())?.interruptions.first?.closedAt != nil
        }, "give-up did not close the interruption on disk")

        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.interruptions.count, 1)
        XCTAssertNotNil(manifest.interruptions[0].closedAt,
                        "rows 10/11 give-up must close the open entry")
        XCTAssertEqual(manifest.interruptions[0].resumed, false)
        // Issue #19: giving up on the retry budget never learns when the
        // interruption actually ended — must stay honestly nil.
        XCTAssertNil(manifest.interruptions[0].endedAt,
                    "giving up is not a system end signal")
    }

    // MARK: issue #20 — a failed resume must never leave a running timer over a
    // capture that writes nothing.

    /// Make the capture's `segments/` directory unwritable, so
    /// `SegmentStore.resumeRecording` persists the `recording` manifest and then
    /// fails to `open()` the next segment — the exact split the issue describes.
    /// The capture directory itself stays writable, so the coordinator's failure
    /// handling can still persist its manifest write.
    @discardableResult
    private func sealSegmentsDirectory(_ sealed: Bool) throws -> URL {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: kCaptureID)
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        try FileManager.default.setAttributes([.posixPermissions: sealed ? 0o555 : 0o755],
                                              ofItemAtPath: segs.path)
        return segs
    }

    /// Make every manifest write fail while leaving `segments/` writable:
    /// `AtomicFile.replace` creates `manifest.json.part` in — and renames within — the
    /// capture directory, both of which need write permission on it. `segments/` is a
    /// subdirectory and is unaffected by its parent's mode.
    @discardableResult
    private func sealCaptureDirectory(_ sealed: Bool) throws -> URL {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: kCaptureID)
        try FileManager.default.setAttributes([.posixPermissions: sealed ? 0o555 : 0o755],
                                              ofItemAtPath: dir.path)
        return dir
    }

    /// Retry budget left: the machine must land back in `interrupted` (blinking,
    /// Done offered, clock stopped), NOT `recording`, and the failure must be on
    /// disk for launch recovery to see.
    func testFailedResumeDiskWriteReturnsToInterruptedNotRecording() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        // A long backoff keeps the state observable: the automatic retry must not
        // race the assertions.
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          resumeBackoff: .seconds(30))

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")
        await waitUntil({ [self] in (try? decodeManifest())?.state == .interrupted },
                        "manifest not interrupted on disk")

        try sealSegmentsDirectory(true)
        defer { try? sealSegmentsDirectory(false) }

        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ [self] in (try? decodeManifest())?.retryCount == 1 },
                        "failed resume was never accounted for on disk")

        XCTAssertEqual(coordinator.phase, .interrupted,
                       "a resume whose disk write failed must not publish `recording`")

        // `lastError` is assigned on the MainActor strictly AFTER the `retryCount`
        // write's `await` returns (`handleReacquireResult`) — a separate, later step
        // of the same transition, not the same synchronous continuation. A task
        // polling the on-disk manifest directly (as above) can therefore observe
        // `retryCount == 1` while `lastError` is still nil: the #4/#22/08-07 family
        // shape, one hop later. This was previously masked only by the elapsed-clock
        // sleep below being incidentally long enough to cover it (flake report
        // 2026-08-07); wait for the actual signal instead of relying on that.
        await waitUntil({ coordinator.lastError != nil },
                        "resume failure never surfaced on lastError")

        let elapsed = coordinator.elapsed
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(coordinator.elapsed, elapsed, accuracy: 0.001,
                       "the elapsed clock must not run over a capture that writes nothing")

        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.state, .interrupted)
        XCTAssertNotNil(manifest.lastError,
                        "launch recovery must be able to see that the resume failed")
        // The interruption never ended: the entry stays OPEN so a later resume (or
        // give-up) closes it truthfully.
        XCTAssertEqual(manifest.interruptions.count, 1)
        XCTAssertNil(manifest.interruptions[0].closedAt,
                     "a failed resume must not stamp the interruption as resumed")
        XCTAssertNotNil(coordinator.lastError, "the owner must be told the resume failed")

        // The audio recorded before the interruption is untouched.
        let s0 = try decodeSidecar(0)
        XCTAssertEqual(s0.frameCount, 750)
    }

    /// Budget exhausted: the machine gives up to `captured`, the pre-interruption
    /// audio is queued for finalize, and the interruption closes as NOT resumed.
    func testFailedResumeDiskWriteGivesUpToCapturedWithAudioIntact() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          machine: CaptureMachine(resumeRetryBudget: 0),
                                          resumeBackoff: .milliseconds(20))

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")
        await waitUntil({ [self] in (try? decodeManifest())?.state == .interrupted },
                        "manifest not interrupted on disk")

        try sealSegmentsDirectory(true)
        defer { try? sealSegmentsDirectory(false) }

        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ coordinator.phase == .captured },
                        "a failed resume with no budget left must give up to captured")
        // Same issue #4 race: `.captured` is published ahead of the commit effects
        // that fill `finalizeQueue` and close the interruption on disk.
        await waitUntil({ [self] in
            coordinator.finalizeQueue == [kCaptureID]
                && (try? decodeManifest())?.interruptions.first?.closedAt != nil
        }, "give-up commit effects did not land")

        XCTAssertEqual(coordinator.finalizeQueue, [kCaptureID],
                       "the audio that WAS recorded must still reach the finalizer")
        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.interruptions.count, 1)
        XCTAssertEqual(manifest.interruptions[0].resumed, false,
                       "the resume failed — the log must not claim it succeeded")
        XCTAssertNotNil(manifest.interruptions[0].closedAt)

        let s0 = try decodeSidecar(0)
        XCTAssertEqual(s0.frameCount, 750)
        XCTAssertEqual(s0.startFrameOffset, 0)
    }

    // MARK: issue #24 — every path to `captured` releases the audio session

    /// Rows 10/11 give-up: the reacquire budget runs out and the machine lands in
    /// `captured` without ever passing through `drainAndFinish`, which used to be the
    /// only place that deactivated. The session must be released here too.
    func testGiveUpPathDeactivatesTheAudioSession() async throws {
        let session = FakeSession()
        let recorder = FakeRecorder()
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
        // Same issue #4 race as the two tests above: `.captured` is published before
        // the give-up path's side effects run, so asserting the count straight off the
        // phase reads 0. Wait for the release, then still assert the exact count so a
        // double-deactivate regression stays caught.
        await waitUntil({ session.deactivateCount >= 1 },
                        "giving up did not release the audio session")

        XCTAssertEqual(session.deactivateCount, 1,
                       "giving up on the retry budget must release the audio session")
    }

    /// Row 14 (Done tapped while interrupted) reaches `captured` by the same shortcut.
    /// Issue #24 names only the give-up path; this is the second leak it does not name.
    func testStopFromInterruptedDeactivatesTheAudioSession() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")

        await coordinator.done()
        XCTAssertEqual(coordinator.phase, .captured)
        XCTAssertEqual(session.deactivateCount, 1,
                       "stopping from interrupted must release the audio session")
    }

    /// GUARD. Fails at 2 if the `session.deactivate()` deleted from `drainAndFinish`
    /// is left in place alongside the new one in `completeCapture()`.
    func testNormalStopDeactivatesExactlyOnce() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        await coordinator.done()

        XCTAssertEqual(coordinator.phase, .captured)
        XCTAssertEqual(session.deactivateCount, 1,
                       "the normal stop must deactivate once, not twice")
    }

    /// GUARD. Fails at 2 if the new `session.deactivate()` is moved from
    /// `completeCapture()` into `resetCaptureWiring()`, which `handlePrepareFailed`
    /// calls *after* deactivating itself.
    func testPrepareFailureDeactivatesExactlyOnce() async throws {
        let session = FakeSession(); session.permissionGranted = false
        let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.lastError, "Microphone access denied")
        XCTAssertEqual(session.deactivateCount, 1,
                       "a failed prepare must deactivate once, not twice")
    }

    // MARK: issue #23 — a swallowed manifest write is recorded, not discarded

    /// The interruption still happens and the segment still closes; only the manifest
    /// write fails. Before the fix the failure was dropped on the floor by `try?`.
    func testFailedInterruptedManifestWriteSetsLastErrorAndStillInterrupts() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)

        let dir = try sealCaptureDirectory(true)
        defer { try? sealCaptureDirectory(false) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path),
                      "running as root — permissions cannot be made to bite")

        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")
        // `send` publishes the phase before realizing disk effects, so the failed write
        // lands after the phase flips — the same race test 2 documents.
        await waitUntil({ coordinator.lastError != nil },
                        "the failed manifest write was never surfaced")

        XCTAssertEqual(coordinator.lastError,
                       "Couldn't save recording status. The audio is safe.")
        // Proof the write really failed, rather than the test proving nothing.
        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.state, .recording,
                       "the manifest write failed, so disk must still read `recording`")
        // The segment close runs before the manifest write and is unaffected.
        let s0 = try decodeSidecar(0)
        XCTAssertEqual(s0.frameCount, 750)
        XCTAssertEqual(s0.closedReason, .interruption)
    }

    /// The lie issue #23 names: the screen says Saved while the manifest still reads
    /// `interrupted`. The audio is safe either way — relaunch recovery rebuilds the
    /// manifest from the segments — but the owner must be told.
    func testFailedCapturedManifestWriteSetsLastErrorAndStillSaves() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")
        await waitUntil({ [self] in (try? decodeManifest())?.state == .interrupted },
                        "manifest not interrupted on disk")

        let dir = try sealCaptureDirectory(true)
        defer { try? sealCaptureDirectory(false) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path),
                      "running as root — permissions cannot be made to bite")

        await coordinator.done()

        XCTAssertEqual(coordinator.phase, .captured)
        XCTAssertEqual(coordinator.finalizeQueue, [kCaptureID],
                       "the audio must still reach the finalizer")
        let manifest = try decodeManifest()
        XCTAssertEqual(manifest.state, .interrupted,
                       "the write failed, so disk still reads `interrupted` while the UI says Saved")
        XCTAssertEqual(coordinator.lastError,
                       "Couldn't save recording status. The audio is safe.")
    }

    /// GUARD. Fails with the generic store-write line if the resume-failure message in
    /// `handleReacquireResult` is assigned BEFORE its `store(setState: .captured, …)`
    /// call instead of after it.
    func testStoreWriteFailureDoesNotClobberTheResumeFailureMessage() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder,
                                          machine: CaptureMachine(resumeRetryBudget: 0),
                                          resumeBackoff: .milliseconds(20))

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")
        await waitUntil({ [self] in (try? decodeManifest())?.state == .interrupted },
                        "manifest not interrupted on disk")

        // Both halves must fail: the resume's disk write AND the give-up's `.captured`
        // manifest write. LIFO `defer` unseals innermost (segments/) first.
        let dir = try sealCaptureDirectory(true)
        defer { try? sealCaptureDirectory(false) }
        try sealSegmentsDirectory(true)
        defer { try? sealSegmentsDirectory(false) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path),
                      "running as root — permissions cannot be made to bite")

        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ coordinator.phase == .captured },
                        "a failed resume with no budget left must give up to captured")
        // Issue #4's race once more. `send` publishes `.captured` BEFORE it realizes the
        // transition, and the specific message is assigned at the END of
        // `handleReacquireResult` — after its own `store(setState: .captured, …)` call.
        // For that whole span `lastError` still holds the generic store-write line left
        // by the failed `store(setState: .resuming)` write in `rebuildAndReacquire`, so
        // asserting straight off the phase reads the generic line and fails. (CI run
        // 31149494129 did exactly that.) `finalizeQueue` is filled by `completeCapture()`
        // — the last step of the give-up path, strictly after the assignment — so it is
        // the honest "this path has finished" marker. The manifest cannot serve as one
        // here: the capture directory is sealed, so it never reaches `.captured` on disk.
        await waitUntil({ coordinator.finalizeQueue == [kCaptureID] },
                        "the give-up path did not run to completion")

        XCTAssertEqual(coordinator.lastError, "Couldn't resume recording. Saved what was recorded.",
                       "the specific resume-failure line must outrank the generic store-write line")
    }

    /// GUARD. Fails if the `self.lastError = …` assignment in the `store(setState:)`
    /// helper is moved out of its `catch` onto the success path.
    func testASuccessfulCaptureLeavesLastErrorNil() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        await coordinator.done()

        XCTAssertEqual(coordinator.phase, .captured)
        XCTAssertNil(coordinator.lastError, "a clean capture must surface no error")
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
        // Issue #19: route loss never gets a `resumeAvailable` signal — the device
        // is simply gone — so `endedAt` must stay nil even though the entry closed
        // as resumed.
        XCTAssertNotNil(manifest.interruptions.first?.closedAt)
        XCTAssertEqual(manifest.interruptions.first?.resumed, true)
        XCTAssertNil(manifest.interruptions.first?.endedAt,
                    "route loss has no 'interruption ended' signal to thread through")
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

    // MARK: T6 §14 step 1 — the frame clock survives resume

    /// The marker frame axis must be one clock per capture. The resume
    /// `recorder.start` reuses the SAME tee, so the clock is inherited; build a
    /// fresh one there and this fails at 250 ≠ 1000 while every on-disk
    /// assertion stays green. Asserted while still `.recording` — the wiring
    /// (and with it `currentCaptureFrame`) is torn down at `done()`.
    func testFrameClockSurvivesInterruptionResume() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")

        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ coordinator.phase == .recording }, "did not resume")

        recorder.feed(frames: 250)

        XCTAssertEqual(coordinator.phase, .recording)
        XCTAssertEqual(coordinator.currentCaptureFrame, 1000,
                       "the frame clock reset across the resume — the resume start "
                       + "is not installing the same tee")

        await coordinator.done()
    }

    func testFrameClockSurvivesRouteLossResume() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.routeLost)
        await waitUntil({ coordinator.phase == .recording && recorder.startCount >= 2 },
                        "did not auto-resume after route loss")

        recorder.feed(frames: 250)

        XCTAssertEqual(coordinator.phase, .recording)
        XCTAssertEqual(coordinator.currentCaptureFrame, 1000,
                       "the frame clock died at the route switch")

        await coordinator.done()
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

    // MARK: T6 §14 step 3 — structure markers

    /// Markers are read back off *disk*, not off the coordinator: the log is the
    /// artifact T7 consumes, and the fixture's constant `mintCaptureID` keeps the
    /// directory addressable after `done()` has nil'd `activeCaptureID`.
    private func loadMarkers(root: URL? = nil) -> MarkerLogReader.LoadResult {
        MarkerLogReader.load(captureDirectory: markerCaptureDirectory(root: root))
    }

    private func markerCaptureDirectory(root: URL? = nil) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: root ?? self.root, captureID: kCaptureID)
    }

    private func transcriptDirectoryExists(root: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: SegmentLayout
            .transcriptDirectory(captureDirectory: markerCaptureDirectory(root: root)).path)
    }

    /// Break `MarkerLogWriter.open()`'s `createDirectory` with a plain FILE where
    /// `transcript/` must go — no chmod, so it bites as root too.
    private func blockTranscriptDirectory() throws {
        try Data("not a directory".utf8)
            .write(to: SegmentLayout.transcriptDirectory(captureDirectory: markerCaptureDirectory()))
    }

    func testMarkParagraphWritesTheRawTapFrame() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        coordinator.markParagraph()

        let markers = loadMarkers().markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.kind, .paragraph)
        XCTAssertEqual(markers.first?.frame, 750, "the raw tap frame, off the frame clock")
        XCTAssertNil(markers.first?.voice, "a paragraph marker carries no voice")
        XCTAssertEqual(coordinator.markerCount, 1)

        await coordinator.done()
    }

    func testMarkVoiceWritesTheMarkerAndPublishesCurrentVoice() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 480)
        coordinator.markVoice(StructureMarker.Voice.littleNico)

        let markers = loadMarkers().markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.kind, .voice)
        XCTAssertEqual(markers.first?.frame, 480)
        XCTAssertEqual(markers.first?.voice, "ln")
        XCTAssertEqual(coordinator.currentVoice, "ln",
                       "the toggle binds `currentVoice`; it must follow the marker")

        await coordinator.done()
    }

    /// #63: the visual marker confirmation needs to know WHICH button's marker just
    /// landed, and `markerCount` alone cannot say. Same honesty rule as the haptic:
    /// `lastMarkerKind` reports what reached disk, so it follows the append, not the tap.
    func testMarkerTapsPublishTheLastMarkerKind() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 480)
        XCTAssertNil(coordinator.lastMarkerKind, "nothing marked yet")

        coordinator.markParagraph()
        XCTAssertEqual(coordinator.lastMarkerKind, .paragraph)

        coordinator.markVoice(StructureMarker.Voice.littleNico)
        XCTAssertEqual(coordinator.lastMarkerKind, .voice)

        await coordinator.done()
    }

    /// A failed append is confirmed by NOTHING — no haptic (existing rule) and no flash:
    /// `lastMarkerKind` must stay nil when the marker never reached disk.
    func testFailedMarkerAppendDoesNotPublishALastMarkerKind() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 480)
        try blockTranscriptDirectory()

        coordinator.markParagraph()

        XCTAssertEqual(coordinator.markerCount, 0, "harness: the append must have failed")
        XCTAssertNil(coordinator.lastMarkerKind,
                     "a marker that never landed must not be visually confirmed")

        await coordinator.done()
    }

    /// The opener is the literal frame 0, never the clock — feeding 750 frames FIRST
    /// is the mutation check: an implementation that reads `currentCaptureFrame`
    /// fails here at 750.
    func testMarkOpeningVoiceWritesLiteralFrameZero() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        coordinator.markOpeningVoice()

        let markers = loadMarkers().markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.frame, 0, "the opener is frame 0, not the clock")
        XCTAssertEqual(markers.first?.kind, .voice)
        XCTAssertEqual(markers.first?.voice, "bn")
        XCTAssertEqual(coordinator.currentVoice, "bn")

        await coordinator.done()
    }

    /// `handlePhase` re-enters `.recording` on an interruption resume and calls the
    /// opener again. Without the once-per-capture latch that writes a second frame-0
    /// marker AND resets `currentVoice` to "bn", mis-attributing everything after the
    /// resume to the wrong voice.
    func testResumeDoesNotWriteASecondOpeningVoiceMarker() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        coordinator.markOpeningVoice()
        recorder.feed(frames: 750)
        coordinator.markVoice(StructureMarker.Voice.littleNico)

        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")
        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ coordinator.phase == .recording }, "did not resume")

        coordinator.markOpeningVoice()   // exactly what the re-entered `.recording` does

        let markers = loadMarkers().markers
        XCTAssertEqual(markers.filter { $0.frame == 0 }.count, 1,
                       "the frame-0 opener is once per capture, not once per .recording")
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(coordinator.currentVoice, "ln",
                       "a duplicate opener would silently reset the voice to bn")

        await coordinator.done()
    }

    func testMarkerSeqsAreMonotonicAcrossKinds() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        coordinator.markOpeningVoice()
        recorder.feed(frames: 480)
        coordinator.markParagraph()
        recorder.feed(frames: 480)
        coordinator.markVoice(StructureMarker.Voice.littleNico)

        let markers = loadMarkers().markers
        XCTAssertEqual(markers.map(\.seq), [0, 1, 2])
        XCTAssertEqual(markers.map(\.kind), [.voice, .paragraph, .voice])
        XCTAssertEqual(markers.map(\.frame), [0, 480, 960])

        await coordinator.done()
    }

    /// The lazy-open discipline at the CALL SITE: an unmarked capture must leave no
    /// `transcript/` behind, or a mis-tapped recording becomes permanently
    /// undeletable (a zero-byte log flips `holdsIrreplaceableArtifacts`).
    func testNoMarksMeansNoTranscriptDirectory() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        await coordinator.done()

        XCTAssertEqual(coordinator.phase, .captured)
        XCTAssertFalse(transcriptDirectoryExists(), "no marks must mean no transcript/")
        XCTAssertEqual(loadMarkers().source, .absent)
    }

    func testFirstMarkCreatesTheLogLazily() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 500)
        XCTAssertFalse(transcriptDirectoryExists(),
                       "the log must not open until a marker actually lands")

        coordinator.markParagraph()

        XCTAssertTrue(transcriptDirectoryExists())
        XCTAssertTrue(FileManager.default.fileExists(atPath: SegmentLayout
            .markerLogURL(captureDirectory: markerCaptureDirectory()).path))

        // Design §4: the quarantine consequence is correct, not incidental — assert it
        // rather than assume it.
        let snapshot = DirectorySnapshot.gather(capturesRoot: root)
        let capture = try XCTUnwrap(snapshot.captures.first { $0.captureID == kCaptureID })
        XCTAssertTrue(capture.holdsIrreplaceableArtifacts,
                      "a marked capture must be quarantined, never deleted")

        await coordinator.done()
    }

    func testMarksOutsideRecordingAreIgnored() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        coordinator.markParagraph()          // idle: no capture, no clock
        coordinator.markVoice(StructureMarker.Voice.littleNico)
        coordinator.markOpeningVoice()
        XCTAssertEqual(coordinator.markerCount, 0)
        XCTAssertFalse(transcriptDirectoryExists())

        await coordinator.record()
        recorder.feed(frames: 100)
        await coordinator.done()
        XCTAssertEqual(coordinator.phase, .captured)

        coordinator.markParagraph()          // captured: wiring already torn down
        coordinator.markVoice(StructureMarker.Voice.bigNico)
        XCTAssertEqual(coordinator.markerCount, 0)
        XCTAssertNil(coordinator.currentVoice)
        XCTAssertFalse(transcriptDirectoryExists())
        XCTAssertEqual(loadMarkers().source, .absent)
    }

    /// Step 1's frame clock, pinned at the marker level: the axis a marker lands on
    /// must not restart when the capture is interrupted and resumed.
    func testMarkerFramesSurviveInterruptionResume() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 750)
        session.emit(.interrupted)
        await waitUntil({ coordinator.phase == .interrupted }, "did not interrupt")
        session.emit(.resumeAvailable(shouldResume: true))
        await waitUntil({ coordinator.phase == .recording }, "did not resume")

        recorder.feed(frames: 250)
        coordinator.markParagraph()

        let markers = loadMarkers().markers
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.frame, 1000,
                       "the marker frame axis restarted across the resume")

        await coordinator.done()
    }

    /// Design §7: continuity of audio outranks marker fidelity — the recording is
    /// never interrupted for a marker — but the failure is loud (the 2026-08-03
    /// "sidecar writes fail loudly" rule), never silent.
    func testOpenFailureSetsLastErrorAndRecordingContinues() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 500)
        try blockTranscriptDirectory()

        coordinator.markParagraph()

        XCTAssertNotNil(coordinator.lastError, "a failed marker write must not be silent")
        XCTAssertEqual(coordinator.phase, .recording, "a marker failure must not stop the capture")
        XCTAssertEqual(coordinator.markerCount, 0)

        recorder.feed(frames: 250)
        await coordinator.done()
        XCTAssertEqual(coordinator.phase, .captured)
        XCTAssertEqual(coordinator.finalizeQueue, [kCaptureID])

        let s0 = try decodeSidecar(0)
        XCTAssertEqual(s0.frameCount, 750, "every fed frame must still have reached disk")
    }

    func testOpenFailureLatchesFurtherMarks() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        recorder.feed(frames: 500)
        try blockTranscriptDirectory()

        coordinator.markParagraph()
        let firstError = coordinator.lastError
        XCTAssertNotNil(firstError)
        XCTAssertTrue(coordinator.markerLoggingBroken,
                      "a failed open latches — the control must not look live")

        coordinator.markVoice(StructureMarker.Voice.littleNico)
        coordinator.markParagraph()

        XCTAssertEqual(coordinator.lastError, firstError,
                       "a latched failure must not be cleared back to a success state")
        XCTAssertEqual(coordinator.markerCount, 0)
        XCTAssertNil(coordinator.currentVoice,
                     "a voice marker that was never written must not publish a voice")

        await coordinator.done()
    }

    /// The haptic seam (plan §0.3.4): the feedback fires on a successful append, so
    /// the count must move once per marker that actually reached disk.
    func testMarkerCountIncrementsPerSuccessfulAppend() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let coordinator = makeCoordinator(session: session, recorder: recorder)

        await coordinator.record()
        XCTAssertEqual(coordinator.markerCount, 0)
        coordinator.markOpeningVoice()
        recorder.feed(frames: 240)
        coordinator.markParagraph()
        recorder.feed(frames: 240)
        coordinator.markVoice(StructureMarker.Voice.littleNico)

        XCTAssertEqual(coordinator.markerCount, 3)
        XCTAssertEqual(loadMarkers().markers.count, 3)

        await coordinator.done()
    }
}
