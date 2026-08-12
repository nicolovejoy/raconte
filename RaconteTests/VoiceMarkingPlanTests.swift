import XCTest
@testable import Raconte

/// T7 Mark Voices (issue #56) Task 4: the pure planner's command shapes.
///
/// Every case is table-driven with cardinality >= 2 (Gate B reco: a single fixture per
/// rule is indistinguishable from a hardcoded answer), built from hand-made spans and
/// paragraphs — no disk. The end-to-end half of this task lives in
/// `VoiceMarkingPlanApplyTests`, which executes these commands through the REAL
/// `MarkerCorrectionWriter` against real capture directories.
final class VoiceMarkingPlanTests: XCTestCase {

    private let bn = VoiceDisplay.mainVoice
    private var ln: String { VoiceDisplay.other(VoiceDisplay.mainVoice) }

    // MARK: - Fixture builders

    /// A placeable span: real, non-degenerate bounds (`TranscriptAttribution.isPlaceableSpan`).
    private func placeable(_ text: String, _ start: Int64, _ end: Int64) -> TranscriptSpan {
        TranscriptSpan(text: text, anchor: .exact, frameStart: start, frameEnd: end)
    }

    /// A span with no usable bounds — the shape a boundary can never anchor to.
    private func unplaceable(_ text: String) -> TranscriptSpan {
        TranscriptSpan(text: text, anchor: .none)
    }

    /// `n` placeable spans, one word each, 10k frames apart.
    private func words(_ n: Int) -> [TranscriptSpan] {
        (0..<n).map { placeable("w\($0)", Int64($0) * 10_000, Int64($0) * 10_000 + 5_000) }
    }

    /// A paragraph over a span range, with its text derived the same way
    /// `TranscriptAttribution.attribute(spans:snapped:)` derives it.
    private func para(_ voice: String?, _ range: Range<Int>,
                      _ spans: [TranscriptSpan]) -> TranscriptAttribution.Paragraph {
        TranscriptAttribution.Paragraph(voice: voice,
                                        text: TranscriptText.join(spans[range].map(\.text)),
                                        hasApproximateBoundary: false,
                                        spanRange: range)
    }

    // MARK: - Opener rule

    /// Anchoring AT the first placeable span of the whole transcript needs no opener: an
    /// `addOpeningVoice` writes frame 0, which resolves to the SAME attribution cut as
    /// the first placeable span's own start, so it could only ever be overridden by the
    /// anchor that follows it (later seq wins). Two shapes: the anchor at span 0, and the
    /// anchor at the first placeable span with non-placeable text leading it.
    func testFlipOfAnUnmarkedEntrysOnlyParagraphAnchorsAtItsFirstPlaceableSpanWithNoOpener() throws {
        let plain = words(3)
        let leadingUnplaceable = [unplaceable("uh")] + words(3)

        let cases: [(name: String, spans: [TranscriptSpan], expectedAnchor: Int)] = [
            ("every span placeable", plain, 0),
            ("a non-placeable span leads the entry", leadingUnplaceable, 1),
        ]

        for c in cases {
            let paragraphs = [para(nil, 0..<c.spans.count, c.spans)]
            let commands = try VoiceMarkingPlan.flipParagraph(at: 0, paragraphs: paragraphs,
                                                              spans: c.spans, hasAnyVoiceMarker: false)
            XCTAssertEqual(commands, [.addVoiceBoundary(spanIndex: c.expectedAnchor, voice: ln)], c.name)
        }
    }

    /// The opener's actual job: everything BEFORE the flipped paragraph must keep the
    /// main voice rather than falling back to "no voice in force". Both cases flip a
    /// paragraph that is neither the first nor the last, so all three commands appear.
    func testFlipOfAMiddleParagraphInAnUnmarkedEntryEmitsOpenerFlipAndRestore() throws {
        let cases: [(name: String, spans: [TranscriptSpan], ranges: [Range<Int>],
                     flip: Int, anchor: Int, restore: Int)] = [
            ("three paragraphs, flip the middle", words(6), [0..<2, 2..<4, 4..<6], 1, 2, 4),
            ("four paragraphs, flip the third", words(8), [0..<2, 2..<4, 4..<6, 6..<8], 2, 4, 6),
        ]

        for c in cases {
            let paragraphs = c.ranges.map { para(nil, $0, c.spans) }
            let commands = try VoiceMarkingPlan.flipParagraph(at: c.flip, paragraphs: paragraphs,
                                                              spans: c.spans, hasAnyVoiceMarker: false)
            XCTAssertEqual(commands, [
                .addOpeningVoice(voice: bn),
                .addVoiceBoundary(spanIndex: c.anchor, voice: ln),
                .addVoiceBoundary(spanIndex: c.restore, voice: bn),
            ], c.name)
        }
    }

