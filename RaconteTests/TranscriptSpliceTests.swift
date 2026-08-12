import XCTest
@testable import Raconte

/// T6d: `TranscriptSplice` — the pure diff-and-splice engine (design §3.3, §10's splice
/// table). No filesystem — every case is a value transform over hand-built revisions.
final class TranscriptSpliceTests: XCTestCase {

    private let parentID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    private func parent(_ spans: [TranscriptSpan]) -> TranscriptRevision {
        TranscriptRevision(id: parentID, source: .machineLive,
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                           spans: spans)
    }

    private func exact(_ text: String, _ start: Int64, _ end: Int64,
                       sourceRevisionID: String? = nil) -> TranscriptSpan {
        TranscriptSpan(text: text, anchor: .exact, frameStart: start, frameEnd: end,
                       sourceRevisionID: sourceRevisionID)
    }

    // MARK: - §10 splice table

    func testUnchangedTextPreservesExactAndSourceRevisionID() {
        let p = parent([exact("hello world", 0, 100, sourceRevisionID: "R-machine")])
        let result = TranscriptSplice.spans(parent: p, editedText: "hello world")
        XCTAssertEqual(result, [exact("hello world", 0, 100, sourceRevisionID: "R-machine")])
    }

    func testUnchangedSpanWithDefaultSourceResolvesToParentIDExplicitly() {
        // The span's own sourceRevisionID field is nil (== the parent it lives in,
        // per TranscriptSpan's own economy). Copying that nil verbatim into a NEW
        // revision would misresolve to the NEW revision's id — so the untouched-copy
        // path must write the resolved parent id explicitly instead.
        let p = parent([exact("hello world", 0, 100)])
        let result = TranscriptSplice.spans(parent: p, editedText: "hello world")
        XCTAssertEqual(result, [exact("hello world", 0, 100, sourceRevisionID: parentID)])
    }

