import XCTest
@testable import Raconte

/// Issue #11 and the decoder hazard behind it: a read that fails must never look like
/// a read that found nothing, and a shape change must never look like an empty file.
final class LiveTranscriptIntegrityTests: XCTestCase {

    private var root: URL!
    private var captureDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-integrity-\(UUID().uuidString)")
        captureDir = root.appendingPathComponent("cap")
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var logURL: URL { SegmentLayout.liveTranscriptURL(captureDirectory: captureDir) }

    private func record(_ text: String, seq: Int = 0) -> TranscriptRecord {
        TranscriptRecord(seq: seq,
                         text: text,
                         captureFrameStart: 0,
                         captureFrameEnd: 100,
                         generator: "SpeechTranscriber",
                         locale: "en_US")
    }

    // MARK: Absent vs unreadable

    func testAbsentLogReportsAbsent() {
        let loaded = LiveTranscriptReader.load(captureDirectory: captureDir)
        XCTAssertEqual(loaded.source, .absent)
        XCTAssertFalse(loaded.isUnreadable)
        XCTAssertTrue(loaded.records.isEmpty)
    }

    func testUnreadableLogIsNotReportedAsAbsent() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("real words"))
        try writer.close()

        // A log that exists and cannot be read. This is the case that used to be
        // indistinguishable from "no transcript yet".
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: logURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: logURL.path),
                      "running as root — permissions cannot be made to bite")

        let loaded = LiveTranscriptReader.load(captureDirectory: captureDir)
        XCTAssertTrue(loaded.isUnreadable)
        XCTAssertNotEqual(loaded.source, .absent,
                          "an unreadable log is not an absent one — issue #11")
    }

    /// The sharp edge: reopening an unreadable log restarted `seq` at 0 and appended
    /// records colliding with the ones already in the file. Refusing to open is the fix.
    func testWriterRefusesToReopenAnUnreadableLog() throws {
        let first = LiveTranscriptWriter(captureDirectory: captureDir)
        try first.open()
        try first.append(record("already here", seq: 0))
        try first.close()

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: logURL.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: logURL.path),
                      "running as root — permissions cannot be made to bite")

        let second = LiveTranscriptWriter(captureDirectory: captureDir)
        XCTAssertThrowsError(try second.open()) { error in
            guard case LiveTranscriptError.unreadableExistingLog = error else {
                return XCTFail("expected unreadableExistingLog, got \(error)")
            }
        }
    }

    // MARK: Tail loss

    func testTailLossIsDetectedAgainstTheManifestCount() {
        XCTAssertEqual(LiveTranscriptReader.completeness(lines: 3, expected: 3), .complete)
        XCTAssertEqual(LiveTranscriptReader.completeness(lines: 2, expected: 3),
                       .truncated(missing: 1))
        // No `TranscriptRef` — the capture was killed, so a short tail is expected and
        // is not a defect. `seq` alone can never tell you this.
        XCTAssertEqual(LiveTranscriptReader.completeness(lines: 2, expected: nil), .unknown)
    }

    func testTornTailIsInvisibleToSeqAlone() throws {
        let writer = LiveTranscriptWriter(captureDirectory: captureDir)
        try writer.open()
        try writer.append(record("one", seq: 0))
        try writer.append(record("two", seq: 1))
        try writer.close()

        // Kill mid-write: a complete file plus an unterminated fragment.
        var data = try Data(contentsOf: logURL)
        data.append(contentsOf: Array(#"{"seq":2,"text":"thr"#.utf8))
        try data.write(to: logURL)

        let loaded = LiveTranscriptReader.load(captureDirectory: captureDir)
        XCTAssertEqual(loaded.records.map(\.seq), [0, 1], "gapless — nothing to notice")
        XCTAssertEqual(LiveTranscriptReader.completeness(lines: loaded.completeLines, expected: 3),
                       .truncated(missing: 1),
                       "only the manifest's count reveals the loss")
    }

    // MARK: Decoder leniency

    /// The hazard that would have erased every log on the next shape change: Swift's
    /// synthesized decoder ignores property defaults, so a missing `runs` key threw,
    /// and `parse` silently skips lines it cannot decode.
    func testRecordWithoutRunsStillDecodes() throws {
        let line = #"{"seq":0,"text":"hi","captureFrameStart":0,"captureFrameEnd":100,"generator":"g","locale":"en_US"}"#
        let decoded = try CaptureCoding.decoder().decode(TranscriptRecord.self,
                                                         from: Data(line.utf8))
        XCTAssertEqual(decoded.text, "hi")
        XCTAssertEqual(decoded.runs, [])
        XCTAssertNil(decoded.analyzerStart)
    }

    func testWholeFileOfOlderRecordsSurvives() {
        let line = #"{"seq":0,"text":"one","captureFrameStart":0,"captureFrameEnd":100,"generator":"g","locale":"en_US"}"#
        let two = #"{"seq":1,"text":"two","captureFrameStart":100,"captureFrameEnd":200,"generator":"g","locale":"en_US"}"#
        let data = Data((line + "\n" + two + "\n").utf8)
        let parsed = LiveTranscriptReader.parse(data)
        XCTAssertEqual(parsed.records.map(\.text), ["one", "two"],
                       "a shape change must not silently erase the file")
    }

    /// Leniency stops at the identity fields — garbage still fails rather than
    /// decoding into a plausible-looking empty record.
    func testRecordMissingTextStillFails() {
        let line = #"{"seq":0,"captureFrameStart":0,"captureFrameEnd":100,"generator":"g","locale":"en_US"}"#
        XCTAssertThrowsError(try CaptureCoding.decoder().decode(TranscriptRecord.self,
                                                                from: Data(line.utf8)))
    }

    func testUntimedRunsRoundTrip() throws {
        var written = record("hi")
        written.runs = [TranscriptRun(text: "hi"),
                        TranscriptRun(text: "there", captureFrameStart: 10, captureFrameEnd: 20)]
        let data = try CaptureCoding.lineEncoder().encode(written)
        let decoded = try CaptureCoding.decoder().decode(TranscriptRecord.self, from: data)
        XCTAssertNil(decoded.runs[0].captureFrameStart,
                     "the SDK documents runs with no time range at all")
        XCTAssertEqual(decoded.runs[1].captureFrameStart, 10)
    }
}
