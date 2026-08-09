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

    func testSpokenDateDetectionInputTextIsIdenticalBeforeAndAfterPromotion() async throws {
        try writeFinalAudio()
        try writeLiveTranscript([("recorded on march third nineteen ninety eight", 0, 20_000)])

        let before = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil)
        let outcome = await revisionStore().promoteIfNeeded(captureID: captureID)
        guard case .promoted = outcome else { return XCTFail("fixture setup failed: \(outcome)") }
        let after = EntryTranscriptLoader.load(captureDirectory: captureDirectory, expectedRecords: nil)

        XCTAssertEqual(before.text, after.text,
                       "SpokenDateDetection reads transcript.text — promotion must not change it")
    }
}
