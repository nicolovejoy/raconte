import XCTest
@testable import Raconte

/// T7 Task 6 — marker correction + #37 typed-word correction.
///
/// Locked decision 5: raw taps are immutable. Corrections are additive records
/// APPENDED to `markers.jsonl` — never an edit of an existing record, never a sibling
/// overlay file. `MarkerCorrections.effectiveMarkers` is the pure READ-time fold that
/// resolves those additive records into the effective `.voice`/`.paragraph` list
/// `MarkerSnapping`/`TranscriptAttribution` already know how to render — production
/// code never rewrites a raw tap.
final class MarkerCorrectionsTests: XCTestCase {

    // MARK: - 6.1: correction-kind decode/encode round trip

    func testCorrectionRetractRoundTripsAndOmitsTheVoiceKey() throws {
        let marker = StructureMarker(seq: 3, frame: 0, kind: .correctionRetract, retractsSeq: 1)
        let data = try CaptureCoding.lineEncoder().encode(marker)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"retractsSeq\":1"))
        XCTAssertFalse(text.contains("\"voice\""),
                       "a retract carries no voice key — design §4's per-kind economy")

        let decoded = try CaptureCoding.decoder().decode(StructureMarker.self, from: data)
        XCTAssertEqual(decoded.kind, .correctionRetract)
        XCTAssertEqual(decoded.retractsSeq, 1)
        XCTAssertNil(decoded.voice)
    }

    func testCorrectionVoiceRoundTripsAndOmitsTheRetractsSeqKey() throws {
        let marker = StructureMarker(seq: 4, frame: 96_000, kind: .correctionVoice,
                                     voice: StructureMarker.Voice.littleNico)
        let data = try CaptureCoding.lineEncoder().encode(marker)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"voice\":\"ln\""))
        XCTAssertFalse(text.contains("\"retractsSeq\""),
                       "a voice correction carries no retractsSeq key")

        let decoded = try CaptureCoding.decoder().decode(StructureMarker.self, from: data)
        XCTAssertEqual(decoded.kind, .correctionVoice)
        XCTAssertEqual(decoded.voice, "ln")
        XCTAssertNil(decoded.retractsSeq)
    }

    func testCorrectionBoundaryAddRoundTripsWithNeitherVoiceNorRetractsSeqKey() throws {
        let marker = StructureMarker(seq: 5, frame: 48_000, kind: .correctionBoundaryAdd)
        let data = try CaptureCoding.lineEncoder().encode(marker)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("\"voice\""))
        XCTAssertFalse(text.contains("\"retractsSeq\""))
        XCTAssertTrue(text.contains("\"kind\":\"correctionBoundaryAdd\""))

        let decoded = try CaptureCoding.decoder().decode(StructureMarker.self, from: data)
        XCTAssertEqual(decoded.kind, .correctionBoundaryAdd)
        XCTAssertEqual(decoded.frame, 48_000)
        XCTAssertNil(decoded.voice)
        XCTAssertNil(decoded.retractsSeq)
    }

    /// "An older-build reader (unknown kind) ignores it and renders the uncorrected
    /// result — assert both directions" (brief 6.1). `"correctionFutureKind"` stands in
    /// for a correction kind THIS build does not know about yet (a real future addition
    /// beyond today's three) — decoded as `.unknown`, exactly like any other kind this
    /// build has never seen.
    ///
    /// Direction 1 (disk): the record survives a read-rewrite cycle verbatim — the
    /// general `.unknown` preservation mechanism (`MarkerLogTests
    /// .testUnknownKindRoundTripsIntact`), re-asserted here for a correction-shaped
    /// kind specifically since it also carries a `retractsSeq`-shaped field this build
    /// cannot interpret.
    func testUnknownFutureCorrectionKindPreservedOnDiskVerbatim() throws {
        let line = #"{"frame":10,"kind":"correctionFutureKind","seq":2,"retractsSeq":1}"#
        let decoded = try CaptureCoding.decoder().decode(StructureMarker.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.kind, .unknown("correctionFutureKind"))
        XCTAssertEqual(decoded.retractsSeq, 1, "the additive field survives even though the kind is unknown")

        let reencoded = try CaptureCoding.lineEncoder().encode(decoded)
        let text = try XCTUnwrap(String(data: reencoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"kind\":\"correctionFutureKind\""),
                      "the unknown correction kind is preserved verbatim, not dropped or coerced")
        XCTAssertTrue(text.contains("\"retractsSeq\":1"))
    }

    /// Direction 2 (rendering): fed through the fold, an unknown-to-this-build
    /// correction record has NO effect — the output is byte-identical to the same raw
    /// list with that record removed. This is what "shows the uncorrected version"
    /// means operationally: `MarkerCorrections.effectiveMarkers` only ever turns
    /// .voice/.paragraph markers into itself, plus records it understands into
    /// resolved .voice/.paragraph effects. An `.unknown` kind is neither.
    func testUnknownFutureCorrectionKindIgnoredByTheFold() {
        let uncorrected: [StructureMarker] = [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn"),
            StructureMarker(seq: 1, frame: 96_000, kind: .paragraph),
        ]
        let withUnknownCorrection = uncorrected + [
            StructureMarker(seq: 2, frame: 0, kind: .unknown("correctionFutureKind"), retractsSeq: 1),
        ]

        XCTAssertEqual(MarkerCorrections.effectiveMarkers(withUnknownCorrection).map(\.marker), uncorrected,
                       "an unknown correction kind must render exactly as if it were absent")
        XCTAssertTrue(MarkerCorrections.effectiveMarkers(withUnknownCorrection).allSatisfy { !$0.isExact },
                      "raw taps are never exact — only a boundary-add's synthesized marker is")
    }

    // MARK: - Review Important 3: a retract must be able to cancel a boundary-add

    /// `.correctionBoundaryAdd` synthesizes a marker whose `seq` is the CORRECTION
    /// record's own (not a fresh one) — exactly so a LATER `.correctionRetract`
    /// targeting that same seq can cancel it, the same as retracting any raw tap.
    /// File order (append order) is not resolution order (this type's own doc
    /// comment) — a retract appended after an addition, or even a retract that
    /// happens to precede it in a pathological reordering, must still cancel it.
    func testRetractCancelsABoundaryAddRegardlessOfAppendOrder() {
        let addThenRetract: [StructureMarker] = [
            StructureMarker(seq: 0, frame: 20_000, kind: .correctionBoundaryAdd),
            StructureMarker(seq: 1, frame: 0, kind: .correctionRetract, retractsSeq: 0),
        ]
        XCTAssertTrue(MarkerCorrections.effectiveMarkers(addThenRetract).isEmpty,
                      "a retract targeting a boundary-add's own seq must cancel it")

        let retractThenAdd: [StructureMarker] = [
            StructureMarker(seq: 0, frame: 0, kind: .correctionRetract, retractsSeq: 1),
            StructureMarker(seq: 1, frame: 20_000, kind: .correctionBoundaryAdd),
        ]
        XCTAssertTrue(MarkerCorrections.effectiveMarkers(retractThenAdd).isEmpty,
                      "resolution is order-independent — gathering every correction before applying any")
    }

    // MARK: - Review Critical 1: a boundary-add's frame must never be snapped again

    /// The frame `MarkerCorrectionWriter.addBoundary` writes is a SPAN's own bound —
    /// exact by construction, never a raw tap subject to latency. `MarkerSnapping`
    /// exists to correct raw TAP latency (design §6) and must never touch this frame
    /// a second time. Only a synthesized boundary-add marker is `isExact`; a raw tap
    /// (including one whose VOICE was corrected — the frame is still the original raw
    /// tap's own) is not, and must still be snapped exactly as before Task 6.
    func testOnlyABoundaryAddsSynthesizedMarkerIsExact() {
        let raw: [StructureMarker] = [
            StructureMarker(seq: 0, frame: 0, kind: .voice, voice: "bn"),
            StructureMarker(seq: 1, frame: 96_000, kind: .paragraph),
            StructureMarker(seq: 2, frame: 20_000, kind: .correctionBoundaryAdd),
            StructureMarker(seq: 3, frame: 0, kind: .correctionVoice, voice: "ln"),
        ]
        let effective = MarkerCorrections.effectiveMarkers(raw)

        let byFrame = Dictionary(uniqueKeysWithValues: effective.map { ($0.marker.frame, $0.isExact) })
        XCTAssertEqual(byFrame[0], false, "the voice-corrected tap's FRAME is still the raw tap's own")
        XCTAssertEqual(byFrame[96_000], false, "an untouched raw .paragraph tap")
        XCTAssertEqual(byFrame[20_000], true, "the boundary-add's own synthesized marker")
    }

    // MARK: - Task 1 (#56): voice-carrying boundary adds — the fold

    /// A `.correctionBoundaryAdd` that carries a voice synthesizes a `.voice` marker
    /// (task-1-brief.md), not the plain `.paragraph` every boundary-add produced before
    /// this task — the whole point of teaching the record to carry a voice at all.
    func testVoiceCarryingBoundaryAddSynthesizesAVoiceMarker() throws {
        let raw: [StructureMarker] = [
            StructureMarker(seq: 2, frame: 20_000, kind: .correctionBoundaryAdd, voice: "ln"),
        ]

        let effective = MarkerCorrections.effectiveMarkers(raw)

        XCTAssertEqual(effective.count, 1)
        let marker = try XCTUnwrap(effective.first)
        XCTAssertEqual(marker.marker.kind, .voice, "a voice-carrying add must synthesize .voice, not .paragraph")
        XCTAssertEqual(marker.marker.voice, "ln")
        XCTAssertEqual(marker.marker.seq, 2, "the correction record's own seq, same as any boundary-add")
        XCTAssertTrue(marker.isExact, "still a synthesized, word-anchored frame — never re-snapped")
    }

    /// The compat pin: a nil-voice boundary-add folds exactly as before this task —
    /// `.paragraph`, no voice. Task 6's existing behavior must survive untouched.
    func testVoicelessBoundaryAddStillSynthesizesAParagraphMarker() throws {
        let raw: [StructureMarker] = [
            StructureMarker(seq: 2, frame: 20_000, kind: .correctionBoundaryAdd),
        ]

        let effective = MarkerCorrections.effectiveMarkers(raw)

        XCTAssertEqual(effective.count, 1)
        let marker = try XCTUnwrap(effective.first)
        XCTAssertEqual(marker.marker.kind, .paragraph)
        XCTAssertNil(marker.marker.voice)
        XCTAssertTrue(marker.isExact)
    }

    /// Mirror of `testRetractCancelsABoundaryAddRegardlessOfAppendOrder` (`:113`) with a
    /// voice on the add — a retract must cancel a voice-carrying boundary-add exactly
    /// as it cancels a plain one, regardless of append order.
    func testRetractCancelsAVoiceCarryingAddRegardlessOfAppendOrder() {
        let addThenRetract: [StructureMarker] = [
            StructureMarker(seq: 0, frame: 20_000, kind: .correctionBoundaryAdd, voice: "ln"),
            StructureMarker(seq: 1, frame: 0, kind: .correctionRetract, retractsSeq: 0),
        ]
        XCTAssertTrue(MarkerCorrections.effectiveMarkers(addThenRetract).isEmpty,
                      "a retract targeting a voice-carrying boundary-add's own seq must cancel it")

        let retractThenAdd: [StructureMarker] = [
            StructureMarker(seq: 0, frame: 0, kind: .correctionRetract, retractsSeq: 1),
            StructureMarker(seq: 1, frame: 20_000, kind: .correctionBoundaryAdd, voice: "ln"),
        ]
        XCTAssertTrue(MarkerCorrections.effectiveMarkers(retractThenAdd).isEmpty,
                      "resolution is order-independent regardless of the add carrying a voice")
    }

    // MARK: - 6.4b: boundary ADD by picked word — MarkerCorrectionWriter

    private var capturesRoot: URL!
    private var captureDir: URL!

    override func setUpWithError() throws {
        capturesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteMarkerCorrections-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        captureDir = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: "cap")
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: capturesRoot.deletingLastPathComponent())
    }

    private func span(_ text: String, _ anchor: SpanAnchor, _ start: Int64? = nil, _ end: Int64? = nil) -> TranscriptSpan {
        TranscriptSpan(text: text, anchor: anchor, frameStart: start, frameEnd: end)
    }

    /// The writer anchors to the PICKED SPAN's own start frame — never the group/
    /// paragraph's start frame (brief case 3: "the record is anchored to that word's
    /// frame, not to a time he scrubs to"). Picking a word mid-way through several
    /// spans (index 1, not index 0) is the discriminating fixture: anchoring to the
    /// group's start (span 0's frame, 0) instead of the picked word's own (span 1's
    /// frame, 20_000) would still produce SOME correction record, just at the wrong
    /// frame — only a fixture with more than one span in scope can catch that.
    func testAddBoundaryAnchorsToThePickedSpansOwnStartFrameNotTheGroupStart() throws {
        let spans = [
            span("one", .inherited, 0, 10_000),
            span("two", .inherited, 20_000, 30_000),
            span("three", .inherited, 40_000, 50_000),
        ]

        let written = try MarkerCorrectionWriter.addBoundary(atSpanIndex: 1, spans: spans,
                                                              captureDirectory: captureDir)

        XCTAssertEqual(written, 20_000, "must be span 1's own start, not span 0's (the group's start)")

        let onDisk = MarkerLogReader.load(captureDirectory: captureDir).markers
        XCTAssertEqual(onDisk.count, 1)
        XCTAssertEqual(onDisk[0].kind, .correctionBoundaryAdd)
        XCTAssertEqual(onDisk[0].frame, 20_000)
    }

    /// A word whose span has no usable bounds (`.none`/`.unknown` anchor, or a
    /// zero-length `.inherited` span — Task 5's exact placeability rule, shared via
    /// `TranscriptAttribution.isPlaceableSpan` rather than re-derived) is rejected with
    /// a stated reason and writes NOTHING — not a boundary silently placed nearby.
    func testAddBoundaryRejectsAWordWithNoUsableBoundsAndWritesNothing() throws {
        let spans = [
            span("typed", .none, nil, nil),
            span("point", .inherited, 10_000, 10_000),   // zero-length: an insertion point
        ]

        for index in [0, 1] {
            XCTAssertThrowsError(try MarkerCorrectionWriter.addBoundary(
                atSpanIndex: index, spans: spans, captureDirectory: captureDir)) { error in
                guard case MarkerCorrectionWriter.BoundaryAddError.noUsableBounds = error else {
                    return XCTFail("expected .noUsableBounds for span \(index), got \(error)")
                }
            }
        }

        XCTAssertEqual(MarkerLogReader.load(captureDirectory: captureDir).source, .absent,
                       "a rejected boundary-add must leave markers.jsonl untouched — nothing offerable, nothing written")
    }

    func testAddBoundaryRejectsAnOutOfRangeIndex() {
        XCTAssertThrowsError(try MarkerCorrectionWriter.addBoundary(
            atSpanIndex: 5, spans: [span("only", .exact, 0, 100)], captureDirectory: captureDir))
    }
}
