import XCTest
@testable import Raconte

/// T7 plan step 1: pure voice attribution over committed transcript results + snapped
/// structure markers (task-1-brief.md).
///
/// Fixture style follows `MarkerSnappingTests`: literal 48 kHz frame numbers, small
/// helper builders, snapped markers built by hand (`MarkerSnapping.SnappedMarker`
/// constructed directly) so these fixtures do not depend on the snapping rules —
/// this file tests attribution, not snapping.
final class TranscriptAttributionTests: XCTestCase {

    // MARK: - Fixtures

    /// A committed result over `range`. Each entry in `runs` is either a timed run's
    /// `(start, end, text)` or `nil` for a run the transcriber attributed no time range
    /// to. Mirrors `MarkerSnappingTests.result(_:runs:)`.
    private func result(_ text: String,
                        range: (Int64, Int64),
                        runs: [(Int64, Int64, String)?] = []) -> TranscriptResult {
        TranscriptResult(
            text: text,
            range: FrameRange(start: range.0, end: range.1),
            isVolatile: false,
            runs: runs.map { entry in
                guard let entry else { return TranscriptRun(text: "untimed") }
                return TranscriptRun(text: entry.2,
                                     captureFrameStart: entry.0,
                                     captureFrameEnd: entry.1)
            })
    }

    private func mark(_ frame: Int64,
                      seq: Int,
                      kind: StructureMarker.Kind,
                      voice: String? = nil) -> StructureMarker {
        StructureMarker(seq: seq, frame: frame, kind: kind, voice: voice)
    }

    private func snapped(_ marker: StructureMarker,
                         at snappedFrame: Int64,
                         approximate: Bool = false) -> MarkerSnapping.SnappedMarker {
        MarkerSnapping.SnappedMarker(marker: marker, snappedFrame: snappedFrame, approximate: approximate)
    }

    /// `TranscriptConsolidator.committedText`'s join rule, reproduced by hand so the
    /// no-marker regression can be checked without instantiating a consolidator.
    private func committedText(_ committed: [TranscriptResult]) -> String {
        committed.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Tests

    func testNoMarkersYieldsOneUnattributedParagraphEqualToCommittedText() {
        let committed = [
            // Deliberately multi-run: `record.text` ("onetwo") is NOT what naively
            // joining its run texts with " " would produce ("one two") — this is what
            // the whole-record-verbatim rule guards against and mutation (b) breaks.
            result("onetwo", range: (0, 20_000), runs: [
                (0, 10_000, "one"),
                (10_000, 20_000, "two"),
            ]),
            result("hello there", range: (20_000, 116_000)),
        ]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: [])

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertNil(paragraphs[0].voice)
        XCTAssertEqual(paragraphs[0].text, committedText(committed))
        XCTAssertEqual(paragraphs[0].text, "onetwo hello there")
        XCTAssertFalse(paragraphs[0].hasApproximateBoundary)
    }

