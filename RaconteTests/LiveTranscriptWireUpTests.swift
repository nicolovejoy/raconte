import XCTest
import AVFoundation
@testable import Raconte

/// M2 T3 wire-up: the session actually writing `live.jsonl`, and the accounting that
/// feeds `TranscriptRef`.
final class LiveTranscriptWireUpTests: XCTestCase {

    private var root: URL!
    private var captureDir: URL!

    private let captureFormat = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32, interleaved: false)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wireup-\(UUID().uuidString)")
        captureDir = root.appendingPathComponent("cap")
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var transcriptDir: URL {
        SegmentLayout.transcriptDirectory(captureDirectory: captureDir)
    }

    private func session(_ engine: ScriptedTranscriptionEngine) -> TranscriptionSession {
        TranscriptionSession(engine: engine,
                             inputFormat: captureFormat,
                             captureDirectory: captureDir)
    }

    private func result(_ text: String, _ start: Int64, _ end: Int64,
                        volatile: Bool = false,
                        finalizedThrough: Int64? = nil) -> TranscriptResult {
        TranscriptResult(text: text,
                         range: FrameRange(start: start, end: end),
                         isVolatile: volatile,
                         confidence: nil,
                         finalizedThroughFrame: finalizedThrough)
    }

    /// Waits for the session's drain to observe an emitted result.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: The quarantine hazard (design §11.6)

    /// A capture that never produced a word must leave no `transcript/` behind. A
    /// zero-byte log flips `holdsIrreplaceableArtifacts`, which turns the delete
    /// decision into the quarantine no-op — so an eager open would make every
    /// denied-permission tap and every accidental sub-second tap leave a directory that
    /// can never be cleaned up.
    func testNoTranscriptDirectoryUntilARecordIsWritten() async {
        let engine = ScriptedTranscriptionEngine()
        let session = session(engine)
        await session.start()
        await settle()

        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptDir.path),
                       "opening eagerly quarantines every mis-tap forever")

        await session.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptDir.path),
                       "and a capture with no words leaves nothing behind at all")
    }

    func testTranscriptDirectoryAppearsOnTheFirstCommittedRecord() async {
        let engine = ScriptedTranscriptionEngine()
        let session = session(engine)
        await session.start()
        engine.emit(result("hello", 0, 4_800))
        await settle()

        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptDir.path))
        let count = await session.committedRecords
        XCTAssertEqual(count, 1)
        await session.finish()
    }

    // MARK: What lands on disk

    /// The property the whole log exists for: read it back, fold it through the
    /// consolidator, and you get what was on screen.
    func testWrittenLogReplaysToTheLiveTranscript() async {
        let engine = ScriptedTranscriptionEngine()
        let session = session(engine)
        await session.start()

        engine.emit(result("teh cat", 0, 4_800))
        engine.emit(result("the cat", 0, 4_800))          // revision
        engine.emit(result("misheard", 4_800, 9_600))
        engine.emit(result("", 4_800, 9_600))             // revocation
        engine.emit(result("sat down", 9_600, 14_400))
        await settle()
        let live = await session.committedText
        await session.finish()

        let loaded = LiveTranscriptReader.load(captureDirectory: captureDir)
        XCTAssertEqual(loaded.source, .present(try! Data(contentsOf:
            SegmentLayout.liveTranscriptURL(captureDirectory: captureDir))))
        XCTAssertEqual(LiveTranscriptReader.consolidate(loaded.records).committedText, live)
        XCTAssertEqual(live, "the cat sat down")
    }

    func testPromotedHypothesesAreWrittenNotJustHeld() async {
        let engine = ScriptedTranscriptionEngine()
        let session = session(engine)
        await session.start()

        engine.emit(result("hello", 0, 4_800, volatile: true))
        engine.emit(result("world", 4_800, 9_600, volatile: true, finalizedThrough: 4_800))
        await settle()
        await session.finish()

        let records = LiveTranscriptReader.load(captureDirectory: captureDir).records
        XCTAssertEqual(records.map(\.text), ["hello"],
                       "a promotion the SDK never reissues exists only on disk if we write it")
    }

    func testRecordsCarryGeneratorAndLocaleFromPrepare() async {
        let engine = ScriptedTranscriptionEngine()
        engine.setup = TranscriptionSetup(generator: "DictationTranscriber",
                                          locale: "fr_FR",
                                          analysisFormat: engine.analysisFormat)
        let session = session(engine)
        await session.start()
        engine.emit(result("bonjour", 0, 4_800))
        await settle()
        await session.finish()

        let record = LiveTranscriptReader.load(captureDirectory: captureDir).records.first
        XCTAssertEqual(record?.generator, "DictationTranscriber")
        XCTAssertEqual(record?.locale, "fr_FR")
    }

    /// §0: a logging fault must never reach the capture path.
    func testLoggingFailureDoesNotFailTheSession() async {
        let engine = ScriptedTranscriptionEngine()
        // A file where the transcript directory needs to be — `open()` cannot succeed.
        try? FileManager.default.removeItem(at: transcriptDir)
        FileManager.default.createFile(atPath: transcriptDir.path, contents: Data())

        let session = session(engine)
        await session.start()
        engine.emit(result("words", 0, 4_800))
        await settle()

        let state = await session.state
        XCTAssertEqual(state, .running, "the transcript is derived; the recording is not")
        let text = await session.committedText
        XCTAssertEqual(text, "words", "and the in-memory transcript still works")
        await session.finish()
    }

    // MARK: Coverage accounting

    func testOverlappingLedgersAreUnionedNotSummed() {
        // The sink's drop and the session's observation of that same gap.
        let ranges = [FrameRange(start: 100, end: 200), FrameRange(start: 150, end: 250)]
        XCTAssertEqual(FrameRangeSet.union(ranges), [FrameRange(start: 100, end: 250)])
        XCTAssertEqual(FrameRangeSet.frameCount(ranges), 150,
                       "summing would say 200 and understate coverage")
    }

    func testAdjacentRangesCoalesce() {
        let ranges = [FrameRange(start: 0, end: 100), FrameRange(start: 100, end: 200)]
        XCTAssertEqual(FrameRangeSet.union(ranges), [FrameRange(start: 0, end: 200)])
    }

    func testDisjointRangesStayApart() {
        let ranges = [FrameRange(start: 300, end: 400), FrameRange(start: 0, end: 100)]
        XCTAssertEqual(FrameRangeSet.union(ranges),
                       [FrameRange(start: 0, end: 100), FrameRange(start: 300, end: 400)])
        XCTAssertEqual(FrameRangeSet.frameCount(ranges), 200)
    }

    func testEmptyRangesAreIgnored() {
        XCTAssertEqual(FrameRangeSet.union([FrameRange(start: 50, end: 50)]), [])
    }
}
