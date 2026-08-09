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
