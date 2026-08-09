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

    func testParagraphOnlyMarkersProduceUnlabeledParagraphs() async throws {
        try writeManifest(idA)
        try writeLiveTranscript(idA, [
            ("first paragraph", 0, 20_000),
            ("second paragraph", 40_000, 60_000),
        ])
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

    // MARK: - Sample rate comes off the manifest, not a constant

    /// Direct loader call (brief step 2): the manifest read that supplies the real
    /// sample rate lives in `LibraryScreenModel`, so this exercises `AttributionMode`
    /// straight, with two window sizes chosen to disagree on where a tap snaps.
    func testSampleRateComesFromTheManifest() throws {
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
        XCTAssertEqual(narrowParagraphs.count, 1,
                       "the narrower 16kHz window misses the gap and the tap lands mid-run")
        XCTAssertNotEqual(wideParagraphs, narrowParagraphs)
    }
}
