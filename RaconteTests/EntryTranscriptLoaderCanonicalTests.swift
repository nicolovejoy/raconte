import XCTest
@testable import Raconte

/// T6c: `EntryTranscriptLoader.load`'s canonical-chain preference (design §4.8, "three
/// answers all the way down"). Sibling to `TranscriptAttributionLoadTests.swift`
/// (there's no single `EntryTranscriptLoaderTests` file to extend — this covers the
/// same seam it does, one layer earlier in the read).
final class EntryTranscriptLoaderCanonicalTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteEntryTranscriptLoaderCanonical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private func revisionStore() -> TranscriptRevisionStore { TranscriptRevisionStore(capturesRoot: capturesRoot) }

    private func writeFinalAudio() throws {
        let finalDir = SegmentLayout.finalDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        try Data("not really an m4a".utf8).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory))
    }

    private func writeLiveTranscript(_ records: [(text: String, start: Int64, end: Int64)]) throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDirectory)
        try writer.open()
        for record in records {
            try writer.append(TranscriptRecord(seq: 0, text: record.text,
                                               captureFrameStart: record.start,
                                               captureFrameEnd: record.end,
                                               generator: "SpeechTranscriber", locale: "en_US"))
        }
        try writer.close()
    }

    private func writeLiveTranscriptRecords(_ records: [TranscriptRecord]) throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDirectory)
        try writer.open()
        for record in records { try writer.append(record) }
        try writer.close()
    }

    @discardableResult
    private func writeRawCanonical(_ n: Int, _ revision: TranscriptRevision) throws -> URL {
        let dir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: n)
        try CaptureCoding.encoder().encode(revision).write(to: url)
        return url
    }

    private func revision(_ id: String, text: String) -> TranscriptRevision {
        TranscriptRevision(id: id, source: .machineLive,
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                           spans: [TranscriptSpan(text: text, anchor: .none)])
    }

    private func writeMarkers(_ markers: [StructureMarker]) throws {
        let writer = MarkerLogWriter(captureDirectory: captureDirectory)
        try writer.open()
        for marker in markers { try writer.append(marker) }
        try writer.close()
    }

    // MARK: - Canonical present

    func testCanonicalPresentSuppliesTextOverLiveJSONL() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([("original words", 0, 20_000)])
        let outcome = await revisionStore().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("fixture setup failed: \(outcome)") }
        // A second, human revision on top — this is what the loader must actually show.
        try writeRawCanonical(1, TranscriptRevision(
            id: "EDITED", source: .userEdit, createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            spans: [TranscriptSpan(text: "edited words", anchor: .none)]))

        let transcript = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil)

        XCTAssertEqual(transcript.state, .present)
        XCTAssertEqual(transcript.text, "edited words", "the canonical chain's current revision must win")
    }

    // MARK: - Canonical + undecodable sibling

    func testCanonicalWithAnUndecodableSiblingDegradesButShowsBestReadableText() async throws {
        try writeRawCanonical(0, revision("R0", text: "readable revision"))
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)
        try Data("{ not valid json at all".utf8).write(
            to: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 1))

        let transcript = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil)

        XCTAssertEqual(transcript.text, "readable revision")
        XCTAssertTrue(transcript.degradations.contains(.revisionUnreadable),
                      "an unreadable sibling file must be surfaced even though the current revision is fine")
    }

    // MARK: - All revisions unreadable

    func testAllRevisionsUnreadableFallsBackToLiveJSONL() async throws {
        try writeLiveTranscript([("fallback words", 0, 20_000)])
        try FileManager.default.createDirectory(
            at: SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory),
            withIntermediateDirectories: true)
        try Data("{ not valid json at all".utf8).write(
            to: SegmentLayout.canonicalTranscriptURL(captureDirectory: captureDirectory, revision: 0))

        let transcript = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil)

        XCTAssertEqual(transcript.state, .present)
        XCTAssertEqual(transcript.text, "fallback words",
                       "with no attached canonical revision, live.jsonl must still be read")
        XCTAssertTrue(transcript.degradations.contains(.revisionUnreadable),
                      "the owner should still learn a revision file couldn't be read")
    }

    // MARK: - No canonical at all (today's path, pinned)

    func testNoCanonicalChainUsesTodaysLiveJSONLPathUnchanged() {
        // No transcript/ directory at all — the overwhelmingly common case for every
        // capture that predates T6c, or hasn't finalized yet.
        let dummyLive = ["one two three"]
        try? writeLiveTranscript(dummyLive.map { ($0, Int64(0), Int64(20_000)) })

        let transcript = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil)

        XCTAssertEqual(transcript.state, .present)
        XCTAssertEqual(transcript.text, "one two three")
        XCTAssertFalse(transcript.degradations.contains(.revisionUnreadable))
    }

    // MARK: - Detection boundary (C3): SpokenDateDetection sees identical text pre/post promotion

    /// Gate B finding C1: the record's runs carry their own boundary whitespace
    /// (`AttributedString` partitions the result text) — the shape
    /// `SpeechAnalyzerEngine.runs(of:)` actually produces on device, e.g. `"recorded"` /
    /// `" on march third nineteen ninety eight"`. Before the trim fix, promotion's
    /// re-join would double that boundary space and `before`/`after` would disagree.
    ///
    /// T7 Task 3 fix round 1, Minor 4: MUST use `.compute`, not the default `.skip`.
    /// Production `SpokenDateDetection` reads via `LibraryScreenModel.transcript(for:)`
    /// (← `CaptureView.detectSpokenDate`), which always asks for `.compute`. Under the
    /// default `.skip` this test would compare live-consolidated text against a
    /// `TranscriptHeadSummary.snippet` truncated at `EntrySnippet.characterLimit` (160)
    /// — it only ever passed because this fixture's text is 47 chars, single-line, well
    /// under that limit. `.skip` would silently stop catching a doubled boundary space
    /// the moment someone lengthened the fixture past 160 characters.
    func testSpokenDateDetectionInputTextIsIdenticalBeforeAndAfterPromotion() async throws {
        try writeFinalAudio()
        try writeLiveTranscriptRecords([
            TranscriptRecord(seq: 0, text: "recorded on march third nineteen ninety eight",
                             captureFrameStart: 0, captureFrameEnd: 20_000,
                             runs: [
                                 TranscriptRun(text: "recorded", captureFrameStart: 0, captureFrameEnd: 8_000),
                                 TranscriptRun(text: " on march third nineteen ninety eight",
                                              captureFrameStart: 8_000, captureFrameEnd: 20_000),
                             ],
                             generator: "SpeechTranscriber", locale: "en_US"),
        ])

        let before = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil,
                                                 attribution: .compute(sampleRate: 48_000))
        let outcome = await revisionStore().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("fixture setup failed: \(outcome)") }
        let after = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil,
                                                attribution: .compute(sampleRate: 48_000))

        XCTAssertEqual(before.text, after.text,
                       "SpokenDateDetection reads transcript.text — promotion must not change it")
    }

    // MARK: - Review finding 1: truncation/unreadability must survive the canonical branch

    /// A capture killed mid-write has a short `live.jsonl`; the launch pass promotes
    /// exactly that short log into revision zero. The canonical branch must still
    /// surface `.transcriptTruncated` — losing it would silently hide the one signal
    /// this codebase is most careful never to drop.
    func testCanonicalBranchStillSurfacesTranscriptTruncated() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([("only one record made it", 0, 20_000)])
        let outcome = await revisionStore().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("fixture setup failed: \(outcome)") }

        // expectedRecords: 2 — the manifest's TranscriptRef.committedRecords says two
        // records were committed before the clean close; only one landed on disk.
        let transcript = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: 2)

        XCTAssertEqual(transcript.state, .present, "the canonical branch still supplies text")
        XCTAssertTrue(transcript.degradations.contains(.transcriptTruncated),
                      "truncation must not be silently lost once promotion takes over")
    }

    /// Symmetric case: the promoted revision itself is fine, but the `live.jsonl` that
    /// produced it can no longer be read (e.g. permissions damage after the fact). The
    /// promoted text is only as good as the log it came from, so this must surface too.
    func testCanonicalBranchStillSurfacesTranscriptUnreadable() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([("hello there", 0, 20_000)])
        let outcome = await revisionStore().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("fixture setup failed: \(outcome)") }

        let logURL = SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: logURL.path),
                      "running as root — permissions cannot be made to bite")

        let transcript = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil)

        XCTAssertEqual(transcript.state, .present, "the canonical revision itself is still readable")
        XCTAssertTrue(transcript.degradations.contains(.transcriptUnreadable),
                      "the source log being unreadable must surface even though `current` decoded fine")
    }

    // MARK: - Review finding 2: paragraphs must not silently mix sources

    /// The brief's ".compute mode... add the test proving it" — the case that was
    /// previously untested at the loader level: a machine-live current revision with a
    /// marker log present must still attribute paragraphs normally.
    func testComputeModeAttributesParagraphsWhenCurrentRevisionIsMachineLive() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([("intro words", 0, 20_000), ("reply words", 40_000, 60_000)])
        let outcome = await revisionStore().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("fixture setup failed: \(outcome)") }
        try writeMarkers([
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: StructureMarker.Voice.bigNico),
            StructureMarker(seq: 1, frame: 30_000, kind: .voice, voice: StructureMarker.Voice.littleNico),
        ])

        let transcript = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil,
                                                     attribution: .compute(sampleRate: 48_000))

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.map(\.text), ["intro words", "reply words"])
        XCTAssertEqual(transcript.text, "intro words reply words")
    }

    /// A human revision (T6d/T6e onward) has diverged from `live.jsonl` by definition.
    /// `paragraphs` must be nil rather than attributing markers.jsonl over post-edit
    /// text — otherwise a marked-up entry would silently show stale pre-edit words
    /// under a voice label.
    func testComputeModeReturnsNilParagraphsWhenCurrentRevisionIsNotMachineLive() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([("intro words", 0, 20_000), ("reply words", 40_000, 60_000)])
        let outcome = await revisionStore().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("fixture setup failed: \(outcome)") }
        try writeMarkers([
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: StructureMarker.Voice.bigNico),
            StructureMarker(seq: 1, frame: 30_000, kind: .voice, voice: StructureMarker.Voice.littleNico),
        ])
        // A divergent human edit on top — the shape T6d/T6e will produce.
        try writeRawCanonical(1, TranscriptRevision(
            id: "EDITED", source: .userEdit, createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            spans: [TranscriptSpan(text: "a completely rewritten paragraph", anchor: .none)]))

        let transcript = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil,
                                                     attribution: .compute(sampleRate: 48_000))

        XCTAssertEqual(transcript.text, "a completely rewritten paragraph")
        XCTAssertNil(transcript.paragraphs,
                    "markers.jsonl attribution must not be shown over text it never produced")
    }
}
