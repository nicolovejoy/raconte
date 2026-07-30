import XCTest
@testable import Raconte

/// Records the segments handed to it (in order, per encode call) and returns a
/// configurable verify result, so every `FinalizerWorker` branch is drivable
/// without touching AVFoundation.
final class FakeAudioEncoder: AudioEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[EncodableSegment]] = []
    private var _lastEncodedFrames = 0
    /// When set, `verify` returns this instead of the default (exact, non-silent) pass.
    var verifyOverride: VerifyResult?

    var calls: [[EncodableSegment]] {
        lock.withLock { _calls }
    }

    func encode(segments: [EncodableSegment], format: AudioFormatDescriptor,
                to outputPartURL: URL) async throws -> EncodeResult {
        let total = lock.withLock { () -> Int in
            _calls.append(segments)
            _lastEncodedFrames = segments.reduce(0) { $0 + $1.frameCount }
            return _lastEncodedFrames
        }
        // Produce a stand-in `.part` so promote/discard have a real file to act on.
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: outputPartURL)
        return EncodeResult(outputURL: outputPartURL, encodedFrameCount: total)
    }

    func verify(m4aURL: URL) async throws -> VerifyResult {
        lock.withLock {
            verifyOverride ?? VerifyResult(decodable: true, decodedFrameCount: _lastEncodedFrames,
                                           nonSilent: true)
        }
    }
}

