import XCTest
@testable import Raconte

/// T7 plan step 2: the read-path wire — `EntryTranscriptLoader` → `MarkerLogReader` →
/// `MarkerSnapping` → `TranscriptAttribution` — exercised through real disk fixtures,
/// the way `LibraryScreenModelTests` exercises the transcript-only path it extends.
///
/// Marker-source rules under test (design §7, non-negotiable): `.absent` and
/// `.unreadable` both mean *no voices assigned*, never "single voice" — and the
/// library scanner must never pay for a marker-log read at all.
@MainActor
final class TranscriptAttributionLoadTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    private let idA = "01AAAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptAttributionLoad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    /// A manifest on disk (no journal, no backdate) — enough for `model.transcript(for:)`
    /// to find a capture-frame format and, in step 2, a sample rate.
    private func writeManifest(_ id: String, sampleRate: Int = 48_000) throws {
        let format = AudioFormatDescriptor(sampleRate: sampleRate, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let created = Date(timeIntervalSince1970: 1_000)
        let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try FileManager.default.createDirectory(at: captureDir(id), withIntermediateDirectories: true)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
    }

    private func writeLiveTranscript(_ id: String,
                                     _ records: [(text: String, start: Int64, end: Int64)]) throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(id))
        try writer.open()
        for record in records {
            try writer.append(TranscriptRecord(seq: 0, text: record.text,
                                               captureFrameStart: record.start,
                                               captureFrameEnd: record.end,
                                               generator: "SpeechTranscriber", locale: "en_US"))
        }
        try writer.close()
    }

    private func writeMarkers(_ id: String, _ markers: [StructureMarker]) throws {
        let writer = MarkerLogWriter(captureDirectory: captureDir(id))
        try writer.open()
        for marker in markers {
            try writer.append(marker)
        }
        try writer.close()
    }

    private func markerLogURL(_ id: String) -> URL {
        SegmentLayout.markerLogURL(captureDirectory: captureDir(id))
    }

    // MARK: - End-to-end through the detail screen

    func testDetailTranscriptAttributesVoicesFromTheMarkerLog() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [
            ("intro words", 0, 20_000),
            ("reply words", 40_000, 60_000),
        ])
        try writeMarkers(idA, [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: StructureMarker.Voice.bigNico),
            StructureMarker(seq: 1, frame: 30_000, kind: .voice, voice: StructureMarker.Voice.littleNico),
        ])

        let transcript = await model().transcript(for: idA)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.map(\.voice), [StructureMarker.Voice.bigNico, StructureMarker.Voice.littleNico])
        XCTAssertEqual(paragraphs.map(\.text), ["intro words", "reply words"])
        XCTAssertEqual(transcript.text, "intro words reply words", "text is unaffected by attribution")
    }

    // MARK: - Marker-source rules (design §7)

    func testEntryWithNoMarkerFileHasNilParagraphsAndUnchangedText() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [("hello there", 0, 20_000)])
        // No markers.jsonl written at all — the common case (single-voice capture).

        let transcript = await model().transcript(for: idA)

        XCTAssertNil(transcript.paragraphs, "absent marker log must never render as single-voice")
        XCTAssertEqual(transcript.text, "hello there")
    }

    func testUnreadableMarkerLogAssignsNoVoices() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [("hello there", 0, 20_000)])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn")])

        let logURL = markerLogURL(idA)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: logURL.path),
                      "running as root — permissions cannot be made to bite")

        let transcript = await model().transcript(for: idA)

        XCTAssertNil(transcript.paragraphs,
                     "an unreadable log must never be read as 'single voice, nothing to see'")
        XCTAssertEqual(transcript.text, "hello there", "the transcript itself is untouched")
    }

    /// The split is attributable to the marker, not to the transcript's own shape: one
    /// `TranscriptRecord` carrying two timed runs, so without the `.paragraph` tap the
    /// pieces would stay one paragraph (§6's "record text used verbatim when a group
    /// holds every piece of its record" rule) — the same-record boundary is not a
    /// boundary the marker log did not create.
    func testParagraphOnlyMarkersProduceUnlabeledParagraphs() async throws {
        try writeManifest(idA)
        let writer = LiveTranscriptWriter(captureDirectory: captureDir(idA))
        try writer.open()
        try writer.append(TranscriptRecord(
            seq: 0, text: "first paragraph second paragraph",
            captureFrameStart: 0, captureFrameEnd: 60_000,
            runs: [
                TranscriptRun(text: "first paragraph", captureFrameStart: 0, captureFrameEnd: 20_000),
                TranscriptRun(text: "second paragraph", captureFrameStart: 40_000, captureFrameEnd: 60_000),
            ],
            generator: "SpeechTranscriber", locale: "en_US"))
        try writer.close()
        try writeMarkers(idA, [
            StructureMarker(seq: 0, frame: 30_000, kind: .paragraph),
        ])

        let transcript = await model().transcript(for: idA)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.map(\.text), ["first paragraph", "second paragraph"])
        XCTAssertTrue(paragraphs.allSatisfy { $0.voice == nil }, "paragraph markers carry no voice")
    }

    func testMarkersWithoutATranscriptLeaveTheAbsentStateAlone() async throws {
        try writeManifest(idA)
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn")])
        // No live.jsonl: transcription never ran on this capture.

        let transcript = await model().transcript(for: idA)

        XCTAssertEqual(transcript.state, .absent)
        XCTAssertNil(transcript.text)
        XCTAssertNil(transcript.paragraphs)
    }

    // MARK: - Performance contract: the scanner never reads markers.jsonl

    func testLibraryScanDoesNotComputeAttribution() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [("hello there", 0, 20_000)])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn")])

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        let capture = try XCTUnwrap(snapshot.captures.first { $0.captureID == idA })

        let transcript = LibraryScanner.transcriptSummary(capture)

        XCTAssertNil(transcript.paragraphs,
                     "the scanner defaults to .skip and must not pay for a markers.jsonl read")
        XCTAssertEqual(transcript.text, "hello there", "the scan's own job is unaffected")
    }

    // MARK: - Window size (the mechanism `AttributionMode.compute(sampleRate:)` drives)

    /// Not a manifest test — a direct `AttributionMode.compute(sampleRate:)` call, to pin
    /// down the *mechanism* `testSampleRateComesFromTheManifest` below depends on: two
    /// window sizes that disagree on where a tap snaps, chosen by hand against
    /// `MarkerSnapping.snap`'s rule order (rule 1's gap intersection vs. rule 4's
    /// raw-frame fallback). The narrow window's outcome is asserted on the property the
    /// window size actually changes — `hasApproximateBoundary` — not just a count, so a
    /// change that shuffled paragraph counts for an unrelated reason would not pass this
    /// by accident.
    func testWiderSnapWindowFindsAGapTheNarrowerWindowMisses() throws {
        try writeLiveTranscript(idA, [
            ("hello there", 0, 50_000),
            ("world", 90_000, 100_000),
        ])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 20_000, kind: .voice, voice: "bn")])

        let wide = EntryTranscriptLoader.load(captureDirectory: captureDir(idA), expectedRecords: nil,
                                              attribution: .compute(sampleRate: 48_000))
        let narrow = EntryTranscriptLoader.load(captureDirectory: captureDir(idA), expectedRecords: nil,
                                                attribution: .compute(sampleRate: 16_000))

        let wideParagraphs = try XCTUnwrap(wide.paragraphs)
        let narrowParagraphs = try XCTUnwrap(narrow.paragraphs)
        XCTAssertEqual(wideParagraphs.count, 2,
                       "the wider 48kHz window reaches the nearby gap and finds the voice boundary")
        XCTAssertFalse(wideParagraphs.contains { $0.hasApproximateBoundary },
                       "the gap was found, so the cut is exact")

        XCTAssertEqual(narrowParagraphs.count, 1,
                       "the narrower 16kHz window misses the gap and the tap lands mid-run")
        XCTAssertTrue(try XCTUnwrap(narrowParagraphs.first).hasApproximateBoundary,
                      "nothing in the window means the raw tap frame is kept, and marked approximate")
    }

    /// The requirement itself: `Manifest.format.sampleRate`, not a constant, is what
    /// reaches `MarkerSnapping.windowFrames`. Same discriminating fixture as the window
    /// test above, but driven end-to-end through `model.transcript(for:)` off a manifest
    /// written at 16kHz — the fixture where 48kHz's window finds the gap (2 paragraphs)
    /// and 16kHz's doesn't (1, approximate). If the loader ever fell back to a literal
    /// 48_000 here, this would still see 2 paragraphs and fail.
    func testSampleRateComesFromTheManifest() async throws {
        try writeManifest(idA, sampleRate: 16_000)
        try writeLiveTranscript(idA, [
            ("hello there", 0, 50_000),
            ("world", 90_000, 100_000),
        ])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 20_000, kind: .voice, voice: "bn")])

        let transcript = await model().transcript(for: idA)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.count, 1, "16kHz off the manifest gives the narrow window's outcome")
        XCTAssertTrue(try XCTUnwrap(paragraphs.first).hasApproximateBoundary)
    }

    /// `manifestFacts`' 48kHz fallback (no manifest, or one that fails to decode) — the
    /// same discriminating fixture, so a broken fallback (e.g. 0 or a tiny default) would
    /// show up as the narrow-window outcome instead of the wide one.
    func testMissingManifestFallsBackTo48kHzForTheSnapWindow() async throws {
        // No writeManifest(idA) call: `transcript/` is created directly, same as a
        // capture whose manifest write never landed.
        try writeLiveTranscript(idA, [
            ("hello there", 0, 50_000),
            ("world", 90_000, 100_000),
        ])
        try writeMarkers(idA, [StructureMarker(seq: 0, frame: 20_000, kind: .voice, voice: "bn")])

        let transcript = await model().transcript(for: idA)

        let paragraphs = try XCTUnwrap(transcript.paragraphs)
        XCTAssertEqual(paragraphs.count, 2, "the 48kHz fallback finds the gap, same as an explicit 48kHz manifest")
        XCTAssertFalse(paragraphs.contains { $0.hasApproximateBoundary })
    }
}