    func testParagraphMarkerOnlySplitsWithoutAnyVoiceLabel() {
        let committed = [
            result("first part", range: (0, 96_000)),
            result("second part", range: (96_000, 192_000)),
        ]
        let markers = [snapped(mark(96_000, seq: 0, kind: .paragraph), at: 96_000)]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.map(\.text), ["first part", "second part"])
        XCTAssertEqual(paragraphs.map(\.voice), [nil, nil])
    }

    func testVoiceSwitchStartsANewParagraph() {
        let committed = [
            result("bn opener", range: (0, 96_000)),
            result("ln reply", range: (96_000, 192_000)),
        ]
        let markers = [
            snapped(mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 0),
            snapped(mark(96_000, seq: 1, kind: .voice, voice: StructureMarker.Voice.littleNico), at: 96_000),
        ]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map(\.voice), ["bn", "ln"])
        XCTAssertEqual(paragraphs.map(\.text), ["bn opener", "ln reply"])
    }

    func testOpeningVoiceMarkerAtFrameZeroDoesNotEmitAnEmptyParagraph() {
        let committed = [result("only text", range: (0, 96_000))]
        let markers = [snapped(mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 0)]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].voice, "bn")
        XCTAssertEqual(paragraphs[0].text, "only text")
    }

    func testRepeatedVoiceMarkerForTheSameVoiceDoesNotBreak() {
        let committed = [
            result("part one", range: (0, 96_000)),
            result("part two", range: (96_000, 192_000)),
        ]
        let markers = [
            snapped(mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 0),
            snapped(mark(96_000, seq: 1, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 96_000),
        ]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].voice, "bn")
        XCTAssertEqual(paragraphs[0].text, "part one part two")
    }

    func testMarkerInsideARecordSplitsBetweenWordRuns() {
        // Four timed runs over one record; marker snaps to the gap between run 2 and
        // run 3 (exactly on a piece boundary — start of run 3), not inside any piece.
        let committed = [
            result("one two three four", range: (0, 40_000), runs: [
                (0, 10_000, "one"),
                (10_000, 20_000, "two"),
                (20_000, 30_000, "three"),
                (30_000, 40_000, "four"),
            ]),
        ]
        let markers = [snapped(mark(20_000, seq: 0, kind: .paragraph), at: 20_000)]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0].text, "onetwo")
        XCTAssertEqual(paragraphs[1].text, "threefour")
        XCTAssertEqual(paragraphs[0].text + paragraphs[1].text, "onetwothreefour")
        XCTAssertFalse(paragraphs[0].hasApproximateBoundary)
        XCTAssertFalse(paragraphs[1].hasApproximateBoundary)
    }

    func testMarkerInsideASingleRunCutsAtTheNearerEdge() {
        // One long run, 0..<100_000. A marker at 20_000 is nearer the start (cut
        // before -> whole run goes to the second paragraph); a marker at 90_000 is
        // nearer the end (cut after -> whole run goes to the first paragraph).
        let nearStart = [
            result("word", range: (0, 100_000), runs: [(0, 100_000, "word")]),
        ]
        let nearStartMarkers = [snapped(mark(20_000, seq: 0, kind: .paragraph), at: 20_000)]
        let nearStartParagraphs = TranscriptAttribution.attribute(committed: nearStart, snapped: nearStartMarkers)
        XCTAssertEqual(nearStartParagraphs.map(\.text), ["word"])
        XCTAssertTrue(nearStartParagraphs[0].hasApproximateBoundary)

        let nearEnd = [
            result("word", range: (0, 100_000), runs: [(0, 100_000, "word")]),
            result("next", range: (100_000, 200_000), runs: [(100_000, 200_000, "next")]),
        ]
        let nearEndMarkers = [snapped(mark(90_000, seq: 0, kind: .paragraph), at: 90_000)]
        let nearEndParagraphs = TranscriptAttribution.attribute(committed: nearEnd, snapped: nearEndMarkers)
        XCTAssertEqual(nearEndParagraphs.map(\.text), ["word", "next"])
        XCTAssertTrue(nearEndParagraphs[0].hasApproximateBoundary)
    }

    func testRecordWithAnyUntimedRunIsNeverSplitInternally() {
        let committed = [
            result("one two", range: (0, 40_000), runs: [(0, 10_000, "one"), nil]),
        ]
        // A marker landing mid-record must not tear it: the untimed run forces the
        // whole record to be one piece (matches MarkerSnapping.intervals).
        let markers = [snapped(mark(20_000, seq: 0, kind: .paragraph), at: 20_000)]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text, "one two")
    }

    func testApproximateMarkerStillSplitsAndAttributes() {
        let committed = [
            result("word", range: (0, 100_000), runs: [(0, 100_000, "word")]),
            result("next", range: (100_000, 200_000), runs: [(100_000, 200_000, "next")]),
        ]
        // Marker snapped deep inside the first run (approximate = true from snapping's
        // own rule 4), cutting nearer the end -> whole first run stays in paragraph 1.
        let markers = [snapped(mark(50_000, seq: 0, kind: .paragraph), at: 90_000, approximate: true)]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.map(\.text), ["word", "next"])
        XCTAssertTrue(paragraphs[0].hasApproximateBoundary)
    }

    func testUnknownKindMarkersAreIgnoredForRendering() {
        let committed = [result("hello world", range: (0, 96_000))]
        let markers = [snapped(mark(48_000, seq: 0, kind: .unknown("chapter")), at: 48_000)]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text, "hello world")
        XCTAssertNil(paragraphs[0].voice)
    }

    func testMarkersAtIdenticalSnappedFramesProduceNoEmptyParagraphs() {
        let committed = [
            result("first", range: (0, 96_000)),
            result("second", range: (96_000, 192_000)),
        ]
        // A voice marker and a paragraph marker landing at the exact same snapped
        // frame must collapse into a single break, not two (one of them empty).
        let markers = [
            snapped(mark(96_000, seq: 0, kind: .voice, voice: StructureMarker.Voice.littleNico), at: 96_000),
            snapped(mark(96_000, seq: 1, kind: .paragraph), at: 96_000),
        ]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map(\.text), ["first", "second"])
        XCTAssertEqual(paragraphs.map(\.voice), [nil, "ln"])
    }

    func testMarkersOrderByFrameThenSeq() {
        let committed = [
            result("first", range: (0, 96_000)),
            result("second", range: (96_000, 192_000)),
            result("third", range: (192_000, 288_000)),
        ]
        // Handed in reversed / scrambled order; seq must still win at equal frames and
        // frame order must still govern overall, regardless of array order.
        let markers = [
            snapped(mark(192_000, seq: 5, kind: .voice, voice: StructureMarker.Voice.littleNico), at: 192_000),
            snapped(mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 0),
            snapped(mark(96_000, seq: 1, kind: .paragraph), at: 96_000),
        ]

        let paragraphs = TranscriptAttribution.attribute(committed: committed, snapped: markers)

        XCTAssertEqual(paragraphs.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(paragraphs.map(\.voice), ["bn", "bn", "ln"])
    }

    func testMarkersWithNoCommittedTranscriptYieldNoParagraphs() {
        let markers = [
            snapped(mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 0),
            snapped(mark(48_000, seq: 1, kind: .paragraph), at: 48_000),
        ]

        let paragraphs = TranscriptAttribution.attribute(committed: [], snapped: markers)

        XCTAssertEqual(paragraphs, [])
    }

    func testDisplayNameUppercasesTheOpaqueVoiceID() {
        XCTAssertEqual(TranscriptAttribution.displayName(forVoice: "bn"), "BN")
        XCTAssertEqual(TranscriptAttribution.displayName(forVoice: "ln"), "LN")
        XCTAssertEqual(TranscriptAttribution.displayName(forVoice: "x-third"), "X-THIRD")
    }

    /// For fixtures whose breaks land exactly on record boundaries (never mid-record),
    /// every paragraph is composed of whole records — so rejoining paragraph texts with
    /// a single space reproduces `committedText` exactly, regardless of how many voice
    /// or paragraph markers cut between those records. The mid-record split case has
    /// its own dedicated test (`testMarkerInsideARecordSplitsBetweenWordRuns`) because
    /// its join rule ("") differs from the between-record rule (" ") checked here.
    func testParagraphTextsRejoinToCommittedTextInEveryFixture() {
        struct Fixture {
            var committed: [TranscriptResult]
            var markers: [MarkerSnapping.SnappedMarker]
        }

        let fixtures: [Fixture] = [
            Fixture(committed: [
                result("hello there", range: (0, 96_000)),
                result("general kenobi", range: (96_000, 192_000)),
            ], markers: []),
            Fixture(committed: [
                result("first part", range: (0, 96_000)),
                result("second part", range: (96_000, 192_000)),
            ], markers: [snapped(mark(96_000, seq: 0, kind: .paragraph), at: 96_000)]),
            Fixture(committed: [
                result("first", range: (0, 96_000)),
                result("second", range: (96_000, 192_000)),
                result("third", range: (192_000, 288_000)),
            ], markers: [
                snapped(mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 0),
                snapped(mark(96_000, seq: 1, kind: .voice, voice: StructureMarker.Voice.littleNico), at: 96_000),
                snapped(mark(192_000, seq: 2, kind: .paragraph), at: 192_000),
            ]),
        ]

        for fixture in fixtures {
            let paragraphs = TranscriptAttribution.attribute(committed: fixture.committed, snapped: fixture.markers)
            let rejoined = paragraphs.map(\.text).joined(separator: " ")
            XCTAssertEqual(rejoined, committedText(fixture.committed))
        }
    }
}