    func testMidSpanEditDegradesBothSurvivingFragmentsToInheritedFullBounds() {
        let p = parent([exact("cabin", 10, 20)])
        // "cabin" -> "castin": delete "b", insert "st". The prefix "ca" and suffix
        // "in" are FRAGMENTS of the touched span — both would independently be
        // .inherited with the parent's FULL [10,20] bounds, never a synthesized
        // sub-range (F17). "st" itself is brand new text, anchored as an ordinary
        // insertion (a zero-length point at the nearest preceding span's frameEnd) —
        // but NONE of these three pieces may survive as separate array entries
        // (Critical 1): `TranscriptText.join` inserts a synthetic space between every
        // pair of array elements and nowhere else, so "ca"/"st"/"in" left as three
        // spans would round-trip to "ca st in", not "castin". They fold into ONE
        // combined span whose bounds are the union of the pieces involved — here that
        // union is exactly the parent's own [10,20], since every piece's natural
        // bounds already sit inside it.
        let result = TranscriptSplice.spans(parent: p, editedText: "castin")
        XCTAssertEqual(result, [
            TranscriptSpan(text: "castin", anchor: .inherited, frameStart: 10, frameEnd: 20,
                           sourceRevisionID: parentID),
        ])
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "castin")
    }

    /// F17, pinned where it actually bites: a lone fragment that survives as its OWN
    /// array entry (an untouched separator keeps it apart from its neighbour) must
    /// carry the parent's FULL bounds, never a synthesized sub-range. The prior
    /// version of this row asserted only a UNION of a forced merge — `forcedMerge`
    /// takes `min(start)`/`max(end)` (`TranscriptSplice.swift`), so a mutation that
    /// synthesizes per-fragment sub-ranges and then unions them back can still land
    /// on the correct total range and slip past a union-only assertion. This test
    /// avoids that: "dog" is untouched, so "ca" is emitted alone, and its bounds must
    /// be checked directly against the parent's, not reconstructed from a union.
    func testLoneFragmentSurvivingBesideAnUntouchedSpanCarriesParentsFullBoundsNotASubRange() {
        let p = parent([exact("cabin", 10, 20), exact("dog", 30, 40)])
        // "cabin dog" -> "ca dog": deletes "bin" from the end of "cabin", keeps the
        // separator and "dog" untouched.
        let result = TranscriptSplice.spans(parent: p, editedText: "ca dog")
        XCTAssertEqual(result, [
            TranscriptSpan(text: "ca", anchor: .inherited, frameStart: 10, frameEnd: 20,
                           sourceRevisionID: parentID),
            exact("dog", 30, 40, sourceRevisionID: parentID),
        ])
        XCTAssertEqual(result[0].frameStart, 10, "the fragment's frameStart must be the PARENT's own, not synthesized")
        XCTAssertEqual(result[0].frameEnd, 20, "the fragment's frameEnd must be the PARENT's own, not a sub-range")
    }

    // MARK: - T7 Task 6, #37: typed-word correction (out-of-vocab retype)

    /// #37's real scenario, in issue #38's own words: "spoken 'LN' transcribes as
    /// 'ellen' every time" — lowercase, mid-sentence, not the capitalized name. The
    /// owner retypes it in the editor. This is what Task 4's splice already gives #37
    /// for free — the acceptance test the brief asks for.
    ///
    /// **A premise check that mattered:** a capitalized "Ellen" -> "LN" pair shares NO
    /// characters at all (character-level Myers diff, case-sensitive), so the whole
    /// "Ellen" span would be wholly removed and "LN" would land via the BRAND-NEW-TEXT
    /// path (`TranscriptSplice.swift`'s `.insertion` case) — a zero-length `.inherited`
    /// POINT at the preceding span's end, not the replaced span's bounds at all. Probed
    /// directly (`target.difference(from: source)`) before trusting either premise. The
    /// ACTUAL scenario is lowercase — "ellen" and "ln" share their `l` and `n` — so the
    /// diff finds a genuine two-character survivor (`ln`) inside the old five-character
    /// run, which is exactly what makes this a TOUCHED span (F17's path), not a wholesale
    /// replacement: the retyped word must land as an `.inherited` span over the touched
    /// SPAN's own FULL parent bounds — not `.none` (the anchor would be lost entirely)
    /// and not a synthesized sub-range (claiming more precision than the edit has;
    /// nobody re-timed "ln" against the audio).
    func testRetypingAnOutOfVocabWordProducesInheritedOverTheFullReplacedSpanBounds() {
        let p = parent([
            exact("hello", 0, 10),
            exact("ellen", 10, 20),
            exact("said", 20, 30),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "hello ln said")

        XCTAssertEqual(result, [
            exact("hello", 0, 10, sourceRevisionID: parentID),
            TranscriptSpan(text: "ln", anchor: .inherited, frameStart: 10, frameEnd: 20,
                           sourceRevisionID: parentID),
            exact("said", 20, 30, sourceRevisionID: parentID),
        ])

        let corrected = result[1]
        XCTAssertEqual(corrected.text, "ln")
        XCTAssertEqual(corrected.anchor, .inherited, "never .none — the touched span's provenance is kept")
        XCTAssertEqual(corrected.frameStart, 10, "the TOUCHED span's own start, not a scrubbed or synthesized time")
        XCTAssertEqual(corrected.frameEnd, 20, "the TOUCHED span's own end — the full bounds, never a sub-range")
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "hello ln said")
    }

    /// **Splice-inherit ruling (design §16.5, owner 2026-08-11 — Task 9b).** The REAL
    /// #37/#38 retype is the CAPITALIZED "LN" — how the owner actually writes the voice
    /// name in prose (`StructureMarker.Voice.littleNico` is the lowercase stored ID).
    /// At that casing, "Ellen" and "LN" share ZERO characters (case-sensitive Myers
    /// diff), so this does NOT take F17's touched-span path — it takes the
    /// brand-new-text `.insertion` path instead. This test used to pin the OLD
    /// behavior (a zero-length `.inherited` point at the preceding span's end, the
    /// replaced span's own `[10,20)` bounds discarded entirely) as a named,
    /// deliberate gap awaiting an owner ruling on whether a wholesale replacement
    /// should instead inherit the replaced span's own bounds.
    ///
    /// **The ruling landed 2026-08-11: it does.** The retyped word IS the heard word,
    /// corrected — a zero-length anchor at the preceding span's end asserted something
    /// untrue about where the word lives in the audio. Flipped here to pin the FIX:
    /// running this test BEFORE the `TranscriptSplice` change (git stash the source
    /// edit, keep this test) fails with `frameStart == frameEnd == 10` and no span
    /// covering `[10,20)` — exactly the old assertions this test used to make. That
    /// failure is Task 9b's RED evidence.
    func testWholesaleZeroOverlapReplacementInheritsTheReplacedSpansFrames() {
        let p = parent([
            exact("hello", 0, 10),
            exact("Ellen", 10, 20),
            exact("said", 20, 30),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "hello LN said")

        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "hello LN said")
        let retyped = try? XCTUnwrap(result.first { $0.text == "LN" })
        let corrected = retyped ?? TranscriptSpan(text: "MISSING", anchor: .none)
        XCTAssertEqual(corrected.anchor, .inherited, "never .none — the replaced span's provenance is kept")
        XCTAssertEqual(corrected.frameStart, 10,
                       "inherits the REPLACED span's own start, not a zero-length point at some other span's end")
        XCTAssertEqual(corrected.frameEnd, 20,
                       "inherits the REPLACED span's own end — real bounds, not a point")
        XCTAssertNotEqual(corrected.frameStart, corrected.frameEnd,
                          "must be a real interval, not degenerately zero-length")
        XCTAssertEqual(corrected.sourceRevisionID, parentID,
                       "resolved explicitly, same rule as every other borrowed span")

        // Task 5's placeability rule (TranscriptAttribution.isPlaceableSpan) requires
        // usable, non-zero-length bounds — the whole point of the ruling is that "LN"
        // can now anchor a 6.4b word-anchored boundary-add and start a paragraph.
        XCTAssertTrue(TranscriptAttribution.isPlaceableSpan(corrected),
                      "the corrected word must be placeable now that it carries real bounds")
    }

    /// Mutation guard (b): an implementation that grabs the PRECEDING span's frames
    /// instead of the REPLACED span's own would still produce a non-zero-length
    /// `.inherited` span and could slip past a looser assertion. "hello" is [0,10] and
    /// "Ellen" is [10,20] — deliberately different bounds so the two are
    /// distinguishable; this test fails if the wrong span's frames are inherited.
    func testWholesaleReplacementInheritsTheReplacedSpanNotThePrecedingOne() {
        let p = parent([
            exact("hello", 0, 10),
            exact("Ellen", 10, 20),
            exact("said", 20, 30),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "hello LN said")
        let corrected = try? XCTUnwrap(result.first { $0.text == "LN" })
        XCTAssertEqual(corrected?.frameStart, 10, "the REPLACED span's [10,20) start, not the preceding span's [0,10) start")
        XCTAssertEqual(corrected?.frameEnd, 20, "the REPLACED span's [10,20) end, not the preceding span's [0,10) end")
        XCTAssertNotEqual(corrected?.frameStart, 0, "must not be the preceding span's start")
    }

    /// The replaced span need not have a preceding neighbour at all — a leading
    /// wholesale replacement still inherits its own bounds rather than falling back to
    /// `.none` for lack of a `lastUsableFrameEnd` to borrow.
    func testLeadingWholesaleReplacementInheritsItsOwnBoundsWithNoPrecedingSpan() {
        let p = parent([
            exact("Ellen", 10, 20),
            exact("said", 20, 30),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "LN said")
        let corrected = try? XCTUnwrap(result.first { $0.text == "LN" })
        XCTAssertEqual(corrected?.anchor, .inherited)
        XCTAssertEqual(corrected?.frameStart, 10)
        XCTAssertEqual(corrected?.frameEnd, 20)
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "LN said")
    }

    /// Review Important 2 (T7 Task 9b): the wholesale tag can fire on a REPLACED span
    /// that itself has no usable bounds (e.g. an unattached machine span, or one
    /// already degraded to `.none` by an earlier edit). There is nothing to inherit —
    /// falling through to the PRECEDING span's `frameEnd` would anchor the correction
    /// under a DIFFERENT word's provenance, the exact untruth §16.5 exists to remove.
    /// Same principle as the sibling touched-span rule two cases above
    /// (`testEditingAnUnanchoredSpanProducesNoneFragmentsNotFabricatedBounds`): no
    /// usable bounds means `.none`, nil source — never borrowed from a neighbour.
    func testWholesaleReplacementOfAnUnanchoredSpanIsNoneNotBorrowedFromThePrecedingSpan() {
        let p = parent([
            exact("hello", 0, 10),
            TranscriptSpan(text: "Ellen", anchor: .none),
            exact("said", 20, 30),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "hello LN said")
        let retyped = try? XCTUnwrap(result.first { $0.text == "LN" })
        let corrected = retyped ?? TranscriptSpan(text: "MISSING", anchor: .exact, frameStart: -1, frameEnd: -1)
        XCTAssertEqual(corrected.anchor, .none, "nothing to inherit — the replaced span itself had no usable bounds")
        XCTAssertNil(corrected.frameStart, "must not borrow the PRECEDING span's frameEnd (10)")
        XCTAssertNil(corrected.frameEnd)
        XCTAssertNil(corrected.sourceRevisionID, "must not borrow the preceding span's provenance")
        XCTAssertFalse(TranscriptAttribution.isPlaceableSpan(corrected),
                       "a span with no usable bounds must never be placeable")
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "hello LN said")
    }

    // MARK: - Gate B Important 1: what the wholesale-replacement rule must NOT swallow
    //
    // §16.5's inherit rule is scoped to ONE retyped word: a run of removed characters
    // covering ALL of exactly one span, immediately followed by newly typed text. Every
    // qualifying clause had a positive test and NO negative one — Gate B loosened
    // `pendingCharsSeen == parentSpans[spanIndex].text.count` to `>= 1` and all 1116 tests
    // still passed, which is the §16.5 untruth generalized: a partial-span typo fix would
    // silently claim the whole word's audio. One negative fixture per clause below.

    /// (a) PARTIAL-span replacement — the loosening Gate B actually mutated in.
    /// "Ellen" [10,20) is the leading span and only its first characters are replaced
    /// (`XYZlen`); the typed text is NOT the heard word corrected, so it may not claim
    /// [10,20).
    ///
    /// The leading position is what makes the two behaviours distinguishable at all: a
    /// touched span's surviving fragment carries the PARENT'S FULL bounds (F17) and sits
    /// immediately beside the insertion with no separator, so `combine` folds them into one
    /// span — and the union of "point at the last usable end" with "full parent bounds" is
    /// just the full parent bounds again, identical to the wrong answer. With nothing
    /// anchored BEFORE it the insertion is `.none` (nothing to borrow), and `forcedMerge`
    /// with a `.none` side is `.none`, so the frames the mutation fabricates show up as the
    /// difference between `.none` and `.inherited [10,20)`.
    func testPartialSpanReplacementNeverInheritsTheWholeSpansFrames() {
        let p = parent([
            exact("Ellen", 10, 20),
            exact("said", 20, 30),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "XYZlen said")

        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "XYZlen said")
        guard let edited = result.first else { return XCTFail("no output spans") }
        XCTAssertEqual(edited.text, "XYZlen")
        XCTAssertEqual(edited.anchor, .none,
                       "a partial replacement is not the heard word corrected — it may not "
                       + "inherit the replaced span's measurement")
        XCTAssertNil(edited.frameStart, "must not claim the replaced span's [10,20)")
        XCTAssertNil(edited.frameEnd)
        XCTAssertFalse(TranscriptAttribution.isPlaceableSpan(edited),
                       "partially retyped text must not become placeable off frames nobody measured")
    }

    /// (b) A replacement that eats the join-SEPARATOR too (the taint rule). Deleting the
    /// space before "Ellen" and retyping the word merges two things at once; §16.5 covers
    /// one retyped word with its spacing intact, not a merge across a deleted boundary. The
    /// typed "LN" stays an ordinary insertion — a zero-length point at the last usable end
    /// (10, `hello`'s) — so the merged output ends at 10 and never stretches to "Ellen"'s
    /// [10,20) end.
    func testReplacementAcrossADeletedSeparatorNeverInheritsTheReplacedSpansFrames() {
        let p = parent([
            exact("hello", 0, 10),
            exact("Ellen", 10, 20),
            exact("said", 20, 30),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "helloLN said")

        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "helloLN said")
        guard let merged = result.first(where: { $0.text.contains("LN") }) else {
            return XCTFail("no span carries the retyped text")
        }
        XCTAssertEqual(merged.frameEnd, 10,
                       "the typed text anchors as a point at the last usable end, so the merged "
                       + "span still ends where 'hello' did")
        XCTAssertNotEqual(merged.frameEnd, 20,
                          "must not stretch to the replaced span's end — the deleted separator "
                          + "taints the run, and this is a merge, not a corrected word")
    }

    /// (c) A removal run spanning TWO spans. Deleting "bravo delta" and typing "XY" is not
    /// a corrected word either, and the typed text must inherit NEITHER span's bounds — it
    /// lands as an ordinary point at "alpha"'s end.
    ///
    /// **Two independent defenses, measured (Gate B fix wave).** `TranscriptText.join` puts
    /// a separator between EVERY pair of non-empty spans, so a removal run that reaches a
    /// second span has always crossed a separator first — the taint rule and the explicit
    /// two-span disqualification (`TranscriptSplice.swift`'s `pendingSpan == spanIndex`
    /// else-branch) BOTH cover this shape, and either alone is sufficient. Disabling just
    /// one leaves this test green in both directions (measured, one mutation at a time);
    /// disabling BOTH makes it fail here. So this fixture pins the pair, and neither branch
    /// can be deleted along with the other without a red test.
    func testARemovalRunSpanningTwoSpansNeverInheritsEitherSpansFrames() {
        let p = parent([
            exact("alpha", 0, 10),
            exact("bravo", 10, 20),
            exact("delta", 20, 30),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "alpha XY")

        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "alpha XY")
        guard let typed = result.first(where: { $0.text.contains("XY") }) else {
            return XCTFail("no span carries the typed text")
        }
        XCTAssertEqual(typed.frameStart, 10, "a zero-length point at 'alpha''s end")
        XCTAssertEqual(typed.frameEnd, 10)
        XCTAssertNotEqual(typed.frameEnd, 20, "must not inherit 'bravo''s [10,20)")
        XCTAssertNotEqual(typed.frameEnd, 30, "must not inherit 'delta''s [20,30)")
    }

    func testDeletionLeavesFramesUnclaimedNoNeighbourStretching() {
        let p = parent([
            exact("hello", 0, 10),
            exact("world", 10, 20),
        ])
        // Delete the whole second span (and the separating space).
        let result = TranscriptSplice.spans(parent: p, editedText: "hello")
        XCTAssertEqual(result, [exact("hello", 0, 10, sourceRevisionID: parentID)])
        // "world"'s frames [10,20] are gone, not absorbed into "hello"'s [0,10].
        XCTAssertEqual(result.first?.frameEnd, 10)
    }

    func testInsertionWithNoPrecedingAnchorIsNone() {
        let p = parent([])
        let result = TranscriptSplice.spans(parent: p, editedText: "brand new text")
        XCTAssertEqual(result, [TranscriptSpan(text: "brand new text", anchor: .none)])
    }

    func testInsertionAfterAnchoredSpanIsZeroLengthInheritedPointAtItsFrameEnd() {
        let p = parent([exact("hello", 0, 10)])
        // The parent has only ONE span, so there is no synthetic join-separator
        // character in the source to absorb the space before "world" — the whole
        // " world" (space included) is genuinely new text the user typed, anchored as
        // a zero-length point at "hello"'s frameEnd. It cannot survive as a SEPARATE
        // array entry from "hello" (Critical 1: nothing separates them in the edited
        // text, and `TranscriptText.join` would insert a phantom space there) — they
        // fold into one span, and the previously-exact "hello" necessarily degrades to
        // `.inherited` (the lattice only ever degrades) with the union of both pieces'
        // bounds, which is still exactly [0,10] since the insertion's own point (10,10)
        // sits inside it.
        let result = TranscriptSplice.spans(parent: p, editedText: "hello world")
        XCTAssertEqual(result, [
            TranscriptSpan(text: "hello world", anchor: .inherited, frameStart: 0, frameEnd: 10,
                           sourceRevisionID: parentID),
        ])
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "hello world")
    }

    // MARK: - Critical 1: round-trip fidelity (join(spans) == editedText)

    func testDeletingTheSeparatorBetweenTwoExactSpansIsNeverSilentlyRestored() {
        let p = parent([exact("hello", 0, 10), exact("world", 10, 20)])
        let result = TranscriptSplice.spans(parent: p, editedText: "helloworld")
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "helloworld")
        XCTAssertFalse(result.contains { $0.anchor == .exact },
                       "neither original .exact span may survive once forced together")
    }

    func testInsertingAnExtraSpaceIsNeverAmplifiedIntoThreeSpaces() {
        let p = parent([exact("hello", 0, 10), exact("world", 10, 20)])
        let result = TranscriptSplice.spans(parent: p, editedText: "hello  world")
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "hello  world")
    }

    /// The F18 property test's own random fuzzing surfaced this: a span between two
    /// others fully deleted while BOTH its flanking separators survive leaves the
    /// SECOND separator with nothing following it (nothing was deleted after it, but
    /// nothing else remains either) — a trailing gap that materializes onto the
    /// previous span's text. `.exact` cannot survive gaining that literal space (its
    /// text would no longer byte-match the parent span it descends from — F18) even
    /// though the span's OWN characters were never touched.
    func testTrailingMaterializedSeparatorDegradesExactToInheritedNotJustAppendsText() {
        let p = parent([exact("d", 0, 1), TranscriptSpan(text: "d", anchor: .none)])
        // "d d" -> "d " (the second "d" span entirely deleted, both its flanking
        // separators — there is only one here, since this parent has just two spans —
        // survive... concretely: delete the trailing "d", keep the space before it.
        let result = TranscriptSplice.spans(parent: p, editedText: "d ")
        XCTAssertEqual(result, [
            TranscriptSpan(text: "d ", anchor: .inherited, frameStart: 0, frameEnd: 1, sourceRevisionID: parentID),
        ])
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "d ")
    }

    /// Same hazard, leading side: a span at the very start is fully deleted while the
    /// separator after it survives, leaving that separator with nothing preceding it.
    func testLeadingMaterializedSeparatorDegradesExactToInheritedNotJustPrependsText() {
        let p = parent([TranscriptSpan(text: "b", anchor: .none), exact("world", 0, 5)])
        // "b world" -> " world" (the leading "b" deleted, the separator before
        // "world" survives with nothing before it).
        let result = TranscriptSplice.spans(parent: p, editedText: " world")
        XCTAssertEqual(result, [
            TranscriptSpan(text: " world", anchor: .inherited, frameStart: 0, frameEnd: 5, sourceRevisionID: parentID),
        ])
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), " world")
    }

    func testAdjacentNoneSpansMerge() {
        // Two untouched .none spans, with the span between them (and both separators
        // around it) deleted entirely, end up genuinely adjacent with no barrier —
        // merge-eligible, and merge into one span with no inserted space (the user
        // really did remove the space along with "middle").
        let p = parent([
            TranscriptSpan(text: "black", anchor: .none),
            TranscriptSpan(text: "middle", anchor: .none),
            TranscriptSpan(text: "white", anchor: .none),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "blackwhite")
        XCTAssertEqual(result, [TranscriptSpan(text: "blackwhite", anchor: .none, sourceRevisionID: parentID)])
    }

    func testInteriorInsertionFragmentsReMergeWhenBoundsAndSourceMatchAfterSplice() {
        // "ab" edited to "axb": splicing first splits the touched span into "a" and
        // "b" fragments (both .inherited, the parent's [5,5] bounds), and the new "x"
        // borrows that SAME point in between. All three end up sharing identical
        // anchor/bounds/source, so the (deliberately content-blind, §3.3) merge pass
        // folds them back into one span — lossless, since the text "axb" survives
        // exactly, just with the fact that "x" is new no longer distinguished.
        let p = parent([exact("ab", 5, 5)])
        let result = TranscriptSplice.spans(parent: p, editedText: "axb")
        XCTAssertEqual(result, [
            TranscriptSpan(text: "axb", anchor: .inherited, frameStart: 5, frameEnd: 5,
                           sourceRevisionID: parentID),
        ])
    }

    func testTwoAdjacentInheritedFragmentsFromDifferentSpansMergeWhenBoundsAndSourceMatch() {
        // Two DIFFERENT parent spans that happen to carry IDENTICAL bounds/source,
        // both edited (so both degrade to .inherited), with the separator between
        // them REMOVED by the edit (no barrier) -> merge-eligible.
        let p = parent([
            exact("cab", 5, 5, sourceRevisionID: "R-shared"),
            exact("dog", 5, 5, sourceRevisionID: "R-shared"),
        ])
        // "cab dog" -> "cxbdyg": edits both spans and removes the separating space.
        let result = TranscriptSplice.spans(parent: p, editedText: "cxbdyg")
        // No two adjacent output spans both .inherited with matching bounds/source
        // remain unmerged.
        for i in 0..<max(0, result.count - 1) {
            let a = result[i], b = result[i + 1]
            if a.anchor == .inherited, b.anchor == .inherited {
                XCTAssertFalse(a.frameStart == b.frameStart && a.frameEnd == b.frameEnd
                               && a.sourceRevisionID == b.sourceRevisionID,
                               "adjacent mergeable .inherited spans must have been merged")
            }
        }
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "cxbdyg")
    }

    func testAdjacentExactSpansNeverMerge() {
        let p = parent([
            exact("hello", 0, 10),
            exact("world", 10, 20),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "hello world")
        XCTAssertEqual(result, [
            exact("hello", 0, 10, sourceRevisionID: parentID),
            exact("world", 10, 20, sourceRevisionID: parentID),
        ])
        XCTAssertEqual(result.count, 2, "two exact spans must never merge, even if adjacent")
    }

    func testKeptSeparatorBlocksMergeAndIsNotStoredAsText() {
        // Two untouched .none spans separated by an UNCHANGED separator must stay two
        // spans (never merged, since the space between them is real and must survive
        // via TranscriptChain.plainText's join rule on the next read, not by being
        // baked into either span's stored text).
        let p = parent([
            TranscriptSpan(text: "left", anchor: .none),
            TranscriptSpan(text: "right", anchor: .none),
        ])
        let result = TranscriptSplice.spans(parent: p, editedText: "left right")
        XCTAssertEqual(result, [
            TranscriptSpan(text: "left", anchor: .none, sourceRevisionID: parentID),
            TranscriptSpan(text: "right", anchor: .none, sourceRevisionID: parentID),
        ])
    }

    // MARK: - Unattached (.none) parent span, edited, must stay .none (no bounds to inherit)

    func testEditingAnUnanchoredSpanProducesNoneFragmentsNotFabricatedBounds() {
        let p = parent([TranscriptSpan(text: "cabin", anchor: .none)])
        let result = TranscriptSplice.spans(parent: p, editedText: "castin")
        for span in result {
            XCTAssertEqual(span.anchor, .none)
            XCTAssertNil(span.frameStart)
            XCTAssertNil(span.frameEnd)
        }
        XCTAssertEqual(TranscriptText.join(result.map(\.text)), "castin")
    }

    // MARK: - F18 monotone-lattice property (scoped to userEdit splice output)

    /// This test carries TWO asserted properties over the same 200 random cases:
    /// F18's monotone lattice, and (Critical 1 fix) round-trip fidelity — every
    /// output must satisfy `TranscriptText.join(spans) == editedText`, since that
    /// equality is what makes the whole splice safe to write to disk and read back.
    /// Before the Critical-1 fix this postcondition failed immediately (RED evidence
    /// in the fix report): a deleted join-separator between two untouched `.exact`
    /// spans left them as two array entries, which `TranscriptText.join` silently
    /// reunites with a phantom space on the next read.
    func testMonotoneLatticeNoExactSpanHasTextDifferingFromItsParentSpan() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abcde ")
        for _ in 0..<200 {
            let parentSpans = Self.randomSpans(alphabet: alphabet, rng: &rng)
            let p = parent(parentSpans)
            let parentText = TranscriptChain.plainText(p)
            let editedText = Self.randomEdit(of: parentText, alphabet: alphabet, rng: &rng)

            let result = TranscriptSplice.spans(parent: p, editedText: editedText)

            let joined = TranscriptText.join(result.map(\.text))
            XCTAssertEqual(joined, editedText,
                           "spliced output must round-trip through TranscriptText.join back to exactly what was typed")

            for span in result where span.anchor == .exact {
                // Every .exact output span must be a byte-identical, UNSPLIT copy of
                // some parent span's full text — never a sub-range or a modification.
                XCTAssertTrue(parentSpans.contains { $0.anchor == .exact && $0.text == span.text },
                              "an .exact span in the output must match a parent .exact span verbatim")
            }
        }
    }

    // MARK: - Generative helpers

    private static func randomSpans(alphabet: [Character],
                                    rng: inout SystemRandomNumberGenerator) -> [TranscriptSpan] {
        let count = Int.random(in: 0...3, using: &rng)
        var spans: [TranscriptSpan] = []
        var frame: Int64 = 0
        let letters = alphabet.filter { $0 != " " }
        for _ in 0..<count {
            let length = Int.random(in: 1...5, using: &rng)
            let text = String((0..<length).map { _ in letters.randomElement(using: &rng)! })
            let anchorRoll = Int.random(in: 0...2, using: &rng)
            let span: TranscriptSpan
            switch anchorRoll {
            case 0:
                span = TranscriptSpan(text: text, anchor: .exact, frameStart: frame, frameEnd: frame + Int64(length))
            case 1:
                span = TranscriptSpan(text: text, anchor: .inherited, frameStart: frame, frameEnd: frame + Int64(length))
            default:
                span = TranscriptSpan(text: text, anchor: .none)
            }
            frame += Int64(length)
            spans.append(span)
        }
        return spans
    }

    private static func randomEdit(of text: String, alphabet: [Character],
                                   rng: inout SystemRandomNumberGenerator) -> String {
        var chars = Array(text)
        let editCount = Int.random(in: 0...3, using: &rng)
        for _ in 0..<editCount {
            let op = Int.random(in: 0...2, using: &rng)
            switch op {
            case 0 where !chars.isEmpty:
                chars.remove(at: Int.random(in: 0..<chars.count, using: &rng))
            case 1:
                let index = Int.random(in: 0...chars.count, using: &rng)
                chars.insert(alphabet.randomElement(using: &rng)!, at: index)
            default:
                break
            }
        }
        return String(chars)
    }
}
