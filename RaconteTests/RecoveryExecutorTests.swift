import XCTest
@testable import Raconte

/// M2 T2.5: the two live M1 bugs that T3 would have walked into — issue #7 (recovery
/// silently dropping manifest fields) and issue #8 (recovery deleting a finalized
/// capture whose manifest went bad). Both run against the real filesystem, because
/// both are about what survives on disk.
/// Separate from `RecoveryExecutorTests` (in `RecoveryPlannerTests.swift`), which
/// covers the design §3 happy paths. These are the two regressions.
final class RecoveryDataLossRegressionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteExecutorTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: Fixtures

    private let format = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
    }

    /// One second of silence as a finalized segment, so the capture clears the
    /// half-second floor and recovery treats it as real audio.
    private func writeSegment(_ id: String, frames: Int = 48_000) throws {
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        let pcm = Data(count: frames * 4)
        try pcm.write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))
    }

    private func write(_ manifest: Manifest, id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        let data = try CaptureCoding.encoder().encode(manifest)
        try data.write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
    }

    private func writeCorruptManifest(id: String) throws {
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try Data("{ not json at all".utf8)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
    }

    private func writeFinalM4A(id: String) throws {
        let dir = SegmentLayout.finalDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4_096)
            .write(to: SegmentLayout.finalRecordingURL(captureDirectory: captureDir(id)))
    }

    private func writeTranscript(id: String) throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(id))
        try writer.open()
        try writer.append(TranscriptRecord(
            seq: 0, text: "hello", captureFrameStart: 0, captureFrameEnd: 4_800,
            generator: "SpeechTranscriber", locale: "en_US"))
        try writer.close()
    }

    private func readManifest(_ id: String) -> Manifest? {
        guard let data = try? Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
        else { return nil }
        return try? CaptureCoding.decoder().decode(Manifest.self, from: data)
    }

    @discardableResult
    private func runRecovery() -> RecoveryOutcome {
        let snapshot = DirectorySnapshot.gather(capturesRoot: root)
        return RecoveryExecutor(capturesRoot: root).apply(RecoveryPlanner.plan(snapshot))
    }

    // MARK: Issue #7 — manifest fields must survive a recovery pass

    /// `writeCapturedManifest` rebuilds `Manifest` field by field, so anything it
    /// forgets is dropped on every crash recovery. `needsAttention` is the one that
    /// hurts: it means finalize gave up and the raw PCM must be kept forever.
    func testRecoveryPreservesEveryManifestField() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let interruption = InterruptionLogEntry(
            kind: "phoneCall", beganAt: created.addingTimeInterval(5),
            endedAt: created.addingTimeInterval(9), resumed: true)
        let transcript = TranscriptRef(
            generator: "SpeechTranscriber", locale: "en_US",
            coverageFrames: 40_000, skippedRanges: [FrameRange(start: 100, end: 200)],
            committedRecords: 4, completedAt: nil, latestRevision: nil)
        var original = Manifest(
            captureID: "cap", schemaVersion: 1, createdAt: created,
            state: .recording, stateSeq: 7, stateUpdatedAt: created,
            format: format, segmentCount: 1, lastKnownFrameOffset: 48_000,
            interruptions: [interruption], final: FinalRef(),
            needsAttention: true, lastError: "diskFull",
            retryCount: 3, finalizeAttempts: 2, transcript: transcript)
        original.final = FinalRef(verifiedAt: nil, durationFrames: nil)

        try write(original, id: "cap")
        try writeSegment("cap")
        runRecovery()

        let recovered = try XCTUnwrap(readManifest("cap"))
        XCTAssertEqual(recovered.state, .captured, "the point of the pass")

        XCTAssertEqual(recovered.needsAttention, true,
                       "a capture that needs the owner's attention must not lose the flag")
        XCTAssertEqual(recovered.lastError, "diskFull")
        XCTAssertEqual(recovered.retryCount, 3)
        XCTAssertEqual(recovered.finalizeAttempts, 2)
        XCTAssertEqual(recovered.schemaVersion, 1,
                       "schemaVersion must be carried, not silently defaulted")
        XCTAssertEqual(recovered.createdAt, created)
        XCTAssertEqual(recovered.interruptions, [interruption])
        XCTAssertEqual(recovered.captureID, "cap")
        XCTAssertGreaterThan(recovered.stateSeq, original.stateSeq)
        XCTAssertEqual(recovered.transcript, transcript,
                       "the transcript ref is exactly the field §3 warned would be dropped")
    }

    /// A capture killed mid-transcription: the ref survives recovery with
    /// `completedAt == nil`, which is what marks it for a re-derive.
    func testACaptureKilledMidTranscriptionKeepsAnIncompleteTranscriptRef() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = Manifest(
            captureID: "cap", createdAt: created, state: .recording,
            stateSeq: 2, stateUpdatedAt: created, format: format,
            segmentCount: 1, lastKnownFrameOffset: 48_000,
            transcript: TranscriptRef(generator: "SpeechTranscriber", locale: "en_US",
                                      coverageFrames: 12_000, committedRecords: 2))
        try write(manifest, id: "cap")
        try writeSegment("cap")
        try writeTranscript(id: "cap")

        runRecovery()

        let recovered = try XCTUnwrap(readManifest("cap"))
        XCTAssertEqual(recovered.state, .captured)
        let ref = try XCTUnwrap(recovered.transcript)
        XCTAssertNil(ref.completedAt)
        XCTAssertTrue(ref.needsRetranscription(against: recovered.lastKnownFrameOffset),
                      "coverage 12000 of 48000 frames must offer a re-derive")
        XCTAssertEqual(LiveTranscriptReader.load(captureDirectory: captureDir("cap")).records.count, 1,
                       "the live log itself is untouched by recovery")
    }

    func testACompleteTranscriptDoesNotAskForRetranscription() {
        let ref = TranscriptRef(generator: "SpeechTranscriber", locale: "en_US",
                                coverageFrames: 48_000, skippedRanges: [],
                                committedRecords: 9, completedAt: Date())
        XCTAssertFalse(ref.needsRetranscription(against: 48_000))
    }

    func testASkippedRangeAlwaysAsksForRetranscription() {
        let ref = TranscriptRef(generator: "SpeechTranscriber", locale: "en_US",
                                coverageFrames: 48_000,
                                skippedRanges: [FrameRange(start: 100, end: 200)],
                                committedRecords: 9, completedAt: Date())
        XCTAssertTrue(ref.needsRetranscription(against: 48_000),
                      "coverage can equal the total while a gap was still never seen")
    }

    /// A tripwire, not a style check. `writeCapturedManifest` enumerates fields by
    /// hand, so a field added to `Manifest` is dropped by default and no existing test
    /// notices. If this fails: carry the new field over in
    /// `RecoveryExecutor.writeCapturedManifest`, assert it above, then bump the count.
    func testManifestFieldCountIsPinnedSoNewFieldsGetCarriedOver() {
        let manifest = Manifest(captureID: "cap", createdAt: Date(), state: .captured,
                                stateSeq: 0, stateUpdatedAt: Date(), format: format)
        XCTAssertEqual(Mirror(reflecting: manifest).children.count, 16,
                       "Manifest gained or lost a field — see RecoveryExecutor.writeCapturedManifest")
    }

    // MARK: Issue #8 — never delete a tree holding a finalized recording

    func testCorruptManifestDoesNotDestroyAFinalizedRecording() throws {
        try writeCorruptManifest(id: "cap")
        try writeFinalM4A(id: "cap")

        let outcome = runRecovery()

        let m4a = SegmentLayout.finalRecordingURL(captureDirectory: captureDir("cap"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path),
                      "one corrupt byte must not cost the finalized recording")
        XCTAssertEqual(outcome.quarantinedCaptureIDs, ["cap"])
        XCTAssertTrue(outcome.deletedCaptureIDs.isEmpty)
    }

    func testCorruptManifestDoesNotDestroyATranscript() throws {
        try writeCorruptManifest(id: "cap")
        try writeTranscript(id: "cap")

        let outcome = runRecovery()

        let transcript = SegmentLayout.transcriptDirectory(captureDirectory: captureDir("cap"))
            .appendingPathComponent("live.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertEqual(outcome.quarantinedCaptureIDs, ["cap"])
    }

    /// Quarantine is a no-op on disk, so running recovery repeatedly is stable — no
    /// growing quarantine folder, no capture that moves out from under the UI.
    func testQuarantineIsIdempotentAcrossRepeatedLaunches() throws {
        try writeCorruptManifest(id: "cap")
        try writeFinalM4A(id: "cap")

        let first = runRecovery()
        let second = runRecovery()

        XCTAssertEqual(first.quarantinedCaptureIDs, second.quarantinedCaptureIDs)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SegmentLayout.finalRecordingURL(captureDirectory: captureDir("cap")).path))
    }

    /// The guard must not smuggle junk past the sweep: an accidental tap that left an
    /// empty tree is still removed.
    func testAnEmptyCaptureIsStillDeleted() throws {
        try writeCorruptManifest(id: "cap")

        let outcome = runRecovery()

        XCTAssertEqual(outcome.deletedCaptureIDs, ["cap"])
        XCTAssertTrue(outcome.quarantinedCaptureIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir("cap").path))
    }

    /// An empty `transcript/` directory holds nothing worth protecting and must not
    /// keep a junk capture alive forever.
    func testAnEmptyTranscriptDirectoryDoesNotBlockDeletion() throws {
        try writeCorruptManifest(id: "cap")
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDir("cap")),
            withIntermediateDirectories: true)

        let outcome = runRecovery()

        XCTAssertEqual(outcome.deletedCaptureIDs, ["cap"])
    }
}
