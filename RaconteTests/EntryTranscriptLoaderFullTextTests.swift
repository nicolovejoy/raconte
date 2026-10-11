import XCTest
@testable import Raconte

final class EntryTranscriptLoaderFullTextTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try SearchCaptureFixture.makeDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testCanonicalSpansAreJoined() throws {
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: ["the new", "strings arrived"])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir, expectedRecords: nil),
                       "the new strings arrived")
    }

    func testFallsBackToConsolidatedCommittedText() throws {
        try SearchCaptureFixture.writeLiveLog(dir, records: ["one", "two"])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir, expectedRecords: 2), "one two")
    }

    func testNothingIsNil() {
        XCTAssertNil(EntryTranscriptLoader.fullText(captureDirectory: dir, expectedRecords: nil))
    }

    func testCanonicalWinsOverALiveLogWhenBothExist() throws {
        try SearchCaptureFixture.writeLiveLog(dir, records: ["live one", "live two"])
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: ["edited", "text"])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir, expectedRecords: 2),
                       "edited text")
    }

    /// The contract: exactly the text the detail screen shows (`load(.compute)`'s `text`).
    func testMatchesTheDetailScreensTextForCanonicalAndLiveLog() throws {
        let sampleRate = 48_000.0
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: ["first span", "second span", "third"])
        let canonical = EntryTranscriptLoader.load(captureDirectory: dir, expectedRecords: nil,
                                                   attribution: .compute(sampleRate: sampleRate))
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir, expectedRecords: nil),
                       canonical.text)
        XCTAssertEqual(canonical.text, "first span second span third")

        let liveOnly = try SearchCaptureFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: liveOnly) }
        try SearchCaptureFixture.writeLiveLog(liveOnly, records: ["alpha", "beta", "gamma"])
        let live = EntryTranscriptLoader.load(captureDirectory: liveOnly, expectedRecords: 3,
                                              attribution: .compute(sampleRate: sampleRate))
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: liveOnly, expectedRecords: 3),
                       live.text)
        XCTAssertEqual(live.text, "alpha beta gamma")
    }

    func testFullTextIsNotTruncatedToASnippet() throws {
        let long = String(repeating: "word ", count: 200)
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: [long, "end"])
        let text = try XCTUnwrap(EntryTranscriptLoader.fullText(captureDirectory: dir, expectedRecords: nil))
        XCTAssertGreaterThan(text.count, 500)
        XCTAssertTrue(text.hasSuffix("end"))
    }
}
