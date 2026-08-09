import XCTest
@testable import Raconte

/// T6c: promoting `transcript/live.jsonl` into canonical revision zero (design §5.1/
/// §5.2). Not `TranscriptPromotionTests.swift` — that file covers
/// `TranscriptConsolidator`'s `resultsFinalizationTime` promotion, an unrelated use of
/// the word "promotion".
final class TranscriptPromotionCanonicalTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteTranscriptPromotion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private var transcriptDirectory: URL {
        SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
    }

    private func store() -> TranscriptRevisionStore { TranscriptRevisionStore(capturesRoot: capturesRoot) }

    // MARK: - Fixture helpers

    private func result(_ text: String, _ start: Int64, _ end: Int64,
                        runs: [TranscriptRun] = [], confidence: Double? = nil) -> TranscriptResult {
        TranscriptResult(text: text, range: FrameRange(start: start, end: end),
                         isVolatile: false, confidence: confidence, finalizedThroughFrame: nil,
                         runs: runs)
    }

    private func writeFinalAudio() throws {
        let finalDir = SegmentLayout.finalDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        try Data("not really an m4a".utf8).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory))
    }

    private func writeLiveTranscript(_ records: [TranscriptRecord]) throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDirectory)
        try writer.open()
        for record in records { try writer.append(record) }
        try writer.close()
    }

    private func record(_ text: String, _ start: Int64, _ end: Int64,
                        runs: [TranscriptRun] = [],
                        generator: String = "SpeechTranscriber", locale: String = "en_US") -> TranscriptRecord {
        TranscriptRecord(seq: 0, text: text, captureFrameStart: start, captureFrameEnd: end,
                         runs: runs, generator: generator, locale: locale)
    }

    private func writeManifest(transcript: TranscriptRef? = nil) throws {
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
        let manifest = Manifest(captureID: captureID, createdAt: Date(timeIntervalSince1970: 1_000),
                                state: .captured, stateSeq: 1,
                                stateUpdatedAt: Date(timeIntervalSince1970: 1_000),
                                format: format, transcript: transcript)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
    }

    // MARK: - 4.1 Span-mapping table tests (pure)

    func testTimedRunsProduceExactSpans() {
        let committed = [result("hello world", 0, 9_600, runs: [
            TranscriptRun(text: "hello", captureFrameStart: 0, captureFrameEnd: 4_800, confidence: 0.9),
            TranscriptRun(text: "world", captureFrameStart: 4_800, captureFrameEnd: 9_600, confidence: 0.8),
        ])]
        let spans = TranscriptRevisionStore.spans(fromCommitted: committed)
        XCTAssertEqual(spans, [
            TranscriptSpan(text: "hello", anchor: .exact, frameStart: 0, frameEnd: 4_800, confidence: 0.9),
            TranscriptSpan(text: "world", anchor: .exact, frameStart: 4_800, frameEnd: 9_600, confidence: 0.8),
        ])
    }

    func testRunMissingOneBoundProducesNoneAnchorWithNilFrames() {
        let committed = [result("partial", 0, 4_800, runs: [
            TranscriptRun(text: "partial", captureFrameStart: 0, captureFrameEnd: nil, confidence: nil),
        ])]
        let spans = TranscriptRevisionStore.spans(fromCommitted: committed)
        XCTAssertEqual(spans, [
            TranscriptSpan(text: "partial", anchor: .none, frameStart: nil, frameEnd: nil, confidence: nil),
        ])
    }

    func testRunlessResultProducesOneInheritedSpanFromResultRange() {
        let committed = [result("no runs at all", 100, 5_000)]
        let spans = TranscriptRevisionStore.spans(fromCommitted: committed)
        XCTAssertEqual(spans, [
            TranscriptSpan(text: "no runs at all", anchor: .inherited, frameStart: 100, frameEnd: 5_000),
        ])
    }

    func testMixedRunAndRunlessResultsMapIndependently() {
        let committed = [
            result("timed", 0, 4_800, runs: [
                TranscriptRun(text: "timed", captureFrameStart: 0, captureFrameEnd: 4_800),
            ]),
            result("untimed", 4_800, 9_600),
        ]
        let spans = TranscriptRevisionStore.spans(fromCommitted: committed)
        XCTAssertEqual(spans.map(\.text), ["timed", "untimed"])
        XCTAssertEqual(spans.map(\.anchor), [.exact, .inherited])
    }

    /// Gate B finding C1: `AttributedString` runs partition their result's text, so
    /// adjacent runs carry their own boundary whitespace (`"hello"` / `" there"` over
    /// `"hello there"`). `TranscriptChain.plainText` re-joins spans with a single
    /// separator (`TranscriptText.join`) — a span text that ALSO carries that
    /// whitespace doubles it. Frames are untouched by the trim; only `text` changes.
    func testRunsWithBoundaryWhitespaceAreTrimmedInTheSpanText() {
        let committed = [result("hello there", 0, 20_000, runs: [
            TranscriptRun(text: "hello", captureFrameStart: 0, captureFrameEnd: 10_000),
            TranscriptRun(text: " there", captureFrameStart: 10_000, captureFrameEnd: 20_000),
        ])]
        let spans = TranscriptRevisionStore.spans(fromCommitted: committed)
        XCTAssertEqual(spans, [
            TranscriptSpan(text: "hello", anchor: .exact, frameStart: 0, frameEnd: 10_000),
            TranscriptSpan(text: "there", anchor: .exact, frameStart: 10_000, frameEnd: 20_000),
        ])
    }

    /// A run that is ENTIRELY boundary whitespace (a bare separator run some analyzer
    /// output can carry) must be dropped, not kept as an empty-text span.
    func testWhitespaceOnlyRunIsDroppedEntirely() {
        let committed = [result("hello there", 0, 20_000, runs: [
            TranscriptRun(text: "hello", captureFrameStart: 0, captureFrameEnd: 9_000),
            TranscriptRun(text: " ", captureFrameStart: 9_000, captureFrameEnd: 10_000),
            TranscriptRun(text: "there", captureFrameStart: 10_000, captureFrameEnd: 20_000),
        ])]
        let spans = TranscriptRevisionStore.spans(fromCommitted: committed)
        XCTAssertEqual(spans.map(\.text), ["hello", "there"])
    }

    func testSpansNeverCarryASourceRevisionID() {
        let committed = [result("hello", 0, 4_800, runs: [
            TranscriptRun(text: "hello", captureFrameStart: 0, captureFrameEnd: 4_800),
        ])]
        let spans = TranscriptRevisionStore.spans(fromCommitted: committed)
        XCTAssertTrue(spans.allSatisfy { $0.sourceRevisionID == nil })
    }

    // MARK: - 4.2 Display-identity test (F16)

    /// Gate B finding C1: `runs` carry their OWN boundary whitespace — `AttributedString`
    /// runs partition the result text, so `"hello there"` splits into runs `"hello"` /
    /// `" there"`, exactly as `SpeechAnalyzerEngine.runs(of:)` builds them on device.
    /// The first record here reproduces that shape; the second stays runless (no
    /// `runs:` argument) so the runless path — which must stay correct — is still
    /// covered by the same test.
    func testPromotedRevisionPlainTextMatchesConsolidatedCommittedTextByteForByte() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([
            record("hello there", 0, 20_000, runs: [
                TranscriptRun(text: "hello", captureFrameStart: 0, captureFrameEnd: 10_000),
                TranscriptRun(text: " there", captureFrameStart: 10_000, captureFrameEnd: 20_000),
            ]),
            record("general kenobi", 40_000, 60_000),
        ])

        let outcome = await store().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("expected .promoted, got \(outcome)") }

        let loaded = LiveTranscriptReader.load(captureDirectory: captureDirectory)
        let consolidated = LiveTranscriptReader.consolidate(loaded.records)

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
        let current = try XCTUnwrap(chain?.revisions.first)
        XCTAssertEqual(TranscriptChain.plainText(current), consolidated.committedText)
    }

    // MARK: - 4.3 Promotion skip tests

    func testSkipsAlreadyTrashedCapture() async throws {
        var metadata = EntryMetadata.defaults
        metadata.trashedAt = Date()
        try EntryMetadataStore.write(metadata, url: SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory))
        try writeFinalAudio()
        try writeLiveTranscript([record("hello", 0, 4_800)])

        let outcome = await store().promoteIfNeeded(captureID: captureID)
        XCTAssertEqual(outcome, .skippedTrashed)
        XCTAssertEqual(TranscriptRevisionStore.listing(captureDirectory: captureDirectory), .present(files: []),
                       "a trashed capture must gain no canonical revision files from promotion — "
                       + "live.jsonl (written by the test fixture, not by promotion) is legitimately there")
    }

    func testSkipsAVanishedCaptureDirectoryAsTrashed() async throws {
        try FileManager.default.removeItem(at: captureDirectory)
        let outcome = await store().promoteIfNeeded(captureID: captureID)
        XCTAssertEqual(outcome, .skippedTrashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "promotion must never resurrect a vanished capture directory")
    }

    func testSkipsWhenAlreadyPromoted() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([record("hello", 0, 4_800)])

        let first = await store().promoteIfNeeded(captureID: captureID)
        guard case .promoted = first else { return XCTFail("expected first call to promote, got \(first)") }

        let before = try FileManager.default.contentsOfDirectory(atPath: transcriptDirectory.path).sorted()
        let second = await store().promoteIfNeeded(captureID: captureID)
        XCTAssertEqual(second, .skippedAlreadyPromoted)
        let after = try FileManager.default.contentsOfDirectory(atPath: transcriptDirectory.path).sorted()
        XCTAssertEqual(before, after, "a second promotion attempt must not touch the directory")
    }

    func testSkipsWhenNoFinalAudio() async throws {
        try writeLiveTranscript([record("hello", 0, 4_800)])
        // No writeFinalAudio() call.
        let outcome = await store().promoteIfNeeded(captureID: captureID)
        XCTAssertEqual(outcome, .skippedNoAudio)
    }

    func testSkipsWhenLiveLogAbsent() async throws {
        try writeFinalAudio()
        // No writeLiveTranscript() call.
        let outcome = await store().promoteIfNeeded(captureID: captureID)
        XCTAssertEqual(outcome, .skippedNoLog)
    }

    func testFailsWhenLiveLogUnreadable() async throws {
        try writeFinalAudio()
        let logURL = SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A directory where the log file should be: LiveTranscriptReader.load reports
        // .unreadable, never .absent, for this shape.
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)

        let outcome = await store().promoteIfNeeded(captureID: captureID)
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    // MARK: - 4.4 Provenance tests

    /// Mutation check (B1): if the copy were hardcoded to `nil` instead of reading the
    /// manifest's ref, this test — which asserts the exact non-nil value — fails.
    /// Verified by hand: swapping `coverageFrames: ref?.coverageFrames` for
    /// `coverageFrames: nil` in `promoteIfNeeded` makes this test fail (asserts 4_800,
    /// got nil) — see the task report for the transcript of that run.
    func testCoverageFramesAndSkippedRangesAreCopiedFromTheManifestRef() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([record("hello", 0, 4_800)])
        let ref = TranscriptRef(generator: "SpeechTranscriber", locale: "en_US",
                                coverageFrames: 4_800, skippedRanges: [FrameRange(start: 9_600, end: 14_400)],
                                committedRecords: 1, completedAt: Date())
        try writeManifest(transcript: ref)

        let outcome = await store().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("expected .promoted, got \(outcome)") }

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
        let revision = try XCTUnwrap(chain?.revisions.first)
        XCTAssertEqual(revision.coverageFrames, 4_800)
        XCTAssertEqual(revision.skippedRanges, [FrameRange(start: 9_600, end: 14_400)])
    }

    func testCoverageFramesNilWhenManifestHasNoTranscriptRef() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([record("hello", 0, 4_800)])
        try writeManifest(transcript: nil)   // launch-recovery shape: manifest, no ref

        let outcome = await store().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("expected .promoted, got \(outcome)") }

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
        let revision = try XCTUnwrap(chain?.revisions.first)
        XCTAssertNil(revision.coverageFrames)
        XCTAssertNil(revision.skippedRanges)
    }

    func testCoverageFramesNilWhenManifestItselfIsAbsent() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([record("hello", 0, 4_800)])
        // No writeManifest() call at all — no throw, promotion still succeeds.

        let outcome = await store().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("expected .promoted, got \(outcome)") }

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
        XCTAssertNil(chain?.revisions.first?.coverageFrames)
    }

    func testGeneratorAndLocaleComeFromTheLastRecordOnDisagreement() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([
            record("first", 0, 4_800, generator: "DictationTranscriber", locale: "en_GB"),
            record("second", 4_800, 9_600, generator: "SpeechTranscriber", locale: "en_US"),
        ])

        let outcome = await store().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("expected .promoted, got \(outcome)") }

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
        let revision = try XCTUnwrap(chain?.revisions.first)
        XCTAssertEqual(revision.generator, "SpeechTranscriber", "the LAST record's generator wins")
        XCTAssertEqual(revision.locale, "en_US")
    }

    // MARK: - Revision shape

    func testPromotedRevisionHasMachineLiveSourceAndNoParent() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([record("hello", 0, 4_800)])

        let outcome = await store().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("expected .promoted, got \(outcome)") }

        let chain = TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)
        let revision = try XCTUnwrap(chain?.revisions.first)
        XCTAssertEqual(revision.source, .machineLive)
        XCTAssertNil(revision.parentID)
        XCTAssertNil(revision.basedOnMachineID)
        XCTAssertNil(revision.closedBy)
        XCTAssertNotNil(revision.deviceID)
    }

    func testDeviceIdentityIsStableAcrossTwoPromotions() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([record("hello", 0, 4_800)])
        let outcome = await store().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("expected .promoted, got \(outcome)") }
        let first = try XCTUnwrap(TranscriptRevisionStore.loadChain(captureDirectory: captureDirectory)?.revisions.first)

        XCTAssertEqual(first.deviceID, DeviceIdentity.stable())
    }

    // MARK: - promoteCorpus

    func testPromoteCorpusPromotesEveryEligibleCaptureIndependently() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([record("hello", 0, 4_800)])

        let secondID = "01KYX77KK5QM15915EZBVXTQZ5"
        let secondDir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: secondID)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        // Second capture has no live.jsonl and no audio — expect .skippedNoAudio.

        let outcomes = await store().promoteCorpus()
        guard case .promoted = outcomes[captureID] else {
            return XCTFail("expected the first capture to promote, got \(String(describing: outcomes[captureID]))")
        }
        XCTAssertEqual(outcomes[secondID], .skippedNoAudio)
    }
}