final class FinalizerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinalizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: helpers

    private static let sampleRate = 48000
    private static let bytesPerFrame = 4

    private func format() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: Self.sampleRate, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4)
    }

    /// Lay down a `captured` capture on disk: manifest + N segments (`.pcm` +
    /// sidecar). Each tuple is (frameCount, startFrameOffset) so a caller can
    /// inject a deliberate offset gap.
    private func layDownCapture(id: String, segments: [(frames: Int, offset: Int)],
                                finalizeAttempts: Int? = nil) throws {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: dir), withIntermediateDirectories: true)

        let fmt = format()
        let total = segments.map(\.frames).reduce(0, +)
        for (i, seg) in segments.enumerated() {
            let pcm = Data(count: seg.frames * Self.bytesPerFrame)
            try pcm.write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: i))
            let sidecar = SegmentSidecar(
                captureID: id, index: i, format: fmt, frameCount: seg.frames,
                startFrameOffset: seg.offset, startHostTime: 0,
                wallClockStart: Date(timeIntervalSince1970: 0), sha256Prefix: "00000000",
                closedReason: .rotation, byteCount: seg.frames * Self.bytesPerFrame)
            let data = try CaptureCoding.encoder().encode(sidecar)
            try AtomicFile.replace(at: SegmentLayout.sidecarURL(segmentsDirectory: segs, index: i),
                                   writing: data)
        }
        let manifestFmt = AudioFormatDescriptor(sampleRate: Self.sampleRate, channels: 1,
                                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let manifest = Manifest(captureID: id, createdAt: Date(timeIntervalSince1970: 0),
                                state: .captured, stateSeq: 5,
                                stateUpdatedAt: Date(timeIntervalSince1970: 0),
                                format: manifestFmt, segmentCount: segments.count,
                                lastKnownFrameOffset: total, finalizeAttempts: finalizeAttempts)
        let data = try CaptureCoding.encoder().encode(manifest)
        try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir), writing: data)
    }

    private func readManifest(_ id: String) throws -> Manifest {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        let data = try Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: dir))
        return try CaptureCoding.decoder().decode(Manifest.self, from: data)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func makeWorker(encoder: AudioEncoder, config: FinalizerWorker.Config = .init()) -> FinalizerWorker {
        FinalizerWorker(capturesRoot: root, encoder: encoder, config: config,
                        now: { Date(timeIntervalSince1970: 1_000) })
    }

    // MARK: ordered, contiguous feed → complete, raw deleted

    func testOrderedContiguousFeedCompletesAndDeletesRaw() async throws {
        let id = "01J000000000000000000001"
        try layDownCapture(id: id, segments: [(1000, 0), (1000, 1000), (500, 2000)])
        let encoder = FakeAudioEncoder()
        let worker = makeWorker(encoder: encoder)
        await worker.enqueue(id)

        let outcomes = await worker.drain()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].status, .completed)
        XCTAssertEqual(outcomes[0].encodedFrameCount, 2500)
        XCTAssertFalse(outcomes[0].hadGap)

        // Encoder saw all three segments once, in ascending index order.
        XCTAssertEqual(encoder.calls.count, 1)
        XCTAssertEqual(encoder.calls[0].map(\.index), [0, 1, 2])
        // Contiguous: each startFrameOffset equals the running sum of prior frames.
        var running = 0
        for seg in encoder.calls[0] {
            XCTAssertEqual(seg.startFrameOffset, running)
            running += seg.frameCount
        }

        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        let manifest = try readManifest(id)
        XCTAssertEqual(manifest.state, .complete)
        XCTAssertNotNil(manifest.final.verifiedAt)
        XCTAssertEqual(manifest.final.durationFrames, 2500)
        // Raw deleted, finished .m4a present.
        XCTAssertFalse(exists(SegmentLayout.segmentsDirectory(captureDirectory: dir)))
        XCTAssertTrue(exists(SegmentLayout.finalRecordingURL(captureDirectory: dir)))
        XCTAssertFalse(exists(SegmentLayout.finalRecordingPartURL(captureDirectory: dir)))
    }

    // MARK: startFrameOffset gap → needsAttention, only the prefix encoded, raw kept

    func testGapFlagsNeedsAttentionAndEncodesContiguousPrefix() async throws {
        let id = "01J000000000000000000002"
        // seg2 offset is wrong (2500 instead of 2000) → chain breaks after seg1.
        try layDownCapture(id: id, segments: [(1000, 0), (1000, 1000), (500, 2500)])
        let encoder = FakeAudioEncoder()
        let worker = makeWorker(encoder: encoder)
        await worker.enqueue(id)

        let outcomes = await worker.drain()
        XCTAssertEqual(outcomes[0].status, .needsAttention)
        XCTAssertTrue(outcomes[0].hadGap)
        XCTAssertEqual(outcomes[0].encodedFrameCount, 2000)

        // Encoder saw only the contiguous prefix [0, 1].
        XCTAssertEqual(encoder.calls[0].map(\.index), [0, 1])

        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        let manifest = try readManifest(id)
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.needsAttention, true)
        // Raw is ground truth — never deleted for an incomplete encode.
        XCTAssertTrue(exists(SegmentLayout.segmentsDirectory(captureDirectory: dir)))
    }

    // MARK: verify-fail with budget left → requeued, attempts++, raw kept, no .m4a

    func testVerifyFailRequeuesAndKeepsRaw() async throws {
        let id = "01J000000000000000000003"
        try layDownCapture(id: id, segments: [(1000, 0), (1000, 1000)])
        let encoder = FakeAudioEncoder()
        encoder.verifyOverride = VerifyResult(decodable: true, decodedFrameCount: 2000, nonSilent: false)
        let worker = makeWorker(encoder: encoder, config: .init(maxFinalizeAttempts: 3))
        await worker.enqueue(id)

        let outcomes = await worker.drain()
        XCTAssertEqual(outcomes[0].status, .requeued)
        XCTAssertEqual(outcomes[0].finalizeAttempts, 1)

        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        let manifest = try readManifest(id)
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.finalizeAttempts, 1)
        XCTAssertNil(manifest.needsAttention)
        XCTAssertTrue(exists(SegmentLayout.segmentsDirectory(captureDirectory: dir)))
        XCTAssertFalse(exists(SegmentLayout.finalRecordingURL(captureDirectory: dir)))
        XCTAssertFalse(exists(SegmentLayout.finalRecordingPartURL(captureDirectory: dir)),
                       ".part discarded on verify fail")
    }

    // MARK: verify-fail at the budget boundary → needsAttention, raw kept forever

    func testVerifyFailBudgetExhaustedFlagsNeedsAttention() async throws {
        let id = "01J000000000000000000004"
        try layDownCapture(id: id, segments: [(1000, 0)], finalizeAttempts: 2)
        let encoder = FakeAudioEncoder()
        // Silent output → fail.
        encoder.verifyOverride = VerifyResult(decodable: true, decodedFrameCount: 1000, nonSilent: false)
        let worker = makeWorker(encoder: encoder, config: .init(maxFinalizeAttempts: 3))
        await worker.enqueue(id)

        let outcomes = await worker.drain()
        XCTAssertEqual(outcomes[0].status, .needsAttention)
        XCTAssertEqual(outcomes[0].finalizeAttempts, 3)

        let manifest = try readManifest(id)
        XCTAssertEqual(manifest.state, .captured)
        XCTAssertEqual(manifest.finalizeAttempts, 3)
        XCTAssertEqual(manifest.needsAttention, true)
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        XCTAssertTrue(exists(SegmentLayout.segmentsDirectory(captureDirectory: dir)))
    }

    // MARK: not-decodable output → treated as failure

    func testUndecodableOutputRequeues() async throws {
        let id = "01J000000000000000000005"
        try layDownCapture(id: id, segments: [(1000, 0)])
        let encoder = FakeAudioEncoder()
        encoder.verifyOverride = VerifyResult(decodable: false, decodedFrameCount: 0, nonSilent: false)
        let worker = makeWorker(encoder: encoder)
        await worker.enqueue(id)

        let outcomes = await worker.drain()
        XCTAssertEqual(outcomes[0].status, .requeued)
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        XCTAssertTrue(exists(SegmentLayout.segmentsDirectory(captureDirectory: dir)))
    }

    // MARK: queue drains FIFO, dedups, and reports per-capture outcomes

    func testDrainProcessesQueueFIFOWithDedup() async throws {
        let id1 = "01J000000000000000000006"
        let id2 = "01J000000000000000000007"
        try layDownCapture(id: id1, segments: [(1000, 0)])
        try layDownCapture(id: id2, segments: [(1000, 0)])
        let encoder = FakeAudioEncoder()
        let worker = makeWorker(encoder: encoder)
        await worker.enqueue(contentsOf: [id1, id2, id1])  // duplicate ignored

        let outcomes = await worker.drain()
        XCTAssertEqual(outcomes.map(\.captureID), [id1, id2])
        XCTAssertEqual(outcomes.map(\.status), [.completed, .completed])

        // Queue is empty after draining.
        let again = await worker.drain()
        XCTAssertTrue(again.isEmpty)
    }
}
