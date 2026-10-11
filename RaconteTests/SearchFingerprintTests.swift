import XCTest
@testable import Raconte

/// Capture-directory fixtures for the search tests, built with the same production
/// writers the existing loader tests use (`LiveTranscriptWriter`, `CaptureCoding`). The
/// existing helpers are `private` to their own test classes, so they cannot be reached.
enum SearchCaptureFixture {
    static func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteSearchFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `canonical-<n>.json`; later `n` gets a later `createdAt`, so it is current.
    @discardableResult
    static func writeCanonical(_ dir: URL, n: Int, spans: [String]) throws -> URL {
        let transcript = SegmentLayout.transcriptDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        let revision = TranscriptRevision(
            id: ULID.make(), source: .machineLive,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
            spans: spans.map { TranscriptSpan(text: $0, anchor: .none) })
        let url = SegmentLayout.canonicalTranscriptURL(captureDirectory: dir, revision: n)
        try CaptureCoding.encoder().encode(revision).write(to: url)
        return url
    }

    static func writeLiveLog(_ dir: URL, records: [String]) throws {
        let writer = LiveTranscriptWriter(captureDirectory: dir)
        try writer.open()
        var frame: Int64 = 0
        for text in records {
            try writer.append(TranscriptRecord(seq: 0, text: text,
                                               captureFrameStart: frame, captureFrameEnd: frame + 100,
                                               generator: "SpeechTranscriber", locale: "en_US"))
            frame += 100
        }
        try writer.close()
    }
}

final class SearchFingerprintTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try SearchCaptureFixture.makeDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testCanonicalHeadDrivesTheFingerprint() throws {
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: ["alpha"])
        let a = SearchFingerprint.compute(directory: dir)
        try SearchCaptureFixture.writeCanonical(dir, n: 2, spans: ["alpha beta"])
        let b = SearchFingerprint.compute(directory: dir)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b)
    }

    func testLiveLogDrivesItWhenThereIsNoCanonical() throws {
        try SearchCaptureFixture.writeLiveLog(dir, records: ["one"])
        let a = SearchFingerprint.compute(directory: dir)
        try SearchCaptureFixture.writeLiveLog(dir, records: ["one", "two"])
        let b = SearchFingerprint.compute(directory: dir)
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
    }

    func testUnrelatedFileDoesNotMoveIt() throws {
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: ["alpha"])
        let a = SearchFingerprint.compute(directory: dir)
        try Data("x".utf8).write(to: dir.appendingPathComponent("note.txt"))
        XCTAssertNotNil(a)
        XCTAssertEqual(a, SearchFingerprint.compute(directory: dir))
    }

    func testEmptyDirectoryIsNil() {
        XCTAssertNil(SearchFingerprint.compute(directory: dir))
    }

    func testComputingWritesNothingUnderTheCaptureDirectory() throws {
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: ["alpha"])
        let before = try listing(dir)
        _ = SearchFingerprint.compute(directory: dir)
        XCTAssertEqual(try listing(dir), before)
    }

    private func listing(_ root: URL) throws -> [String] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).map(\.path).sorted()
    }
}
