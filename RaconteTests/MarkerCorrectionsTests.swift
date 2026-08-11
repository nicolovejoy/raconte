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

        XCTAssertEqual(MarkerCorrections.effectiveMarkers(withUnknownCorrection), uncorrected,
                       "an unknown correction kind must render exactly as if it were absent")
    }
}
