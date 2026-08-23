import XCTest
@testable import Raconte

final class RecoveryPlannerTests: XCTestCase {

    // MARK: Fixtures

    /// Float32/mono/48k canonical format (bytesPerFrame 4).
    private let fmt = AudioFormatDescriptor(
        sampleRate: 48000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)
    private let bpf = 4
    private let root = URL(fileURLWithPath: "/tmp/RaconteRecoveryTests/captures", isDirectory: true)

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    /// bytes for `frames` whole Float32-mono frames.
    private func bytes(frames: Int) -> Int { frames * bpf }
    /// frames for `seconds` at 48k.
    private func frames(seconds: Double) -> Int { Int(seconds * 48000) }

    private func manifest(_ state: CaptureState,
                          verifiedAt: Date? = nil,
                          segmentCount: Int = 0,
                          frameOffset: Int = 0) -> Manifest {
        var m = Manifest(
            captureID: "cap", createdAt: date("2026-07-29T15:00:00.000Z"),
            state: state, stateSeq: 3, stateUpdatedAt: date("2026-07-29T15:00:00.000Z"),
            format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                          commonFormat: .pcmFormatFloat32, interleaved: false),
            segmentCount: segmentCount, lastKnownFrameOffset: frameOffset)
        if let v = verifiedAt { m.final = FinalRef(verifiedAt: v, durationFrames: frameOffset) }
        return m
    }

    private func snapshot(id: String = "cap",
                          manifest: Manifest?,
                          manifestCorrupt: Bool = false,
                          segments: [SegmentFileStat],
                          m4a: Bool = false,
                          m4aPart: Bool = false,
                          transcript: Bool = false,
                          strayManifestPart: Bool = false) -> CaptureSnapshot {
        CaptureSnapshot(
            captureID: id,
            directory: SegmentLayout.captureDirectory(capturesRoot: root, captureID: id),
            manifest: manifest, manifestCorrupt: manifestCorrupt,
            strayManifestPart: strayManifestPart,
            segments: segments, finalM4APresent: m4a, finalM4APartPresent: m4aPart,
            transcriptPresent: transcript,
            format: fmt)
    }

    private func plan(_ capture: CaptureSnapshot) -> RecoveryAction {
        RecoveryPlanner.plan(for: capture)
    }

    // MARK: Row — absent/corrupt manifest + real segments → rebuild → captured

    func testCorruptManifestWithRealSegmentsRebuildsToCaptured() {
        // Two finalized segments with sidecars: 480000 + 480000 frames = 20 s total.
        let s0 = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: 480_000),
            sidecar: sidecar(index: 0, frameCount: 480_000, offset: 0))
        let s1 = SegmentFileStat(index: 1, pcmByteSize: bytes(frames: 480_000),
            sidecar: sidecar(index: 1, frameCount: 480_000, offset: 480_000))
        let cap = snapshot(manifest: nil, manifestCorrupt: true, segments: [s0, s1])

        guard case .normalizeToCaptured(let rec) = plan(cap) else {
            return XCTFail("expected normalizeToCaptured")
        }
        XCTAssertEqual(rec.totalFrames, 960_000)
        XCTAssertEqual(rec.durationSeconds, 20.0, accuracy: 0.001)
        XCTAssertEqual(rec.segments.map(\.startFrameOffset), [0, 480_000])
        XCTAssertFalse(rec.segments.contains { $0.needsPartNormalization })
    }

    // MARK: Row — absent/corrupt manifest + no/empty segments → delete (silent)

    func testAbsentManifestNoSegmentsDeletes() {
        XCTAssertEqual(plan(snapshot(manifest: nil, segments: [])),
                       .deleteCaptureDirectory(captureID: "cap"))
    }

    func testCorruptManifestOnlyEmptyPartDeletes() {
        let empty = SegmentFileStat(index: 0, partByteSize: 0)
        XCTAssertEqual(plan(snapshot(manifest: nil, manifestCorrupt: true, segments: [empty])),
                       .deleteCaptureDirectory(captureID: "cap"))
    }

    // MARK: Row — preparing + no segments → delete

    func testPreparingNoSegmentsDeletes() {
        XCTAssertEqual(plan(snapshot(manifest: manifest(.preparing), segments: [])),
                       .deleteCaptureDirectory(captureID: "cap"))
    }

    // MARK: Row — recording/interrupted/resuming/stopping + ≥1 non-empty → normalize→captured

    func testRecordingCrashNormalizesToCaptured() {
        for state in [CaptureState.recording, .interrupted, .resuming, .stopping] {
            let s0 = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: 960_000),
                sidecar: sidecar(index: 0, frameCount: 960_000, offset: 0))
            let cap = snapshot(manifest: manifest(state), segments: [s0])
            guard case .normalizeToCaptured(let rec) = plan(cap) else {
                return XCTFail("expected normalizeToCaptured for \(state)")
            }
            XCTAssertEqual(rec.totalFrames, 960_000, "\(state)")
        }
    }

    func testRecordingWithEmptySegmentsDeletes() {
        let empty = SegmentFileStat(index: 0, pcmByteSize: 0)
        XCTAssertEqual(plan(snapshot(manifest: manifest(.recording), segments: [empty])),
                       .deleteCaptureDirectory(captureID: "cap"))
    }

    // MARK: Row — .pcm.part present → normalize with correct truncated frameCount

    func testPcmPartNormalizesWithTruncatedFrameCount() {
        // 10 s of frames + 3 stray bytes (a torn final frame).
        let partBytes = bytes(frames: 480_000) + 3
        let s0 = SegmentFileStat(index: 0, partByteSize: partBytes)  // no sidecar
        let cap = snapshot(manifest: manifest(.recording), segments: [s0])

        guard case .normalizeToCaptured(let rec) = plan(cap) else {
            return XCTFail("expected normalizeToCaptured")
        }
        XCTAssertEqual(rec.segments.count, 1)
        let seg = rec.segments[0]
        XCTAssertTrue(seg.needsPartNormalization)
        XCTAssertTrue(seg.needsSidecar)
        XCTAssertEqual(seg.frameCount, 480_000, "trailing partial frame dropped")
        XCTAssertEqual(seg.byteCount, bytes(frames: 480_000))
        XCTAssertEqual(rec.totalFrames, 480_000)
    }

    func testPcmPartAfterFinalizedSegmentChainsOffset() {
        let s0 = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: 300_000),
            sidecar: sidecar(index: 0, frameCount: 300_000, offset: 0))
        // Live tail: 200000 frames + 2 partial bytes.
        let s1 = SegmentFileStat(index: 1, partByteSize: bytes(frames: 200_000) + 2)
        let cap = snapshot(manifest: manifest(.recording), segments: [s0, s1])

        guard case .normalizeToCaptured(let rec) = plan(cap) else {
            return XCTFail("expected normalizeToCaptured")
        }
        XCTAssertEqual(rec.segments.map(\.frameCount), [300_000, 200_000])
        XCTAssertEqual(rec.segments.map(\.startFrameOffset), [0, 300_000])
        XCTAssertEqual(rec.segments.map(\.needsPartNormalization), [false, true])
        XCTAssertEqual(rec.totalFrames, 500_000)
    }

    // MARK: Row — captured + ≥1 + m4a absent → enqueue finalize

    func testCapturedNoFinalEnqueuesFinalize() {
        let s0 = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: 960_000),
            sidecar: sidecar(index: 0, frameCount: 960_000, offset: 0))
        let cap = snapshot(manifest: manifest(.captured, segmentCount: 1, frameOffset: 960_000),
                           segments: [s0])
        XCTAssertEqual(plan(cap), .enqueueFinalize(captureID: "cap"))
    }

    func testCapturedWithStrayPartNormalizesFirst() {
        // captured state but a `.pcm.part` slipped through (missing sidecar too).
        let s0 = SegmentFileStat(index: 0, partByteSize: bytes(frames: 960_000))
        let cap = snapshot(manifest: manifest(.captured), segments: [s0])
        guard case .normalizeToCaptured = plan(cap) else {
            return XCTFail("expected normalizeToCaptured to fix the stray part")
        }
    }

    // MARK: Row — finalizing + .part only → discard + requeue

    func testFinalizingPartOnlyDiscardsAndRequeues() {
        let s0 = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: 960_000),
            sidecar: sidecar(index: 0, frameCount: 960_000, offset: 0))
        let cap = snapshot(manifest: manifest(.finalizing, segmentCount: 1, frameOffset: 960_000),
                           segments: [s0], m4a: false, m4aPart: true)
        XCTAssertEqual(plan(cap), .discardFinalPartRequeue(captureID: "cap"))
    }

    func testFinalizingNoFinalAtAllEnqueuesFinalize() {
        let s0 = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: 960_000),
            sidecar: sidecar(index: 0, frameCount: 960_000, offset: 0))
        let cap = snapshot(manifest: manifest(.finalizing, segmentCount: 1, frameOffset: 960_000),
                           segments: [s0])
        XCTAssertEqual(plan(cap), .enqueueFinalize(captureID: "cap"))
    }

    // MARK: Row — finalizing/complete + unverified .m4a → verify

    func testFinalizingWithM4APresentVerifies() {
        let s0 = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: 960_000),
            sidecar: sidecar(index: 0, frameCount: 960_000, offset: 0))
        let cap = snapshot(manifest: manifest(.finalizing, segmentCount: 1, frameOffset: 960_000),
                           segments: [s0], m4a: true)
        XCTAssertEqual(plan(cap), .verifyFinal(captureID: "cap"))
    }

    func testCompleteUnverifiedM4AVerifies() {
        // `complete` state but verifiedAt still nil → re-verify before trusting.
        let cap = snapshot(manifest: manifest(.complete), segments: [], m4a: true)
        XCTAssertEqual(plan(cap), .verifyFinal(captureID: "cap"))
    }

    // MARK: Row — complete + verified m4a + half-deleted segments → finish delete

    func testCompleteVerifiedFinishesRawDelete() {
        // Raw half-deleted: only one leftover sidecar-less segment remains.
        let leftover = SegmentFileStat(index: 2, pcmByteSize: bytes(frames: 120_000))
        let cap = snapshot(
            manifest: manifest(.complete, verifiedAt: date("2026-07-29T15:10:00.000Z"),
                               segmentCount: 3, frameOffset: 960_000),
            segments: [leftover], m4a: true)
        XCTAssertEqual(plan(cap), .finishRawDelete(captureID: "cap"))
    }

    func testCompleteVerifiedNoSegmentsFinishesRawDelete() {
        let cap = snapshot(
            manifest: manifest(.complete, verifiedAt: date("2026-07-29T15:10:00.000Z"),
                               frameOffset: 960_000),
            segments: [], m4a: true)
        XCTAssertEqual(plan(cap), .finishRawDelete(captureID: "cap"))
    }

    // MARK: Row — sub-floor total duration → discard

    func testSubFloorDurationDiscards() {
        // 0.4 s total (< 0.5 s floor) across two tiny segments.
        let s0 = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: frames(seconds: 0.2)),
            sidecar: sidecar(index: 0, frameCount: frames(seconds: 0.2), offset: 0))
        let s1 = SegmentFileStat(index: 1, pcmByteSize: bytes(frames: frames(seconds: 0.2)),
            sidecar: sidecar(index: 1, frameCount: frames(seconds: 0.2), offset: frames(seconds: 0.2)))
        let cap = snapshot(manifest: manifest(.recording), segments: [s0, s1])
        XCTAssertEqual(plan(cap), .deleteCaptureDirectory(captureID: "cap"))
    }

    func testExactlyFloorDurationSurvives() {
        // Exactly 0.5 s == floor → kept (>= comparison).
        let s0 = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: 24_000),
            sidecar: sidecar(index: 0, frameCount: 24_000, offset: 0))
        let cap = snapshot(manifest: manifest(.recording), segments: [s0])
        guard case .normalizeToCaptured = plan(cap) else {
            return XCTFail("0.5 s should survive the floor")
        }
    }

    // MARK: Row — multiple captures → multiple independent actions

    func testMultipleCapturesYieldIndependentActions() {
        let good = SegmentFileStat(index: 0, pcmByteSize: bytes(frames: 960_000),
            sidecar: sidecar(index: 0, frameCount: 960_000, offset: 0))
        let a = snapshot(id: "a", manifest: manifest(.recording), segments: [good])
        let b = snapshot(id: "b", manifest: nil, segments: [])  // nothing
        let c = snapshot(id: "c", manifest: manifest(.captured, segmentCount: 1, frameOffset: 960_000),
                         segments: [good])
        let snap = DirectorySnapshot(capturesRoot: root, captures: [a, b, c])

        let actions = RecoveryPlanner.plan(snap)
        XCTAssertEqual(actions.count, 3)
        guard case .normalizeToCaptured(let rec) = actions[0], rec.captureID == "a" else {
            return XCTFail("a → normalize")
        }
        XCTAssertEqual(actions[1], .deleteCaptureDirectory(captureID: "b"))
        XCTAssertEqual(actions[2], .enqueueFinalize(captureID: "c"))
    }

    // MARK: Issue #8 — a delete must never take a finalized recording with it

    /// The exact reported failure: one flipped byte in a finished capture's manifest.
    /// `segments/` is gone (the finalizer removed it), so `hasData` is false forever
    /// and the old planner routed this straight to `.deleteCaptureDirectory`.
    func testCorruptManifestWithAFinalizedM4AIsQuarantinedNotDeleted() {
        let action = plan(snapshot(manifest: nil, manifestCorrupt: true, segments: [], m4a: true))
        XCTAssertEqual(action, .quarantineCaptureDirectory(captureID: "cap"),
                       "a corrupt manifest must never cost the one file M1 promises to keep")
    }

    func testMissingManifestWithAFinalizedM4AIsQuarantined() {
        XCTAssertEqual(plan(snapshot(manifest: nil, segments: [], m4a: true)),
                       .quarantineCaptureDirectory(captureID: "cap"))
    }

    /// An interrupted finalize left only the `.part`. Still the only copy of the
    /// encode, and still not something to delete on a hunch.
    func testCorruptManifestWithOnlyAnM4APartIsQuarantined() {
        XCTAssertEqual(plan(snapshot(manifest: nil, manifestCorrupt: true, segments: [], m4aPart: true)),
                       .quarantineCaptureDirectory(captureID: "cap"))
    }

    /// M2 T3 writes `transcript/` into this same tree, which is what made #8 a
    /// blocker rather than a nuisance.
    func testCorruptManifestWithATranscriptIsQuarantined() {
        XCTAssertEqual(plan(snapshot(manifest: nil, manifestCorrupt: true, segments: [], transcript: true)),
                       .quarantineCaptureDirectory(captureID: "cap"))
    }

    /// `complete` with no `.m4a` and no segments used to delete too. Same guard.
    func testCompleteWithoutM4AButWithATranscriptIsQuarantined() {
        XCTAssertEqual(plan(snapshot(manifest: manifest(.complete), segments: [], transcript: true)),
                       .quarantineCaptureDirectory(captureID: "cap"))
    }

    /// The guard must not neuter the real delete path: an accidental tap that left
    /// nothing behind is still swept.
    func testEmptyCaptureWithNoArtifactsStillDeletes() {
        XCTAssertEqual(plan(snapshot(manifest: nil, manifestCorrupt: true, segments: [])),
                       .deleteCaptureDirectory(captureID: "cap"))
    }

    /// Quarantine is a decision, not a mutation: re-planning the same directory next
    /// launch reaches the same answer because nothing moved.
    func testQuarantineIsStableAcrossLaunches() {
        let capture = snapshot(manifest: nil, manifestCorrupt: true, segments: [], m4a: true)
        XCTAssertEqual(plan(capture), plan(capture))
    }

    func testEmptySnapshotYieldsNoActions() {
        XCTAssertTrue(RecoveryPlanner.plan(DirectorySnapshot(capturesRoot: root, captures: [])).isEmpty)
    }

    // MARK: Format fallback — bytesPerFrame derivation with no explicit value

    func testBytesPerFrameDerivedWhenAbsent() {
        // Int16 stereo → 4 bytes/frame, no explicit bytesPerFrame.
        let f = AudioFormatDescriptor(sampleRate: 48000, channels: 2,
                                      commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(DirectorySnapshot.bytesPerFrame(f), 4)
        // 48000 frames = 1 s → survives floor.
        let s0 = SegmentFileStat(index: 0, pcmByteSize: 48_000 * 4)
        let cap = CaptureSnapshot(
            captureID: "cap",
            directory: SegmentLayout.captureDirectory(capturesRoot: root, captureID: "cap"),
            manifest: nil, segments: [s0], format: f)
        guard case .normalizeToCaptured(let rec) = plan(cap) else {
            return XCTFail("expected normalize")
        }
        XCTAssertEqual(rec.segments[0].frameCount, 48_000)
    }

    // MARK: Helpers

    private func sidecar(index: Int, frameCount: Int, offset: Int) -> SegmentSidecar {
        SegmentSidecar(
            captureID: "cap", index: index,
            format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false, bytesPerFrame: 4),
            frameCount: frameCount, startFrameOffset: offset, startHostTime: 0,
            wallClockStart: date("2026-07-29T15:00:00.000Z"),
            sha256Prefix: "abcd1234", closedReason: .rotation, byteCount: frameCount * 4)
    }
}