    // MARK: - Restore rule

    /// A flip that runs to the end of the entry has nothing to restore — the new voice
    /// legitimately governs everything after it.
    func testFlipOfTheLastParagraphEmitsNoRestore() throws {
        let spans = words(6)

        let unmarked = try VoiceMarkingPlan.flipParagraph(
            at: 1, paragraphs: [para(nil, 0..<2, spans), para(nil, 2..<6, spans)],
            spans: spans, hasAnyVoiceMarker: false)
        XCTAssertEqual(unmarked, [.addOpeningVoice(voice: bn), .addVoiceBoundary(spanIndex: 2, voice: ln)],
                       "two paragraphs, flip the second")

        let marked = try VoiceMarkingPlan.flipParagraph(
            at: 2, paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<4, spans), para(bn, 4..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(marked, [.addVoiceBoundary(spanIndex: 4, voice: ln)],
                       "three already-voiced paragraphs, flip the last")
    }

    /// The opener is gated on `hasAnyVoiceMarker`, not on where the anchor sits: both
    /// cases anchor well past the first placeable span (where an unmarked entry WOULD get
    /// an opener) and must still emit none, because a voice is already in force.
    func testFlipOfAMarkedParagraphEmitsNoOpener() throws {
        let spans = words(6)

        let twoParagraphs = try VoiceMarkingPlan.flipParagraph(
            at: 1, paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(twoParagraphs, [.addVoiceBoundary(spanIndex: 2, voice: ln)])

        let threeParagraphs = try VoiceMarkingPlan.flipParagraph(
            at: 1, paragraphs: [para(ln, 0..<2, spans), para(ln, 2..<4, spans), para(ln, 4..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(threeParagraphs, [
            .addVoiceBoundary(spanIndex: 2, voice: bn),
            .addVoiceBoundary(spanIndex: 4, voice: ln),
        ])
    }

    /// A paragraph that already declares its own voice (its voice differs from the
    /// paragraph before it, which means a voice marker re-declares at its start) needs no
    /// restore — the declaration is already there on disk, and appending a duplicate is
    /// noise. The third row is the adversary: identical shape EXCEPT that the next
    /// paragraph inherits its voice, where the restore must be emitted.
    func testFlipSkipsTheRestoreWhenTheNextParagraphDeclaresItsOwnVoice() throws {
        let spans = words(6)

        let firstOfTwo = try VoiceMarkingPlan.flipParagraph(
            at: 0, paragraphs: [para(bn, 0..<2, spans), para(ln, 2..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(firstOfTwo, [.addVoiceBoundary(spanIndex: 0, voice: ln)],
                       "paragraph 1 declares ln itself")

        let middleOfThree = try VoiceMarkingPlan.flipParagraph(
            at: 1, paragraphs: [para(bn, 0..<2, spans), para(ln, 2..<4, spans), para(bn, 4..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(middleOfThree, [.addVoiceBoundary(spanIndex: 2, voice: bn)],
                       "paragraph 2 declares bn itself")

        let inheritingNeighbour = try VoiceMarkingPlan.flipParagraph(
            at: 0, paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(inheritingNeighbour, [
            .addVoiceBoundary(spanIndex: 0, voice: ln),
            .addVoiceBoundary(spanIndex: 2, voice: bn),
        ], "paragraph 1 only INHERITS bn — without a restore it would flip too")
    }

    /// Walking forward past a paragraph with nothing to anchor to, and the end of that
    /// walk. The restored voice is the NEXT paragraph's pre-change voice even when the
    /// index it lands on comes from a later paragraph.
    func testRestoreWalksPastAParagraphWithNoPlaceableSpans() throws {
        var spans = words(5)
        spans.insert(unplaceable("mm"), at: 2)      // spans: w0 w1 [mm] w2 w3 w4

        let walked = try VoiceMarkingPlan.flipParagraph(
            at: 0,
            paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<3, spans), para(bn, 3..<6, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(walked, [
            .addVoiceBoundary(spanIndex: 0, voice: ln),
            .addVoiceBoundary(spanIndex: 3, voice: bn),
        ], "paragraph 1 holds only a non-placeable span — the restore lands in paragraph 2")

        let walkedOffTheEnd = try VoiceMarkingPlan.flipParagraph(
            at: 0,
            paragraphs: [para(bn, 0..<2, spans), para(bn, 2..<3, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(walkedOffTheEnd, [.addVoiceBoundary(spanIndex: 0, voice: ln)],
                       "nothing placeable remains to restore at")
    }

    // MARK: - Refusals

    func testFlipThrowsNotMarkableWhenTheParagraphHasNoPlaceableSpan() throws {
        let spans = [unplaceable("uh"), unplaceable("mm")] + words(2)

        let allUnplaceable = [para(nil, 0..<2, spans), para(nil, 2..<4, spans)]
        XCTAssertThrowsError(try VoiceMarkingPlan.flipParagraph(at: 0, paragraphs: allUnplaceable,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable)
        }

        // The committed/pieces attribution path populates no `spanRange` at all.
        let noSpanRange = [TranscriptAttribution.Paragraph(voice: nil, text: "uh mm w0 w1",
                                                           hasApproximateBoundary: false, spanRange: nil)]
        XCTAssertThrowsError(try VoiceMarkingPlan.flipParagraph(at: 0, paragraphs: noSpanRange,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable)
        }

        XCTAssertThrowsError(try VoiceMarkingPlan.flipParagraph(at: 7, paragraphs: allUnplaceable,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
            XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable)
        }
    }

    /// Endpoints are the caller's responsibility, but the planner refuses rather than
    /// trusting it — `MarkerCorrectionWriter` would throw on the same span anyway, and a
    /// half-written plan (switch appended, restore refused) is worse than no plan.
    func testMarkRangeThrowsNotMarkableWhenAnEndpointIsNotPlaceable() throws {
        var spans = words(4)
        spans[1] = unplaceable("mm")
        let paragraphs = [para(nil, 0..<4, spans)]

        for range in [1...2, 0...1, 0...9] {
            XCTAssertThrowsError(try VoiceMarkingPlan.markRange(range, to: ln, paragraphs: paragraphs,
                                                                spans: spans, hasAnyVoiceMarker: false)) {
                XCTAssertEqual($0 as? VoiceMarkingPlan.PlanError, .notMarkable, "\(range)")
            }
        }
    }

    // MARK: - markRange

    /// The three-way split: the marked words take the target voice, and the first
    /// placeable span after them restores whatever governed there before.
    func testMarkRangeMidParagraphEmitsSwitchAndRestoreAtTheFollowingSpan() throws {
        let spans = words(5)

        let unmarked = try VoiceMarkingPlan.markRange(1...2, to: ln, paragraphs: [para(nil, 0..<5, spans)],
                                                       spans: spans, hasAnyVoiceMarker: false)
        XCTAssertEqual(unmarked, [
            .addOpeningVoice(voice: bn),
            .addVoiceBoundary(spanIndex: 1, voice: ln),
            .addVoiceBoundary(spanIndex: 3, voice: bn),
        ], "an unmarked entry needs the opener to voice the words before the range")

        let alreadyVoiced = try VoiceMarkingPlan.markRange(2...3, to: ln,
                                                           paragraphs: [para(bn, 0..<5, spans)],
                                                           spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(alreadyVoiced, [
            .addVoiceBoundary(spanIndex: 2, voice: ln),
            .addVoiceBoundary(spanIndex: 4, voice: bn),
        ], "the restore carries the voice governing the span it lands on")

        let acrossParagraphs = try VoiceMarkingPlan.markRange(
            1...3, to: bn,
            paragraphs: [para(ln, 0..<2, spans), para(bn, 2..<3, spans), para(ln, 3..<5, spans)],
            spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(acrossParagraphs, [
            .addVoiceBoundary(spanIndex: 1, voice: bn),
            .addVoiceBoundary(spanIndex: 4, voice: ln),
        ], "span 4's governing paragraph is the ln one it sits in, not the range's own paragraph")
    }

    func testMarkRangeToTheEndOfTheEntryEmitsNoRestore() throws {
        let spans = words(5)
        let toTheLastSpan = try VoiceMarkingPlan.markRange(3...4, to: ln, paragraphs: [para(bn, 0..<5, spans)],
                                                           spans: spans, hasAnyVoiceMarker: true)
        XCTAssertEqual(toTheLastSpan, [.addVoiceBoundary(spanIndex: 3, voice: ln)])

        var withTrailingUnplaceable = words(4)
        withTrailingUnplaceable.append(unplaceable("mm"))
        let toTheLastPlaceableSpan = try VoiceMarkingPlan.markRange(
            2...3, to: ln, paragraphs: [para(bn, 0..<5, withTrailingUnplaceable)],
            spans: withTrailingUnplaceable, hasAnyVoiceMarker: true)
        XCTAssertEqual(toTheLastPlaceableSpan, [.addVoiceBoundary(spanIndex: 2, voice: ln)],
                       "a trailing non-placeable span can anchor nothing — no restore exists to emit")
    }
}
