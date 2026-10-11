import XCTest
@testable import Raconte

final class EntryTranscriptLoaderFullTextTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try SearchCaptureFixture.makeDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testCanonicalSpansAreJoined() throws {
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: ["the new", "strings arrived"])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir),
                       .text("the new strings arrived"))
    }

    func testFallsBackToConsolidatedCommittedText() throws {
        try SearchCaptureFixture.writeLiveLog(dir, records: ["one", "two"])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir), .text("one two"))
    }

    func testNothingIsEmpty() {
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir), .empty)
    }

    func testReadableButWordlessIsEmpty() throws {
        try SearchCaptureFixture.writeLiveLog(dir, records: [])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir), .empty)
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: [""])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir), .empty)
    }

    func testCanonicalWinsOverALiveLogWhenBothExist() throws {
        try SearchCaptureFixture.writeLiveLog(dir, records: ["live one", "live two"])
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: ["edited", "text"])
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir),
                       .text("edited text"))
    }

    /// The contract: exactly the text the detail screen shows (`load(.compute)`'s `text`).
    func testMatchesTheDetailScreensTextForCanonicalAndLiveLog() throws {
        let sampleRate = 48_000.0
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: ["first span", "second span", "third"])
        let canonical = EntryTranscriptLoader.load(captureDirectory: dir, expectedRecords: nil,
                                                   attribution: .compute(sampleRate: sampleRate))
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir),
                       canonical.text.map { .text($0) })
        XCTAssertEqual(canonical.text, "first span second span third")

        let liveOnly = try SearchCaptureFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: liveOnly) }
        try SearchCaptureFixture.writeLiveLog(liveOnly, records: ["alpha", "beta", "gamma"])
        let live = EntryTranscriptLoader.load(captureDirectory: liveOnly, expectedRecords: 3,
                                              attribution: .compute(sampleRate: sampleRate))
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: liveOnly),
                       live.text.map { .text($0) })
        XCTAssertEqual(live.text, "alpha beta gamma")
    }

    func testFullTextIsNotTruncatedToASnippet() throws {
        let long = String(repeating: "word ", count: 200)
        try SearchCaptureFixture.writeCanonical(dir, n: 1, spans: [long, "end"])
        guard case .text(let text) = EntryTranscriptLoader.fullText(captureDirectory: dir) else {
            return XCTFail("expected text")
        }
        XCTAssertGreaterThan(text.count, 500)
        XCTAssertTrue(text.hasSuffix("end"))
    }

    // MARK: Unreadable is not empty

    /// The log is there and reading it fails. That is not "no words": the caller must not
    /// treat it as text that has gone.
    func testAnUnreadableLiveLogIsUnreadableNotEmpty() throws {
        try SearchCaptureFixture.writeLiveLog(dir, records: ["one", "two"])
        try SearchCaptureFixture.sealLiveLog(dir)
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir), .unreadable)
    }

    func testAnUndecodableCanonicalWithNoLiveLogIsUnreadableNotEmpty() throws {
        try SearchCaptureFixture.writeUndecodableCanonical(dir, n: 1)
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir), .unreadable)
    }

    /// Same fallback as `load`: with no readable revision the live log is the text.
    func testAnUndecodableCanonicalFallsBackToAReadableLiveLog() throws {
        try SearchCaptureFixture.writeLiveLog(dir, records: ["one", "two"])
        try SearchCaptureFixture.writeUndecodableCanonical(dir, n: 1)
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir), .text("one two"))
    }

    /// A wordless log does not vouch for a revision that did not read.
    func testAnUndecodableCanonicalBesideAWordlessLiveLogIsUnreadable() throws {
        try SearchCaptureFixture.writeLiveLog(dir, records: [])
        try SearchCaptureFixture.writeUndecodableCanonical(dir, n: 1)
        XCTAssertEqual(EntryTranscriptLoader.fullText(captureDirectory: dir), .unreadable)
    }
}