/// Executor applied against a real temp dir: correctness + idempotency (design §3).
final class RecoveryExecutorTests: XCTestCase {
    private var root: URL!
    private let bpf = 4
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryExecTests-\(UUID().uuidString)/captures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let r = root?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: r) }
    }

    private func executor() -> RecoveryExecutor {
        RecoveryExecutor(capturesRoot: root, now: { self.fixedNow })
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    /// Materialize a capture dir. `partFrames`/`pcmFrames`+`extraBytes` seed a
    /// live `.pcm.part` (no sidecar) or finalized `.pcm`.
    @discardableResult
    private func makeCapture(id: String) -> URL {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        try? FileManager.default.createDirectory(
            at: SegmentLayout.segmentsDirectory(captureDirectory: dir),
            withIntermediateDirectories: true)
        return dir
    }

    private func writeBytes(_ n: Int, to url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data(count: n))
    }

    private func readManifest(_ dir: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: dir)) else { return nil }
        return try? CaptureCoding.decoder().decode(Manifest.self, from: data)
    }

    // MARK: normalizeToCaptured — .part truncate+rename, sidecar, manifest; idempotent

    func testNormalizeToCapturedRenamesPartWritesSidecarAndManifest() throws {
        let dir = makeCapture(id: "cap")
        let segsDir = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        let partURL = SegmentLayout.pcmPartURL(segmentsDirectory: segsDir, index: 0)
        let pcmURL = SegmentLayout.pcmURL(segmentsDirectory: segsDir, index: 0)
        let sidecarURL = SegmentLayout.sidecarURL(segmentsDirectory: segsDir, index: 0)
        writeBytes(960_000 * bpf + 3, to: partURL)  // 20 s + 3 torn bytes

        let snap = DirectorySnapshot.gather(capturesRoot: root)
        let actions = RecoveryPlanner.plan(snap)
        guard case .normalizeToCaptured = actions.first else { return XCTFail("expected normalize") }

        let outcome = executor().apply(actions)
        XCTAssertEqual(outcome.recoveredCaptureIDs, ["cap"])
        XCTAssertEqual(outcome.finalizeQueue, ["cap"])

        XCTAssertFalse(exists(partURL), ".part renamed away")
        XCTAssertTrue(exists(pcmURL))
        XCTAssertEqual(size(pcmURL), 960_000 * bpf, "truncated to whole frames")
        XCTAssertTrue(exists(sidecarURL))
        let m = try XCTUnwrap(readManifest(dir))
        XCTAssertEqual(m.state, .captured)
        XCTAssertEqual(m.segmentCount, 1)
        XCTAssertEqual(m.lastKnownFrameOffset, 960_000)

        // Idempotency: capture the full tree, re-apply the SAME actions, compare.
        let before = try treeFingerprint(dir)
        let outcome2 = executor().apply(actions)
        XCTAssertEqual(outcome2, outcome)
        XCTAssertEqual(try treeFingerprint(dir), before, "second apply changed nothing")
    }

    func testNormalizeIsConvergent() throws {
        // After normalize, a fresh gather+plan should NOT normalize again; it's captured.
        let dir = makeCapture(id: "cap")
        let segsDir = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        writeBytes(960_000 * bpf, to: SegmentLayout.pcmPartURL(segmentsDirectory: segsDir, index: 0))

        executor().apply(RecoveryPlanner.plan(DirectorySnapshot.gather(capturesRoot: root)))

        let actions2 = RecoveryPlanner.plan(DirectorySnapshot.gather(capturesRoot: root))
        XCTAssertEqual(actions2, [.enqueueFinalize(captureID: "cap")])
        _ = dir
    }

    // MARK: deleteCaptureDirectory — idempotent

    func testDeleteCaptureDirectoryIdempotent() throws {
        let dir = makeCapture(id: "cap")  // empty segments dir, no manifest
        XCTAssertTrue(exists(dir))
        let actions = RecoveryPlanner.plan(DirectorySnapshot.gather(capturesRoot: root))
        XCTAssertEqual(actions, [.deleteCaptureDirectory(captureID: "cap")])

        let o1 = executor().apply(actions)
        XCTAssertFalse(exists(dir))
        XCTAssertEqual(o1.deletedCaptureIDs, ["cap"])

        let o2 = executor().apply(actions)  // dir already gone
        XCTAssertEqual(o2, o1)
        XCTAssertFalse(exists(dir))
    }

    /// #82 safety story: `CaptureSnapshot` has no field for `entry.json` at all —
    /// `DirectorySnapshot`'s gather never reads it — so planting one in an otherwise
    /// zero-frame capture must not change the decision. This is what
    /// `LibraryScreenModel.deleteJournal`'s on-demand resolution trusts: a "worthless"
    /// blocker's own sidecar naming a journal is irrelevant to whether the planner will
    /// delete its directory.
    func testEntryJSONDoesNotChangeTheDecisionForAZeroFrameCapture() throws {
        let dir = makeCapture(id: "cap")  // empty segments dir, no manifest
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "some-journal"),
            url: SegmentLayout.entryMetadataURL(captureDirectory: dir))

        let actions = RecoveryPlanner.plan(DirectorySnapshot.gather(capturesRoot: root))

        XCTAssertEqual(actions, [.deleteCaptureDirectory(captureID: "cap")],
                       "entry.json is not part of CaptureSnapshot — planting it must not change the decision")
    }

    // MARK: finishRawDelete — idempotent

    func testFinishRawDeleteRemovesSegmentsIdempotent() throws {
        let dir = makeCapture(id: "cap")
        let segsDir = SegmentLayout.segmentsDirectory(captureDirectory: dir)
        writeBytes(120_000 * bpf, to: SegmentLayout.pcmURL(segmentsDirectory: segsDir, index: 2))

        let actions: [RecoveryAction] = [.finishRawDelete(captureID: "cap")]
        let o1 = executor().apply(actions)
        XCTAssertFalse(exists(segsDir), "raw segments dir removed")
        XCTAssertTrue(exists(dir), "capture dir (with final/) stays")

        let o2 = executor().apply(actions)  // already gone
        XCTAssertEqual(o2, o1)
        XCTAssertFalse(exists(segsDir))
    }

    // MARK: discardFinalPartRequeue — remove .part, set captured; idempotent

    func testDiscardFinalPartRequeueIdempotent() throws {
        let dir = makeCapture(id: "cap")
        // Seed a finalizing manifest + a stray final/recording.m4a.part.
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: dir), withIntermediateDirectories: true)
        let partURL = SegmentLayout.finalRecordingPartURL(captureDirectory: dir)
        writeBytes(1234, to: partURL)
        let m = Manifest(captureID: "cap", createdAt: fixedNow, state: .finalizing,
                         stateSeq: 5, stateUpdatedAt: fixedNow,
                         format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                                       commonFormat: .pcmFormatFloat32, interleaved: false),
                         segmentCount: 1, lastKnownFrameOffset: 960_000)
        try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir),
                               writing: try CaptureCoding.encoder().encode(m))

        let actions: [RecoveryAction] = [.discardFinalPartRequeue(captureID: "cap")]
        let o1 = executor().apply(actions)
        XCTAssertFalse(exists(partURL), ".m4a.part discarded")
        XCTAssertEqual(readManifest(dir)?.state, .captured)
        XCTAssertEqual(o1.finalizeQueue, ["cap"])

        let before = try treeFingerprint(dir)
        let o2 = executor().apply(actions)  // part gone, already captured
        XCTAssertEqual(o2, o1)
        XCTAssertEqual(try treeFingerprint(dir), before, "no churn on re-apply")
    }

    // MARK: enqueue/verify hand-offs make no FS change

    func testEnqueueAndVerifyAreFilesystemNoOps() throws {
        let dir = makeCapture(id: "cap")
        let before = try treeFingerprint(dir)
        let o = executor().apply([.enqueueFinalize(captureID: "cap"), .verifyFinal(captureID: "cap")])
        XCTAssertEqual(o.finalizeQueue, ["cap"])
        XCTAssertEqual(o.verifyQueue, ["cap"])
        XCTAssertEqual(try treeFingerprint(dir), before)
    }

    // MARK: A whole batch of mixed captures applies idempotently

    func testMixedBatchIdempotent() throws {
        // a: normalize, b: delete, c: enqueue, d: discard part.
        let a = makeCapture(id: "a")
        writeBytes(960_000 * bpf, to: SegmentLayout.pcmPartURL(
            segmentsDirectory: SegmentLayout.segmentsDirectory(captureDirectory: a), index: 0))
        _ = makeCapture(id: "b")  // empty → delete
        let c = makeCapture(id: "c")
        let cSegs = SegmentLayout.segmentsDirectory(captureDirectory: c)
        writeBytes(960_000 * bpf, to: SegmentLayout.pcmURL(segmentsDirectory: cSegs, index: 0))
        let cSidecar = SegmentSidecar(captureID: "c", index: 0,
            format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4),
            frameCount: 960_000, startFrameOffset: 0, startHostTime: 0,
            wallClockStart: fixedNow, sha256Prefix: "", closedReason: .rotation, byteCount: 960_000 * 4)
        try AtomicFile.replace(at: SegmentLayout.sidecarURL(segmentsDirectory: cSegs, index: 0),
                               writing: try CaptureCoding.encoder().encode(cSidecar))
        let cManifest = Manifest(captureID: "c", createdAt: fixedNow, state: .captured,
            stateSeq: 2, stateUpdatedAt: fixedNow,
            format: AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                commonFormat: .pcmFormatFloat32, interleaved: false),
            segmentCount: 1, lastKnownFrameOffset: 960_000)
        try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: c),
                               writing: try CaptureCoding.encoder().encode(cManifest))

        let actions = RecoveryPlanner.plan(DirectorySnapshot.gather(capturesRoot: root))
        let o1 = executor().apply(actions)
        let o2 = executor().apply(actions)
        XCTAssertEqual(o1, o2)
        // Final state stable across a third gather+plan pass.
        let actions3 = RecoveryPlanner.plan(DirectorySnapshot.gather(capturesRoot: root))
        // a normalized→captured→enqueue; c stays enqueue; b deleted (gone); order by id.
        XCTAssertEqual(actions3.filter {
            if case .normalizeToCaptured = $0 { return true } else { return false }
        }.count, 0, "nothing needs re-normalizing")
    }

    // MARK: fingerprint helper

    /// A stable, order-independent digest of a directory tree (relative path → byte size),
    /// so "same result" comparisons ignore filesystem enumeration order.
    private func treeFingerprint(_ dir: URL) throws -> [String: Int] {
        var out: [String: Int] = [:]
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return out }
        for case let url as URL in en {
            let rv = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if rv.isRegularFile == true {
                let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
                out[rel] = rv.fileSize ?? 0
            }
        }
        return out
    }
}
