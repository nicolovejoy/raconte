import XCTest
@testable import Raconte

/// M4 T10: `MarkerStreamMerge` (pure) plus one integration test proving the merge
/// actually reaches `TranscriptAttribution` through `EntryTranscript`/
/// `LibraryScreenModel.transcript(for:)` — the same end-to-end path
/// `TranscriptAttributionLoadTests` already exercises for a single stream.
@MainActor
final class MarkerStreamMergeTests: XCTestCase {

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
    }

    // MARK: Pure merge — single-stream identity

    /// Brief pin: one stream in → byte-equal marker semantics out. A single stream's
    /// own order is already `(at, deviceID-constant, originalSeq)` — exactly the merge's
    /// own sort key with a constant middle term — so the renumbering is the identity
    /// map, including for a `retractsSeq` reference. Pre-M4 (single-device) entries must
    /// therefore behave exactly as before this task landed.
    func testSingleStreamIdentityRenumbersToTheSameValues() {
        let markers = [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn", at: stamp(0)),
            StructureMarker(seq: 1, frame: 1_000, kind: .paragraph, at: stamp(10)),
            // A retract of the paragraph at seq 1 — proves retractsSeq survives the
            // identity mapping unchanged, not merely that the algorithm no-ops when no
            // retract is present.
            StructureMarker(seq: 2, frame: 0, kind: .correctionRetract, retractsSeq: 1, at: stamp(20)),
        ]
        let stream = MarkerStreamMerge.Stream(deviceID: "device-a", markers: markers)

        let merged = MarkerStreamMerge.merge([stream])

        XCTAssertEqual(merged, markers, "a single stream must round-trip byte-for-byte, seqs included")
    }

    // MARK: Pure merge — cross-stream ordering

    /// Unstamped legacy records (every marker written before M4 T1) sort before every
    /// stamped one — `at ?? .distantPast` in the sort key, no special-casing needed.
    func testUnstampedLegacyRecordsSortBeforeStampedOnes() {
        let legacy = StructureMarker(seq: 0, frame: 0, kind: .paragraph, at: nil)
        let stamped = StructureMarker(seq: 0, frame: 1_000, kind: .paragraph, at: stamp(0))
        // Deliberately handed in the OPPOSITE order the merge must produce, so a merge
        // that just concatenated streams unchanged would fail this too.
        let stream = MarkerStreamMerge.Stream(deviceID: "device-a", markers: [stamped, legacy])

        let merged = MarkerStreamMerge.merge([stream])

        XCTAssertEqual(merged.map(\.at), [nil, stamp(0)])
        XCTAssertEqual(merged.map(\.seq), [0, 1])
    }

    /// Equal `at` → the lexicographically GREATER deviceID wins, both directions —
    /// tested here as "sorts later, so it ends up at the higher seq", which is exactly
    /// what makes it win under `MarkerCorrections.effectiveMarkers`' existing
    /// later-seq-wins precedence rule.
    func testEqualAtTieBreaksOnDeviceIDBothDirections() {
        let when = stamp(0)
        let low = MarkerStreamMerge.Stream(deviceID: "device-aaa",
                                           markers: [StructureMarker(seq: 0, frame: 0, kind: .voice,
                                                                     voice: "low-wins-if-first", at: when)])
        let high = MarkerStreamMerge.Stream(deviceID: "device-zzz",
                                            markers: [StructureMarker(seq: 0, frame: 0, kind: .voice,
                                                                      voice: "high-wins-if-first", at: when)])

        let mergedLowFirst = MarkerStreamMerge.merge([low, high])
        XCTAssertEqual(mergedLowFirst.last?.voice, "high-wins-if-first",
                       "the greater deviceID sorts LAST regardless of input order")

        let mergedHighFirst = MarkerStreamMerge.merge([high, low])
        XCTAssertEqual(mergedHighFirst.last?.voice, "high-wins-if-first",
                       "same answer with the streams handed in the opposite order — proves the sort, not input order, decides it")
    }

    // MARK: Pure merge — retractsSeq remap

    /// Same-stream remap, deliberately interleaved with a FOREIGN stream's own marker
    /// sitting between the two (by `at`) — proves the remap tracks the retracting
    /// record's OWN stream identity through the renumbering, not merely "whatever sits
    /// next to it after the sort".
    func testRetractsSeqRemapsWithinItsOwnStreamAcrossInterleavedForeignMarkers() {
        let ownParagraph = StructureMarker(seq: 0, frame: 0, kind: .paragraph, at: stamp(0))
        let ownRetract = StructureMarker(seq: 1, frame: 0, kind: .correctionRetract, retractsSeq: 0, at: stamp(20))
        let own = MarkerStreamMerge.Stream(deviceID: "device-own", markers: [ownParagraph, ownRetract])

        // Sorts BETWEEN the two own-stream records by `at`.
        let foreignMarker = StructureMarker(seq: 0, frame: 500, kind: .voice, voice: "bn", at: stamp(10))
        let foreign = MarkerStreamMerge.Stream(deviceID: "device-foreign", markers: [foreignMarker])

        let merged = MarkerStreamMerge.merge([own, foreign])

        XCTAssertEqual(merged.map(\.seq), [0, 1, 2], "own-paragraph, foreign-marker, own-retract, in that at-order")
        let retract = merged[2]
        XCTAssertEqual(retract.kind, .correctionRetract)
        XCTAssertEqual(retract.retractsSeq, 0,
                       "must remap to the own paragraph's NEW seq (0) — not the foreign marker's index (1), "
                       + "and not the original raw value (also 0, which would pass a weaker test)")
    }

    /// The brief's named test: a retract that only coincidentally shares a raw seq
    /// number with a DIFFERENT stream's own record must never resolve against it — raw
    /// seq numbers restart at 0 per device and are not globally unique before this
    /// merge. Confirmed two ways: the merged retract's `retractsSeq` is nil, and feeding
    /// the merge through `MarkerCorrections.effectiveMarkers` leaves the other stream's
    /// same-numbered record UN-retracted.
    func testAForeignRetractsSeqNamingALocalSeqIsDroppedNotResolved() throws {
        // Local (own) stream's own marker happens to be numbered 5.
        var local5 = StructureMarker(seq: 0, frame: 0, kind: .paragraph, at: stamp(0))
        local5.seq = 5
        let local = MarkerStreamMerge.Stream(deviceID: "device-local", markers: [local5])

        // Foreign stream's OWN numbering starts at 0 — its retract targets "5", but that
        // 5 was never one of ITS OWN records.
        let foreignRetract = StructureMarker(seq: 0, frame: 0, kind: .correctionRetract, retractsSeq: 5, at: stamp(10))
        let foreign = MarkerStreamMerge.Stream(deviceID: "device-foreign", markers: [foreignRetract])

        let merged = MarkerStreamMerge.merge([local, foreign])

        let retract = try XCTUnwrap(merged.first { $0.kind == .correctionRetract })
        XCTAssertNil(retract.retractsSeq, "a cross-stream coincidence must never resolve")

        let effective = MarkerCorrections.effectiveMarkers(merged)
        XCTAssertTrue(effective.contains { $0.marker.kind == .paragraph },
                     "the local device's own seq-5 paragraph must survive — the foreign retract named nothing real")
    }

    // MARK: holdsIrreplaceableArtifacts (design §7.4)

    /// A foreign marker stream file sitting alone in `transcript/` (no m4a, no
    /// `live.jsonl`, no own `markers.jsonl`) must already trip
    /// `DirectorySnapshot.holdsIrreplaceableArtifacts` — asserted directly against the
    /// real guard, not re-implemented, per design §7.4: "they are precious voice
    /// attribution and *should* trip" it.
    func testForeignMarkerStreamFileAloneTripsHoldsIrreplaceableArtifacts() throws {
        let containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkerStreamMergeHoldsArtifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: containerRoot) }
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        let captureID = ULID.make()
        let captureDirectory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)

        let foreignURL = SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDirectory, deviceID: "device-x")
        try Data("{\"seq\":0,\"frame\":0,\"kind\":\"paragraph\"}\n".utf8).write(to: foreignURL)

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot, captureID: captureID)
        XCTAssertTrue(snapshot.holdsIrreplaceableArtifacts,
                     "a foreign device's marker stream is precious voice attribution, same as this device's own")
    }

    // MARK: Integration — through TranscriptAttribution (the point of this task)

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = "01BBBBBBBBBBBBBBBBBBBBBBBB"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkerStreamMergeIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func captureDir() -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private func writeManifest(sampleRate: Int = 48_000) throws {
        let format = AudioFormatDescriptor(sampleRate: sampleRate, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let created = Date(timeIntervalSince1970: 1_000)
        let manifest = Manifest(captureID: captureID, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try FileManager.default.createDirectory(at: captureDir(), withIntermediateDirectories: true)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDir()))
    }

    private func writeLiveTranscript(_ records: [(text: String, start: Int64, end: Int64)]) throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir())
        try writer.open()
        for record in records {
            try writer.append(TranscriptRecord(seq: 0, text: record.text,
                                               captureFrameStart: record.start,
                                               captureFrameEnd: record.end,
                                               generator: "SpeechTranscriber", locale: "en_US"))
        }
        try writer.close()
    }

    private func writeOwnMarkers(_ markers: [StructureMarker]) throws {
        let writer = MarkerLogWriter(captureDirectory: captureDir())
        try writer.open()
        for marker in markers { try writer.append(marker) }
        try writer.close()
    }

    /// Writes a foreign device's already-synced marker stream directly, the same shape
    /// `SyncRecordExchange.materializeMarkerStream` (T10 ingest) produces — one JSONL
    /// line per marker via the SAME line encoder `MarkerLogWriter` uses, so this fixture
    /// cannot silently diverge from the real wire format `MarkerLogReader` parses.
    private func writeForeignMarkers(deviceID: String, _ markers: [StructureMarker]) throws {
        let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDir())
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        var data = Data()
        for marker in markers {
            data.append(try CaptureCoding.lineEncoder().encode(marker))
            data.append(UInt8(ascii: "\n"))
        }
        let url = SegmentLayout.foreignMarkerLogURL(captureDirectory: captureDir(), deviceID: deviceID)
        try data.write(to: url)
    }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    /// THE integration pin (brief): a voice correction landing on a PEER device, stamped
    /// LATER than this device's own correction of the same boundary, must win in the
    /// rendered paragraph's voice — end to end through
    /// `LibraryScreenModel.transcript(for:)` → `EntryTranscript.load` →
    /// `EntryTranscript.snappedMarkers` (this task's own wiring) →
    /// `MarkerCorrections.effectiveMarkers` → `TranscriptAttribution.attribute`. Ordering
    /// alone (a bare `MarkerStreamMerge.merge` array assertion) would not prove the wire-
    /// up actually reached attribution — this does.
    @MainActor
    func testForeignCorrectionStampedLaterWinsThroughTranscriptAttribution() async throws {
        try writeManifest()
        try writeLiveTranscript([("hello there", 0, 20_000)])
        // This device's own raw tap, stamped first — a real `MarkerLogWriter` with an
        // injected clock (never `Date.init`'s real wall time, which would land far in
        // the future relative to the fixed `stamp(...)` epoch used below and silently
        // invert every ordering assumption this test relies on).
        let rawTapAt = stamp(0)
        let rawTapWriter = MarkerLogWriter(captureDirectory: captureDir(), now: { rawTapAt })
        try rawTapWriter.open()
        try rawTapWriter.append(StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn"))
        try rawTapWriter.close()

        // A same-device correction at +100s — would win if the foreign one below did
        // not exist, proving this isn't a trivial "foreign always wins" test.
        let localCorrectionAt = stamp(100)
        let correctionWriter = MarkerLogWriter(captureDirectory: captureDir(), now: { localCorrectionAt })
        try correctionWriter.open()
        try correctionWriter.append(StructureMarker(seq: 0, frame: 0, kind: .correctionVoice, voice: "ln"))
        try correctionWriter.close()

        // The peer's correction of the SAME boundary, stamped LATER. deviceID is
        // deliberately constructed to sort LEXICOGRAPHICALLY BEFORE this device's own
        // real `DeviceIdentity.stable()` (a Crockford-base32 ULID, whose characters are
        // all >= "0") — "!" precedes every ULID character. This makes the test a real
        // discriminator against a (deviceID, at) mis-ordered sort: under that mutation
        // the LOWER deviceID would sort first regardless of timestamp, so THIS peer
        // would lose even though it must win on `at` alone — a same-device-ID-luck
        // false pass is structurally impossible here (mutation-verified: see task report).
        let foreignDeviceID = "!" + DeviceIdentity.stable()
        let foreignCorrectionAt = localCorrectionAt.addingTimeInterval(300)
        try writeForeignMarkers(deviceID: foreignDeviceID, [
            StructureMarker(seq: 0, frame: 0, kind: .correctionVoice, voice: "guest", at: foreignCorrectionAt),
        ])

        let transcript = await model().transcript(for: captureID)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.map(\.voice), ["guest"],
                       "the later-stamped PEER correction must win over this device's own earlier one")
    }

    /// The own-absent-but-foreign-present case (design #11 restated per-stream): this
    /// device never marked voices at all, but a peer did — attribution must still work.
    @MainActor
    func testOwnStreamAbsentButForeignStreamPresentStillAttributesVoices() async throws {
        try writeManifest()
        try writeLiveTranscript([
            ("intro words", 0, 20_000),
            ("reply words", 40_000, 60_000),
        ])
        // No markers.jsonl of our own at all.
        try writeForeignMarkers(deviceID: "device-peer", [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn", at: stamp(0)),
            StructureMarker(seq: 1, frame: 30_000, kind: .voice, voice: "ln", at: stamp(10)),
        ])

        let transcript = await model().transcript(for: captureID)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.map(\.voice), ["bn", "ln"])
    }
}
