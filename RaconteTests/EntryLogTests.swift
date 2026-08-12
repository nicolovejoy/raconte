import XCTest
@testable import Raconte

/// T7 §7: `entry-log.jsonl`, the per-entry metadata audit log. Written and exported,
/// never shown (owner ruling, Q10) — no view in this app reads it.
final class EntryLogTests: XCTestCase {

    private var capturesRoot: URL!
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        capturesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteEntryLog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: capturesRoot.deletingLastPathComponent())
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private var logURL: URL {
        SegmentLayout.entryLogURL(captureDirectory: captureDirectory)
    }

    // MARK: 7.1 — round trip + lenient/strict decode

    /// §7.1's shape, verbatim: `at`, `field`, `from`, `to`, `cause`, `origin`. One line,
    /// no embedded newline (JSONL requirement — `LiveTranscriptWriter`'s own assertion,
    /// copied here since a `.prettyPrinted` encoder would tear this format the same way).
    func testRecordRoundTripsThroughLineEncoding() throws {
        let record = EntryLogRecord(at: Date(timeIntervalSince1970: 1_700_000_000.5),
                                     field: "originalDate", from: "1998", to: "1998-03",
                                     cause: .userEdit, origin: "detected")
        let data = try CaptureCoding.lineEncoder().encode(record)
        XCTAssertFalse(data.contains(UInt8(ascii: "\n")),
                       "a JSONL record must not itself contain a raw newline")
        let decoded = try CaptureCoding.decoder().decode(EntryLogRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    /// The whole pipe end to end: append through the writer, read back through the reader.
    func testEveryFieldSurvivesAppendAndRead() throws {
        let record = EntryLogRecord(at: Date(timeIntervalSince1970: 1_700_000_000),
                                     field: "trashedAt", from: nil, to: "2026-08-11T00:00:00.000Z",
                                     cause: .sweep, origin: nil)
        try EntryLogWriter.append(record, captureDirectory: captureDirectory)
        let loaded = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(loaded.records, [record])
    }

    /// `cause` is the one field a future build can invent a new case for. A build that
    /// doesn't recognize it must still read every OTHER field on the line rather than
    /// losing the whole record — `.unknown` is the fallback, never a throw.
    func testUnrecognizedCauseDecodesAsUnknownRatherThanThrowing() throws {
        let json = #"{"at":"2026-08-11T00:00:00.000Z","field":"journalID","to":"J9","cause":"aFutureBuildInventedThis"}"#
        let decoded = try CaptureCoding.decoder().decode(EntryLogRecord.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.cause, .unknown)
        XCTAssertEqual(decoded.field, "journalID")
        XCTAssertEqual(decoded.to, "J9")
    }

    // MARK: 7.3 — torn-tail fuse

    /// Plants a file whose last line lacks a trailing `\n` — the shape a kill mid-write
    /// leaves behind — then appends. **Mutation check (documented in the task report):**
    /// removing the fuse makes the new record land directly on the torn tail, fusing two
    /// JSON objects onto one line; that line fails to decode and BOTH records are lost.
    func testTornTailIsFusedSoBothRecordsSurvive() throws {
        let first = EntryLogRecord(at: Date(timeIntervalSince1970: 1), field: "journalID",
                                    from: nil, to: "J1", cause: .userEdit, origin: nil)
        let firstLine = try CaptureCoding.lineEncoder().encode(first)
        try firstLine.write(to: logURL)  // no trailing newline — the torn shape
        XCTAssertNotEqual(firstLine.last, UInt8(ascii: "\n"), "fixture must actually be torn")

        let second = EntryLogRecord(at: Date(timeIntervalSince1970: 2), field: "journalID",
                                     from: "J1", to: "J2", cause: .userEdit, origin: nil)
        try EntryLogWriter.append(second, captureDirectory: captureDirectory)

        let loaded = EntryLogReader.load(captureDirectory: captureDirectory)
        XCTAssertEqual(loaded.records, [first, second],
                       "a torn tail must be fused with a bare newline, not fused onto the new record")
    }
}
