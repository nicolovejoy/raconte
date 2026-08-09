import XCTest
@testable import Raconte

/// T6a: pure format types for the on-disk revision chain (design §4.2). No writer, no
/// callers — this pins the wire shape and the decode leniency rules (F10) before
/// anything else is built on top of them.
final class TranscriptRevisionCodingTests: XCTestCase {

    // MARK: - Fixtures

    private func fullSpan() -> TranscriptSpan {
        TranscriptSpan(text: "hello world", anchor: .exact,
                       frameStart: 100, frameEnd: 200,
                       confidence: 0.9, sourceRevisionID: "rev-other")
    }

    private func fullRevision() -> TranscriptRevision {
        TranscriptRevision(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                           source: .machineLive,
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                           spans: [fullSpan()],
                           parentID: "parent-rev",
                           basedOnMachineID: "machine-rev",
                           generator: "SpeechTranscriber",
                           locale: "en_US",
                           coverageFrames: 48_000,
                           skippedRanges: [FrameRange(start: 0, end: 100)],
                           deviceID: "device-1",
                           closedBy: .sessionEnd)
    }

    private func fullHeadSummary() -> TranscriptHeadSummary {
        TranscriptHeadSummary(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                              fileNumber: 3,
                              source: .userEdit,
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                              characterCount: 42,
                              firstLine: "hello",
                              isForked: false)
    }

    private func fullHead() -> TranscriptHead {
        TranscriptHead(current: fullHeadSummary(),
                       revisionFiles: [1, 2, 3],
                       unreadableFiles: [],
                       revisionCount: 3)
    }

    private func fullDraft() -> TranscriptDraft {
        TranscriptDraft(captureID: "cap-1",
                        parentID: "parent-rev",
                        basedOnMachineID: "machine-rev",
                        openedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        lastWriteAt: Date(timeIntervalSince1970: 1_700_000_100),
                        text: "in progress")
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try CaptureCoding.encoder().encode(value)
        return try CaptureCoding.decoder().decode(T.self, from: data)
    }

    // MARK: - 1.2 Round-trip

    func testTranscriptSpanRoundTrips() throws {
        XCTAssertEqual(try roundTrip(fullSpan()), fullSpan())
    }

    func testTranscriptRevisionRoundTrips() throws {
        XCTAssertEqual(try roundTrip(fullRevision()), fullRevision())
    }

    func testTranscriptHeadSummaryRoundTrips() throws {
        XCTAssertEqual(try roundTrip(fullHeadSummary()), fullHeadSummary())
    }

    func testTranscriptHeadRoundTrips() throws {
        XCTAssertEqual(try roundTrip(fullHead()), fullHead())
    }

    func testTranscriptDraftRoundTrips() throws {
        XCTAssertEqual(try roundTrip(fullDraft()), fullDraft())
    }

    // MARK: - 1.2 Strictness: missing identity keys throw

    func testSpanMissingTextThrows() {
        let json = "{\"anchor\":\"exact\"}".data(using: .utf8)!
        XCTAssertThrowsError(try CaptureCoding.decoder().decode(TranscriptSpan.self, from: json))
    }

    func testRevisionMissingIDThrows() {
        let json = """
        {"source":"machineLive","createdAt":"2023-11-14T22:13:20.000Z","spans":[]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CaptureCoding.decoder().decode(TranscriptRevision.self, from: json))
    }

    func testRevisionMissingCreatedAtThrows() {
        let json = """
        {"id":"r1","source":"machineLive","spans":[]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CaptureCoding.decoder().decode(TranscriptRevision.self, from: json))
    }

    func testRevisionMissingSourceKeyThrows() {
        let json = """
        {"id":"r1","createdAt":"2023-11-14T22:13:20.000Z","spans":[]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CaptureCoding.decoder().decode(TranscriptRevision.self, from: json))
    }

    func testRevisionMissingSpansKeyThrows() {
        let json = """
        {"id":"r1","source":"machineLive","createdAt":"2023-11-14T22:13:20.000Z"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CaptureCoding.decoder().decode(TranscriptRevision.self, from: json),
                             "spans key must be present even if the array is empty")
    }

