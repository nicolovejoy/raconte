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
        // T7 Task 9.3: `hasApproximateBoundary`'s own contract (see the span-path sibling
        // pair, `testMarkerStrictlyInsideAPlaceableSpanNearer{Start,End}IsApproximate`) is
        // that the imprecision belongs to the CUT, not to one side of it — the flag must
        // land on BOTH paragraphs adjacent to an interior cut. This piece-based path
        // (`cutIndex(forFrame:pieces:)`) had that contract implemented since Task 1 but
        // never asserted on the second side; only the span path (`placeableCutPosition`,
        // added in Task 5's fix round) had a two-sided pin. Symmetric here too.
        XCTAssertTrue(nearEndParagraphs[0].hasApproximateBoundary)
        XCTAssertTrue(nearEndParagraphs[1].hasApproximateBoundary,
                      "the cut's imprecision belongs to both paragraphs it separates, not just the first")
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
        // T7 Task 9.3: symmetric — this source of `approximate` is the marker's OWN
        // snap-imprecision flag (not a structural interior-cut), so pin it lands on
        // both sides too, distinct from the structural case above.
        XCTAssertTrue(paragraphs[1].hasApproximateBoundary)
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

    // MARK: - T7 Task 5: attribution over a revision's SPANS (survives an edit)

    /// Brief step 5.1: rev0 promoted (both spans `.exact`), then one word retyped —
    /// TranscriptSplice degrades a touched span to `.inherited`, carrying the PARENT
    /// span's full frame bounds forward (design §3.3), never `.exact` again. Attribution
    /// must still place the marker correctly and label both paragraphs, proving it reads
    /// spans generally rather than only ever-`.exact` machine output.
    func testEditedInheritedSpanKeepsVoiceAttributionAcrossTheEdit() {
        let spans = [
            TranscriptSpan(text: "bn opener", anchor: .exact, frameStart: 0, frameEnd: 96_000),
            // Stands in for "ln reply" retyped to "ln answer": the whole span touched,
            // degraded to `.inherited` but keeping the ORIGINAL span's frame bounds —
            // exactly TranscriptSplice's rule for a fully-replaced run.
            TranscriptSpan(text: "ln answer", anchor: .inherited, frameStart: 96_000, frameEnd: 192_000),
        ]
        let markers = [
            snapped(mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 0),
            snapped(mark(96_000, seq: 1, kind: .voice, voice: StructureMarker.Voice.littleNico), at: 96_000),
        ]

        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map(\.voice), ["bn", "ln"])
        XCTAssertEqual(paragraphs.map(\.text), ["bn opener", "ln answer"])
    }

    /// The same scenario driven through the REAL splice engine (not a hand-built
    /// `.inherited` fixture), so the pipeline `TranscriptSplice` → `TranscriptAttribution`
    /// is exercised end-to-end at the pure-function level. Assertions are deliberately
    /// robust to exactly how the character diff fragments the touched span (that is
    /// `TranscriptSplice`'s concern, pinned by its own tests) — this only checks the
    /// properties Task 5 owns: voice count/order, which words land on which side, and
    /// that the paragraphs still rejoin to the revision's own `plainText`.
    func testRealSplicedEditStillAttributesVoicesCorrectly() {
        let parent = TranscriptRevision(
            id: "R0", source: .machineLive, createdAt: Date(timeIntervalSince1970: 1_000),
            spans: [
                TranscriptSpan(text: "bn opener", anchor: .exact, frameStart: 0, frameEnd: 96_000),
                TranscriptSpan(text: "ln reply", anchor: .exact, frameStart: 96_000, frameEnd: 192_000),
            ])
        let editedText = "bn opener ln answer"   // "reply" retyped to "answer"
        let editedSpans = TranscriptSplice.spans(parent: parent, editedText: editedText)
        XCTAssertEqual(TranscriptText.join(editedSpans.map(\.text)), editedText,
                       "TranscriptSplice's own round-trip guarantee — sanity check on the fixture")

        let markers = [
            snapped(mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 0),
            snapped(mark(96_000, seq: 1, kind: .voice, voice: StructureMarker.Voice.littleNico), at: 96_000),
        ]

        let paragraphs = TranscriptAttribution.attribute(spans: editedSpans, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map(\.voice), ["bn", "ln"])
        XCTAssertTrue(paragraphs[0].text.contains("opener") && !paragraphs[0].text.contains("answer"))
        XCTAssertTrue(paragraphs[1].text.contains("answer") && !paragraphs[1].text.contains("reply"))
        XCTAssertEqual(paragraphs.map(\.text).joined(separator: " "), editedText,
                       "paragraphs rejoin to exactly the edited plain text")
    }

    /// Brief step 5.2: a `.none`-anchored span (typed from nothing — no frame bounds at
    /// all) sitting between two `.exact` spans must join the PRECEDING paragraph, never
    /// open one of its own. The wrong answer (a 3rd, "typed"-only paragraph, or "typed"
    /// silently dropped) is representable here, so this is non-degenerate.
    func testNoneAnchoredSpanJoinsThePrecedingParagraphAndNeverOpensANewOne() {
        let spans = [
            TranscriptSpan(text: "kept before", anchor: .exact, frameStart: 0, frameEnd: 50_000),
            TranscriptSpan(text: "typed", anchor: .none),
            TranscriptSpan(text: "kept after", anchor: .exact, frameStart: 50_000, frameEnd: 100_000),
        ]
        let markers = [snapped(mark(50_000, seq: 0, kind: .paragraph), at: 50_000)]

        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0].text, "kept before typed")
        XCTAssertEqual(paragraphs[1].text, "kept after")
    }

    /// A zero-length `.inherited` insertion point (TranscriptSplice's own rule for newly
    /// typed text with a preceding usable span to inherit from — frameStart == frameEnd)
    /// is UNPLACEABLE the same way `.none` is (brief's explicit "and zero-length
    /// `.inherited` insertion points" clause) — distinct from the `.none` case above,
    /// since `anchor.hasUsableBounds` alone would say yes here.
    func testZeroLengthInheritedInsertionPointIsNotPlaceable() {
        let spans = [
            TranscriptSpan(text: "kept before", anchor: .exact, frameStart: 0, frameEnd: 50_000),
            TranscriptSpan(text: "typed", anchor: .inherited, frameStart: 50_000, frameEnd: 50_000),
            TranscriptSpan(text: "kept after", anchor: .exact, frameStart: 50_000, frameEnd: 100_000),
        ]
        let markers = [snapped(mark(50_000, seq: 0, kind: .paragraph), at: 50_000)]

        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0].text, "kept before typed")
        XCTAssertEqual(paragraphs[1].text, "kept after")
    }

    /// A run of non-placeable spans with NOTHING preceding them (no placeable span
    /// exists earlier in the array) has no voice to inherit either — there is no
    /// "nearest preceding placeable span." A frame-0 voice marker's cut lands
    /// immediately before the first REAL placeable span (`kept`); the leading `.none`
    /// span stays in its own group, carrying `nil` (never the marker's voice, which it
    /// has no actual evidence for) — the stronger reading of "never allowed to start a
    /// paragraph on its own evidence": it must never be attributed a voice it didn't
    /// earn, not even by being folded into whichever voice happens to follow it.
    /// RULED (controller, T7 Task 5 review): a deliberate deviation from the brief's
    /// literal "inherit the nearest preceding placeable span" wording for exactly this
    /// no-predecessor edge case, accepted because it follows the owner's thrice-affirmed
    /// never-label-untrue principle — attributing a voice with no evidence is exactly
    /// what that principle forbids. Not drift; leave as-is.
    func testLeadingNonPlaceableSpanWithNothingToInheritStaysUnvoiced() {
        let spans = [
            TranscriptSpan(text: "typed opening", anchor: .none),
            TranscriptSpan(text: "kept", anchor: .exact, frameStart: 0, frameEnd: 50_000),
        ]
        let markers = [snapped(mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico), at: 0)]

        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map(\.voice), [nil, "bn"])
        XCTAssertEqual(paragraphs.map(\.text), ["typed opening", "kept"])
    }

    /// Review finding (task-5-report re-review): the interior-cut branch of
    /// `placeableCutPosition` — a marker frame landing STRICTLY inside a placeable
    /// span's `[frameStart, frameEnd)`, with room on both sides — was exercised by ZERO
    /// span-path tests; every prior fixture put the marker at 0, exactly at a span
    /// boundary, or in a gap between spans. This is also the ONLY source of
    /// `structuralApprox: true` on the span path, so `hasApproximateBoundary` was
    /// entirely unpinned there too.
    ///
    /// Marker at 70_000 inside "word"'s `[50_000, 150_000)`: 20_000 from the start,
    /// 80_000 to the end — nearer the start, so the cut lands BEFORE the span
    /// (`insideAt`, not `insideAt + 1`). Deliberately a TWO-span fixture, not one: with
    /// only one placeable span, "cut before" and "cut after" both leave one side of the
    /// cut empty (filtered) and produce the SAME single surviving paragraph — a
    /// direction bug would be invisible. Here the wrong direction pulls "word" into the
    /// FIRST paragraph instead of starting the second one, which the mutation check
    /// below confirms actually fails on this fixture (unlike an earlier, single-span
    /// draft of this test, which did not).
    func testMarkerStrictlyInsideAPlaceableSpanNearerTheStartIsApproximate() {
        let spans = [
            TranscriptSpan(text: "before", anchor: .exact, frameStart: 0, frameEnd: 50_000),
            TranscriptSpan(text: "word", anchor: .exact, frameStart: 50_000, frameEnd: 150_000),
        ]
        let markers = [snapped(mark(70_000, seq: 0, kind: .paragraph), at: 70_000)]

        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map(\.text), ["before", "word"])
        XCTAssertTrue(paragraphs[0].hasApproximateBoundary)
        XCTAssertTrue(paragraphs[1].hasApproximateBoundary)
    }

    /// Companion to the "nearer the start" test above: marker at 90_000 inside "word"'s
    /// [0, 100_000) — 90_000 from the start, 10_000 to the end — nearer the end, so the
    /// cut lands AFTER the span (`insideAt + 1`). A second span ("next") makes the cut
    /// DIRECTION observable: this fixture asserts BOTH the resulting cut position (which
    /// span lands in which paragraph) AND that the boundary is flagged approximate on
    /// BOTH sides of it (`Paragraph.hasApproximateBoundary`'s own contract — the
    /// imprecision belongs to the cut, not to one side of it). Distinct fixture from
    /// `testMarkerInsideASingleRunCutsAtTheNearerEdge` (the committed/`Piece`-based
    /// sibling test) — that one pins `cutIndex(forFrame:pieces:)`; this one pins the
    /// separate `placeableCutPosition` implementation for the span path.
    func testMarkerStrictlyInsideAPlaceableSpanNearerTheEndIsApproximate() {
        let spans = [
            TranscriptSpan(text: "word", anchor: .exact, frameStart: 0, frameEnd: 100_000),
            TranscriptSpan(text: "next", anchor: .exact, frameStart: 100_000, frameEnd: 200_000),
        ]
        let markers = [snapped(mark(90_000, seq: 0, kind: .paragraph), at: 90_000)]

        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map(\.text), ["word", "next"])
        XCTAssertTrue(paragraphs[0].hasApproximateBoundary)
        XCTAssertTrue(paragraphs[1].hasApproximateBoundary)
    }

    /// Gate B Minor 4 — the fixture `placeableCutPosition`'s doc comment deferred to Gate
    /// B, now closed. Two CONSECUTIVE placeable spans sharing IDENTICAL `[0, 100_000)`
    /// bounds is not a contrivance: it is the ordinary post-edit shape, because
    /// `TranscriptSplice` degrades a touched span into `.inherited` fragments that each
    /// carry the PARENT span's FULL bounds. With a marker strictly inside those shared
    /// bounds, `firstIndex(where:)` finds the FIRST fragment, so "nearer the end" cuts
    /// after THAT fragment — not after the run the fragments came from.
    ///
    /// Both halves of the comment's claim are asserted: the cut position (after fragment
    /// one, so fragment two starts the second paragraph) and `structuralApprox` being set
    /// regardless, so the imprecision is disclosed rather than silently claimed as exact.
    /// Nothing tears mid-word either — each paragraph is whole span texts.
    ///
    /// Mutation this fixture uniquely catches (measured, Gate B fix wave):
    /// `firstIndex(where:)` -> `lastIndex(where:)`. Every other interior-cut fixture has
    /// exactly one span containing the frame, so first and last are the same span there and
    /// none of them fail.
    func testTwoPlaceableSpansSharingBoundsCutAfterTheFirstFragmentAndFlagItApproximate() {
        let spans = [
            TranscriptSpan(text: "frag one", anchor: .inherited, frameStart: 0, frameEnd: 100_000),
            TranscriptSpan(text: "frag two", anchor: .inherited, frameStart: 0, frameEnd: 100_000),
            TranscriptSpan(text: "after", anchor: .exact, frameStart: 100_000, frameEnd: 200_000),
        ]
        // 90_000 is strictly inside [0, 100_000) and nearer that interval's END, so the cut
        // goes AFTER the span it landed in — which is fragment ONE, the first match.
        let markers = [snapped(mark(90_000, seq: 0, kind: .paragraph), at: 90_000)]

        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: markers)

        XCTAssertEqual(paragraphs.map(\.text), ["frag one", "frag two after"],
                       "the cut lands after the FIRST same-bounds fragment, not after the run")
        XCTAssertTrue(paragraphs[0].hasApproximateBoundary,
                      "an interior cut is disclosed as approximate on both sides of it")
        XCTAssertTrue(paragraphs[1].hasApproximateBoundary)
    }

    /// A span with an `.unknown` anchor (a foreign/future anchoring scheme this build
    /// doesn't understand) is unplaceable even when it carries real, non-nil frame
    /// bounds — `SpanAnchor.hasUsableBounds` says no for `.unknown` specifically because
    /// frames under a scheme this build can't interpret aren't safe to test a marker
    /// frame against, even though a naive nil-check on `frameStart`/`frameEnd` alone
    /// would not catch this (the field being present is not the same as it being
    /// trustworthy for THIS anchor).
    /// The marker frame sits exactly at the foreign span's own `frameStart` — the one
    /// position where its placeability actually changes the outcome: if `.unknown`
    /// wrongly counted as placeable, the cut would land BEFORE the foreign span
    /// (grouping it with "kept after"); correctly excluded, the cut skips past it to the
    /// next REAL placeable span, grouping "foreign" with "kept before" instead.
    func testUnknownAnchoredSpanWithRealFramesIsNotPlaceable() {
        let spans = [
            TranscriptSpan(text: "kept before", anchor: .exact, frameStart: 0, frameEnd: 20_000),
            TranscriptSpan(text: "foreign", anchor: .unknown("futureScheme"),
                           frameStart: 20_000, frameEnd: 40_000),
            TranscriptSpan(text: "kept after", anchor: .exact, frameStart: 40_000, frameEnd: 60_000),
        ]
        let markers = [snapped(mark(20_000, seq: 0, kind: .paragraph), at: 20_000)]

        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: markers)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0].text, "kept before foreign")
        XCTAssertEqual(paragraphs[1].text, "kept after")
    }

    /// Brief step 5.3 (pure half): the whole-record join rule generalises to a
    /// whole-SPAN join rule — with no markers at all, one paragraph must reproduce
    /// `TranscriptChain.plainText(revision)` byte-for-byte, the same `TranscriptText
    /// .join` rule `plainText` itself uses. Mutation-checked (see task report): a
    /// different separator in `spanParagraph`'s join breaks this.
    func testNoMarkersOverSpansReproducesPlainTextByteForByte() {
        let spans = [
            TranscriptSpan(text: "hello there", anchor: .exact, frameStart: 0, frameEnd: 50_000),
            TranscriptSpan(text: "general kenobi", anchor: .inherited, frameStart: 50_000, frameEnd: 100_000),
        ]
        let revision = TranscriptRevision(id: "R0", source: .userEdit,
                                          createdAt: Date(timeIntervalSince1970: 2_000), spans: spans)

        let paragraphs = TranscriptAttribution.attribute(spans: spans, snapped: [])

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertNil(paragraphs[0].voice)
        XCTAssertEqual(paragraphs[0].text, TranscriptChain.plainText(revision))
        XCTAssertEqual(paragraphs[0].text, "hello there general kenobi")
    }

    func testDisplayNameUppercasesTheOpaqueVoiceID() {
        XCTAssertEqual(TranscriptAttribution.displayName(forVoice: "bn"), "BN")
        XCTAssertEqual(TranscriptAttribution.displayName(forVoice: "ln"), "LN")
        XCTAssertEqual(TranscriptAttribution.displayName(forVoice: "x-third"), "X-THIRD")
    }

    func testIsItalicIsTrueOnlyForBigNico() {
        XCTAssertTrue(TranscriptAttribution.isItalic(voice: "bn"))
        XCTAssertFalse(TranscriptAttribution.isItalic(voice: "ln"))
        XCTAssertFalse(TranscriptAttribution.isItalic(voice: "x-third"))
        XCTAssertFalse(TranscriptAttribution.isItalic(voice: nil))
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
