import XCTest
import AVFoundation
@testable import Raconte

final class SegmentStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Helpers

    private static let captureID = "01J000000000000000000000"
    private static let bytesPerFrame = 4  // Float32 mono

    private func fixedClock() -> SegmentStore.Clock {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: "2026-07-29T15:00:00.123Z")!
        return SegmentStore.Clock(now: { date }, hostTimeSeconds: { 1490283.402 })
    }

    /// Store whose only rotation trigger is the byte cap, so segment boundaries
    /// are deterministic regardless of wall-clock.
    private func makeStore(byteCap: Int) -> SegmentStore {
        SegmentStore(
            capturesRoot: root, captureID: Self.captureID,
            format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                          commonFormat: .pcmFormatFloat32, interleaved: false),
            config: .init(rotationDurationSeconds: .infinity, rotationByteCap: byteCap),
            clock: fixedClock())
    }

    private func chunk(frames: Int) -> PCMChunk {
        PCMChunk(data: Data(count: frames * Self.bytesPerFrame),
                 frameCount: AVAudioFrameCount(frames), sampleRate: 48000)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func fileSize(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
    }
    private func decodeSidecar(index: Int, segs: URL) throws -> SegmentSidecar {
        let data = try Data(contentsOf: SegmentLayout.sidecarURL(segmentsDirectory: segs, index: index))
        return try CaptureCoding.decoder().decode(SegmentSidecar.self, from: data)
    }
    private func decodeManifest(dir: URL) throws -> Manifest {
        let data = try Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: dir))
        return try CaptureCoding.decoder().decode(Manifest.self, from: data)
    }

    // MARK: append -> rotate -> files + sidecars

    func testAppendRotateProducesSegmentsAndSidecars() async throws {
        let store = makeStore(byteCap: 4000)  // rotate every 1000 frames
        let dir = store.captureDirectory
        let segs = store.segmentsDirectory

        try await store.begin()
        // 4 chunks of 500 frames -> rotate after chunks 2 and 4; segment 2 stays empty.
        for _ in 0..<4 { try await store.append(chunk(frames: 500)) }
        try await store.finish()

        // Two finalized segments, gap-free, each 1000 frames / 4000 bytes.
        for i in 0..<2 {
            let pcm = SegmentLayout.pcmURL(segmentsDirectory: segs, index: i)
            XCTAssertTrue(exists(pcm), "000000+000001 .pcm present")
            XCTAssertEqual(try fileSize(pcm), 4000)
            XCTAssertFalse(exists(SegmentLayout.pcmPartURL(segmentsDirectory: segs, index: i)),
                           "no stray .part for finalized segment")
        }
        // The empty trailing segment was discarded, not written.
        XCTAssertFalse(exists(SegmentLayout.pcmURL(segmentsDirectory: segs, index: 2)))
        XCTAssertFalse(exists(SegmentLayout.pcmPartURL(segmentsDirectory: segs, index: 2)))
        XCTAssertFalse(exists(SegmentLayout.sidecarURL(segmentsDirectory: segs, index: 2)))

        let s0 = try decodeSidecar(index: 0, segs: segs)
        let s1 = try decodeSidecar(index: 1, segs: segs)
        XCTAssertEqual(s0.index, 0)
        XCTAssertEqual(s0.frameCount, 1000)
        XCTAssertEqual(s0.startFrameOffset, 0)
        XCTAssertEqual(s0.byteCount, 4000)
        XCTAssertEqual(s0.closedReason, .rotation)
        XCTAssertEqual(s0.format.bytesPerFrame, 4)
        XCTAssertEqual(s0.sha256Prefix.count, 8)
        XCTAssertEqual(s1.startFrameOffset, 1000)  // cumulative chain
        XCTAssertEqual(s1.frameCount, 1000)

        let manifest = try decodeManifest(dir: dir)
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.segmentCount, 2)
        XCTAssertEqual(manifest.lastKnownFrameOffset, 2000)
        // begin(1) + close seg0(2) + close seg1(3) + finish(4).
        XCTAssertEqual(manifest.stateSeq, 4)

        let total = await store.totalFrameCount()
        XCTAssertEqual(total, 2000)
    }

    // MARK: manifest atomic write (no stray .part)

    func testManifestAtomicWriteLeavesNoPart() async throws {
        let store = makeStore(byteCap: 4000)
        let dir = store.captureDirectory
        let manifestPart = SegmentLayout.manifestPartURL(captureDirectory: dir)

        try await store.begin()
        var m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(m.stateSeq, 1)
        XCTAssertEqual(m.segmentCount, 0)
        XCTAssertFalse(exists(manifestPart), "atomic write renames away the .part")

        // Force one rotation; manifest updates and still leaves no .part behind.
        for _ in 0..<2 { try await store.append(chunk(frames: 500)) }
        m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.segmentCount, 1)
        XCTAssertEqual(m.lastKnownFrameOffset, 1000)
        XCTAssertFalse(exists(manifestPart))
    }

    // MARK: kill-simulation — stop mid-.part, files remain recoverable

    func testKillMidPartLeavesRecoverableFiles() async throws {
        let store = makeStore(byteCap: 4000)
        let segs = store.segmentsDirectory
        let dir = store.captureDirectory

        try await store.begin()
        // Rotate once (seg0 = 1000 frames), then leave 500 frames in seg1's live .part.
        for _ in 0..<2 { try await store.append(chunk(frames: 500)) }
        try await store.append(chunk(frames: 500))
        // No finish(): simulate a force-kill with the live .part unrenamed.

        // Finalized segment 0 is intact + sidecar'd.
        let pcm0 = SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0)
        XCTAssertTrue(exists(pcm0))
        XCTAssertEqual(try fileSize(pcm0), 4000)
        let s0 = try decodeSidecar(index: 0, segs: segs)
        XCTAssertEqual(s0.frameCount, 1000)

        // Live segment 1 is a bare .part: no .pcm, no sidecar.
        let part1 = SegmentLayout.pcmPartURL(segmentsDirectory: segs, index: 1)
        XCTAssertTrue(exists(part1), "the killed live segment survives as .pcm.part")
        XCTAssertFalse(exists(SegmentLayout.pcmURL(segmentsDirectory: segs, index: 1)))
        XCTAssertFalse(exists(SegmentLayout.sidecarURL(segmentsDirectory: segs, index: 1)))

        // Playable frame total (what recovery reconstructs): closed sidecar frames
        // + whole frames in the unrenamed .part.
        let partBytes = try fileSize(part1)
        let partFrames = SegmentLayout.wholeFrameCount(fileSize: partBytes, bytesPerFrame: 4)
        XCTAssertEqual(partBytes, 2000)
        XCTAssertEqual(partFrames, 500)
        XCTAssertFalse(SegmentLayout.hasTrailingPartialFrame(fileSize: partBytes, bytesPerFrame: 4))
        XCTAssertEqual(s0.frameCount + partFrames, 1500)
        let liveTotal = await store.totalFrameCount()
        XCTAssertEqual(liveTotal, 1500)

        // Manifest never claimed the live segment (it only knows the closed one).
        let m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.state, .recording)
        XCTAssertEqual(m.segmentCount, 1)
        XCTAssertEqual(m.lastKnownFrameOffset, 1000)
    }

    // MARK: interruption closes the live segment as `interruption`

    func testInterruptClosesLiveSegmentAndLogsInterruption() async throws {
        let store = makeStore(byteCap: .max)  // never rotate on bytes
        let segs = store.segmentsDirectory
        let dir = store.captureDirectory

        try await store.begin()
        try await store.append(chunk(frames: 750))
        try await store.markInterrupted(kind: "call", beganAt: Date(timeIntervalSince1970: 100))

        let pcm0 = SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0)
        XCTAssertTrue(exists(pcm0))
        let s0 = try decodeSidecar(index: 0, segs: segs)
        XCTAssertEqual(s0.frameCount, 750)
        XCTAssertEqual(s0.closedReason, .interruption)

        let m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.state, .interrupted)
        XCTAssertEqual(m.interruptions.count, 1)
        XCTAssertEqual(m.interruptions.first?.kind, "call")

        // Resume opens the next gap-free segment; a further append lands there.
        try await store.resumeRecording()
        try await store.append(chunk(frames: 250))
        try await store.finish()
        let s1 = try decodeSidecar(index: 1, segs: segs)
        XCTAssertEqual(s1.startFrameOffset, 750)
        XCTAssertEqual(s1.frameCount, 250)
        let total = await store.totalFrameCount()
        XCTAssertEqual(total, 1000)
    }

    // MARK: issue #9 — interruption entries must close, not stay open forever

    /// Resume without a known interruption-end signal (the `interruptionEndedAt`
    /// default) closes the entry stamped `resumed: true` and `closedAt` at the
    /// store's injected clock (the same clock `fixedClock()` pins for every other
    /// timestamp in this file) — but `endedAt` stays honestly nil: nothing told the
    /// store when the interruption itself ended (issue #19).
    func testResumeClosesOpenInterruptionAsResumed() async throws {
        let store = makeStore(byteCap: .max)
        let dir = store.captureDirectory

        try await store.begin()
        try await store.append(chunk(frames: 750))
        try await store.markInterrupted(kind: "call", beganAt: Date(timeIntervalSince1970: 100))
        try await store.resumeRecording()

        let m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.interruptions.count, 1)
        XCTAssertNil(m.interruptions[0].endedAt, "no interruptionEndedAt was supplied")
        XCTAssertEqual(m.interruptions[0].closedAt, fixedClock().now())
        XCTAssertEqual(m.interruptions[0].resumed, true)
    }

    /// Issue #19: when the coordinator DOES know the system-reported end time (the
    /// `resumeAvailable` notification), `resumeRecording(interruptionEndedAt:)`
    /// threads it into `endedAt` — distinct from `closedAt`, which is always the
    /// store's own clock at close time. The two may legitimately differ.
    func testResumeThreadsKnownInterruptionEndedAtSeparatelyFromClosedAt() async throws {
        let store = makeStore(byteCap: .max)
        let dir = store.captureDirectory
        // Distinct from fixedClock()'s close-time stamp, so a bug that collapses
        // the two (or discards the argument) is caught by an exact-value mismatch,
        // not a coincidental match.
        let knownEndedAt = Date(timeIntervalSince1970: 150)

        try await store.begin()
        try await store.append(chunk(frames: 750))
        try await store.markInterrupted(kind: "call", beganAt: Date(timeIntervalSince1970: 100))
        try await store.resumeRecording(interruptionEndedAt: knownEndedAt)

        let m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.interruptions.count, 1)
        XCTAssertEqual(m.interruptions[0].endedAt, knownEndedAt,
                       "the system-reported end time must be threaded through, not discarded")
        XCTAssertEqual(m.interruptions[0].closedAt, fixedClock().now(),
                       "closedAt is always when we stopped waiting, independent of endedAt")
        XCTAssertNotEqual(m.interruptions[0].endedAt, m.interruptions[0].closedAt)
        XCTAssertEqual(m.interruptions[0].resumed, true)
    }

    /// Stopping from `interrupted` (`setState(.captured, closingInterruption: false)`,
    /// the coordinator's row-14 path) closes the entry as never resumed. The true
    /// end of the interruption is unknowable here — the owner just tapped Done —
    /// so `endedAt` must stay nil, not be fabricated from the tap's moment (#19).
    func testSetStateCapturedClosesOpenInterruptionAsNotResumed() async throws {
        let store = makeStore(byteCap: .max)
        let dir = store.captureDirectory

        try await store.begin()
        try await store.append(chunk(frames: 750))
        try await store.markInterrupted(kind: "call", beganAt: Date(timeIntervalSince1970: 100))
        try await store.setState(.captured, closingInterruption: false)

        let m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.interruptions.count, 1)
        XCTAssertNil(m.interruptions[0].endedAt, "the owner's Done tap is not a system end signal")
        XCTAssertEqual(m.interruptions[0].closedAt, fixedClock().now())
        XCTAssertEqual(m.interruptions[0].resumed, false)
    }

    /// `setState` without `closingInterruption` (the `.resuming`/`.interrupted` calls
    /// the coordinator makes mid-retry) must leave the entry open — a reacquire
    /// attempt in flight has not resolved yet. `closedAt`, not `endedAt`, is what
    /// marks open/closed (issue #19).
    func testSetStateWithoutClosingInterruptionLeavesEntryOpen() async throws {
        let store = makeStore(byteCap: .max)
        let dir = store.captureDirectory

        try await store.begin()
        try await store.append(chunk(frames: 750))
        try await store.markInterrupted(kind: "call", beganAt: Date(timeIntervalSince1970: 100))
        try await store.setState(.interrupted, retryCount: 1)

        let m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.interruptions.count, 1)
        XCTAssertNil(m.interruptions[0].endedAt)
        XCTAssertNil(m.interruptions[0].closedAt)
        XCTAssertNil(m.interruptions[0].resumed)
    }

    /// Interrupt -> resume -> interrupt -> stop: two full cycles, two closed entries,
    /// each with its own outcome. Neither resume nor stop supplies a known
    /// interruption-end time here, so both close with `endedAt` nil and `closedAt`
    /// stamped.
    func testDoubleInterruptionCycleProducesTwoClosedEntries() async throws {
        let store = makeStore(byteCap: .max)
        let dir = store.captureDirectory

        try await store.begin()
        try await store.append(chunk(frames: 500))
        try await store.markInterrupted(kind: "call", beganAt: Date(timeIntervalSince1970: 100))
        try await store.resumeRecording()

        try await store.append(chunk(frames: 500))
        try await store.markInterrupted(kind: "routeChange", beganAt: Date(timeIntervalSince1970: 200))
        try await store.setState(.captured, closingInterruption: false)

        let m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.interruptions.count, 2)
        XCTAssertEqual(m.interruptions[0].kind, "call")
        XCTAssertEqual(m.interruptions[0].resumed, true)
        XCTAssertNil(m.interruptions[0].endedAt)
        XCTAssertNotNil(m.interruptions[0].closedAt)
        XCTAssertEqual(m.interruptions[1].kind, "routeChange")
        XCTAssertEqual(m.interruptions[1].resumed, false)
        XCTAssertNil(m.interruptions[1].endedAt)
        XCTAssertNotNil(m.interruptions[1].closedAt)
    }

    /// A crash between `markInterrupted` and its close can, in principle, leave two
    /// open entries (nothing in this actor prevents a second `markInterrupted` call
    /// while one is already open — the state machine is what normally prevents it).
    /// Closing must only ever touch the most recent: the earlier one is left exactly
    /// as it was, historical evidence rather than tidied away.
    func testCloseOnlyTouchesTheMostRecentOpenEntry() async throws {
        let store = makeStore(byteCap: .max)
        let dir = store.captureDirectory

        try await store.begin()
        try await store.markInterrupted(kind: "first", beganAt: Date(timeIntervalSince1970: 100))
        // Simulated crash recovery re-entering markInterrupted without an intervening
        // resume: a second open entry, exactly what "crash between mark and close"
        // would produce.
        try await store.markInterrupted(kind: "second", beganAt: Date(timeIntervalSince1970: 200))
        try await store.resumeRecording()

        let m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.interruptions.count, 2)
        XCTAssertEqual(m.interruptions[0].kind, "first")
        XCTAssertNil(m.interruptions[0].closedAt, "earlier open entry must not be touched")
        XCTAssertNil(m.interruptions[0].endedAt)
        XCTAssertNil(m.interruptions[0].resumed)
        XCTAssertEqual(m.interruptions[1].kind, "second")
        XCTAssertEqual(m.interruptions[1].closedAt, fixedClock().now())
        XCTAssertEqual(m.interruptions[1].resumed, true)
    }

    /// Issue #19 back-compat: a pre-#19 entry has only `endedAt` (which meant "when
    /// we stopped waiting") and no `closedAt` key at all. Decoding must migrate that
    /// value into `closedAt` and leave the new `endedAt` honestly nil — never
    /// fabricate a system-reported end time that was never actually captured.
    func testLegacyInterruptionEntryWithoutClosedAtKeyMigratesToClosedAt() throws {
        let json = """
        {"kind":"call","beganAt":"2026-07-29T15:00:00.000Z",
         "endedAt":"2026-07-29T15:05:00.000Z","resumed":true}
        """
        let entry = try CaptureCoding.decoder().decode(InterruptionLogEntry.self,
                                                        from: Data(json.utf8))
        XCTAssertEqual(entry.kind, "call")
        XCTAssertNil(entry.endedAt, "legacy endedAt was really a close-time stamp, not a system signal")
        XCTAssertEqual(entry.closedAt, entry.beganAt.addingTimeInterval(300))
        XCTAssertEqual(entry.resumed, true)
    }

    /// A legacy still-open entry (no `endedAt`, no `closedAt` key) round-trips as
    /// still open under the new schema too.
    func testLegacyOpenInterruptionEntryStaysOpenAfterMigration() throws {
        let json = """
        {"kind":"call","beganAt":"2026-07-29T15:00:00.000Z",
         "endedAt":null,"resumed":null}
        """
        let entry = try CaptureCoding.decoder().decode(InterruptionLogEntry.self,
                                                        from: Data(json.utf8))
        XCTAssertNil(entry.endedAt)
        XCTAssertNil(entry.closedAt)
        XCTAssertNil(entry.resumed)
    }

    /// New-format round trip: both `endedAt` (system-reported, known) and `closedAt`
    /// (when we stopped waiting) survive encode/decode independently.
    func testNewFormatInterruptionEntryRoundTripsBothTimestamps() throws {
        let entry = InterruptionLogEntry(
            kind: "call", beganAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 150),
            closedAt: Date(timeIntervalSince1970: 200), resumed: true)
        let data = try CaptureCoding.encoder().encode(entry)
        let decoded = try CaptureCoding.decoder().decode(InterruptionLogEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
        XCTAssertNotEqual(decoded.endedAt, decoded.closedAt)
    }

    // MARK: setState persists operational fields

    func testSetStatePersistsOperationalFields() async throws {
        let store = makeStore(byteCap: 4000)
        let dir = store.captureDirectory
        try await store.begin()
        try await store.finish()
        try await store.setState(.finalizing)
        try await store.setState(.captured, needsAttention: true, finalizeAttempts: 3)

        let m = try decodeManifest(dir: dir)
        XCTAssertEqual(m.state, .captured)
        XCTAssertEqual(m.needsAttention, true)
        XCTAssertEqual(m.finalizeAttempts, 3)
    }
}