    func testRevisionSpansPresentButEmptyDecodes() throws {
        let json = """
        {"id":"r1","source":"machineLive","createdAt":"2023-11-14T22:13:20.000Z","spans":[]}
        """.data(using: .utf8)!
        let revision = try CaptureCoding.decoder().decode(TranscriptRevision.self, from: json)
        XCTAssertEqual(revision.spans, [])
    }

    func testDraftMissingCaptureIDThrows() {
        let json = """
        {"openedAt":"2023-11-14T22:13:20.000Z","lastWriteAt":"2023-11-14T22:13:20.000Z","text":""}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CaptureCoding.decoder().decode(TranscriptDraft.self, from: json))
    }

    // MARK: - 1.2 Lenient keys absent → nils

    func testRevisionMissingEveryLenientKeyDecodesWithNils() throws {
        let json = """
        {"id":"r1","source":"machineLive","createdAt":"2023-11-14T22:13:20.000Z","spans":[]}
        """.data(using: .utf8)!
        let revision = try CaptureCoding.decoder().decode(TranscriptRevision.self, from: json)
        XCTAssertNil(revision.parentID)
        XCTAssertNil(revision.basedOnMachineID)
        XCTAssertNil(revision.generator)
        XCTAssertNil(revision.locale)
        XCTAssertNil(revision.coverageFrames)
        XCTAssertNil(revision.skippedRanges)
        XCTAssertNil(revision.deviceID)
        XCTAssertNil(revision.closedBy)
    }

    func testSpanMissingEveryLenientKeyDecodesWithNils() throws {
        let json = """
        {"text":"hi","anchor":"exact"}
        """.data(using: .utf8)!
        let span = try CaptureCoding.decoder().decode(TranscriptSpan.self, from: json)
        XCTAssertNil(span.frameStart)
        XCTAssertNil(span.frameEnd)
        XCTAssertNil(span.confidence)
        XCTAssertNil(span.sourceRevisionID)
    }

    func testDraftMissingEveryLenientKeyDecodesWithNils() throws {
        let json = """
        {"captureID":"cap-1","openedAt":"2023-11-14T22:13:20.000Z","lastWriteAt":"2023-11-14T22:13:20.000Z","text":""}
        """.data(using: .utf8)!
        let draft = try CaptureCoding.decoder().decode(TranscriptDraft.self, from: json)
        XCTAssertNil(draft.parentID)
        XCTAssertNil(draft.basedOnMachineID)
    }

    func testHeadMissingCurrentDecodesWithNil() throws {
        let json = """
        {"revisionFiles":[1],"unreadableFiles":[],"revisionCount":1}
        """.data(using: .utf8)!
        let head = try CaptureCoding.decoder().decode(TranscriptHead.self, from: json)
        XCTAssertNil(head.current)
    }

    // MARK: - 1.3 Unknown-enum rule (F10)

    func testUnrecognizedSourceDecodesToUnknownAndIsMachineLineage() throws {
        let json = """
        {"id":"r1","source":"futureCase","createdAt":"2023-11-14T22:13:20.000Z","spans":[]}
        """.data(using: .utf8)!
        let revision = try CaptureCoding.decoder().decode(TranscriptRevision.self, from: json)
        XCTAssertEqual(revision.source, .unknown("futureCase"))
        XCTAssertFalse(revision.source.isHumanLineage,
                        "unknown source counts as MACHINE lineage (design §2.1)")
    }

    func testKnownHumanSourcesAreHumanLineage() {
        XCTAssertTrue(RevisionSource.userEdit.isHumanLineage)
        XCTAssertTrue(RevisionSource.merge.isHumanLineage)
        XCTAssertTrue(RevisionSource.import.isHumanLineage)
    }

    func testKnownMachineSourcesAreNotHumanLineage() {
        XCTAssertFalse(RevisionSource.machineLive.isHumanLineage)
        XCTAssertFalse(RevisionSource.machineRetranscribe.isHumanLineage)
    }

    func testUnrecognizedAnchorDecodesToNone() throws {
        let json = """
        {"text":"hi","anchor":"wobbly"}
        """.data(using: .utf8)!
        let span = try CaptureCoding.decoder().decode(TranscriptSpan.self, from: json)
        XCTAssertEqual(span.anchor, .none)
    }

    func testMissingAnchorKeyDecodesToNone() throws {
        let json = """
        {"text":"hi"}
        """.data(using: .utf8)!
        let span = try CaptureCoding.decoder().decode(TranscriptSpan.self, from: json)
        XCTAssertEqual(span.anchor, .none)
    }

    func testUnrecognizedClosedByDecodesToUnknown() throws {
        let json = """
        {"id":"r1","source":"machineLive","createdAt":"2023-11-14T22:13:20.000Z","spans":[],"closedBy":"telepathy"}
        """.data(using: .utf8)!
        let revision = try CaptureCoding.decoder().decode(TranscriptRevision.self, from: json)
        XCTAssertEqual(revision.closedBy, .unknown)
    }

    func testUnknownSourceReencodesRawSpellingVerbatim() throws {
        let original = TranscriptRevision(id: "r1", source: .unknown("futureCase"),
                                          createdAt: Date(timeIntervalSince1970: 0),
                                          spans: [])
        let data = try CaptureCoding.encoder().encode(original)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"futureCase\""),
                      "an unknown source must re-encode its original spelling for a foreign revision to round-trip")

        let decoded = try CaptureCoding.decoder().decode(TranscriptRevision.self, from: data)
        XCTAssertEqual(decoded.source, .unknown("futureCase"))
    }

    // MARK: - 1.4 Key omission on nil

    func testSpanEncodingOmitsConfidenceKeyWhenNil() throws {
        let span = TranscriptSpan(text: "hi", anchor: .exact)
        let data = try CaptureCoding.encoder().encode(span)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("\"confidence\""))
    }

    func testSpanEncodingOmitsSourceRevisionIDKeyWhenNil() throws {
        let span = TranscriptSpan(text: "hi", anchor: .exact)
        let data = try CaptureCoding.encoder().encode(span)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("\"sourceRevisionID\""))
    }

    func testSpanEncodingOmitsFrameStartAndEndKeysWhenNil() throws {
        let span = TranscriptSpan(text: "hi", anchor: .none)
        let data = try CaptureCoding.encoder().encode(span)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("\"frameStart\""))
        XCTAssertFalse(json.contains("\"frameEnd\""))
    }

    func testSpanEncodingIncludesConfidenceKeyWhenPresent() throws {
        let span = TranscriptSpan(text: "hi", anchor: .exact, confidence: 0.5)
        let data = try CaptureCoding.encoder().encode(span)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"confidence\""))
    }

    // MARK: - 1.5 Mirror tripwires

    /// A tripwire, not a style check. `TranscriptRevision` gets hand-enumerated in its
    /// `init(from:)`/`encode(to:)`, so a field added to the struct is silently dropped
    /// by both unless this fires. If it fires: carry the new field through
    /// `init(from:)` and `encode(to:)` above, then bump the count.
    func testTranscriptRevisionFieldCountIsPinned() {
        let revision = fullRevision()
        XCTAssertEqual(Mirror(reflecting: revision).children.count, 12,
                       "TranscriptRevision gained or lost a field — see its init(from:)/encode(to:)")
    }

    /// Same tripwire for `TranscriptSpan`.
    func testTranscriptSpanFieldCountIsPinned() {
        let span = fullSpan()
        XCTAssertEqual(Mirror(reflecting: span).children.count, 6,
                       "TranscriptSpan gained or lost a field — see its init(from:)/encode(to:)")
    }
}
