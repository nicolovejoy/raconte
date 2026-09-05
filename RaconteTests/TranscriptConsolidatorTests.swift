import XCTest
@testable import Raconte

/// M2 T2: the SDK's documented sharp edges around volatile results (design §8).
/// Every one of these is reachable without models or hardware.
final class TranscriptConsolidatorTests: XCTestCase {

    private func result(_ text: String, _ start: Int64, _ end: Int64,
                        volatile: Bool = false) -> TranscriptResult {
        TranscriptResult(text: text,
                         range: FrameRange(start: start, end: end),
                         isVolatile: volatile,
                         confidence: nil)
    }

    func testFinalResultsCommitInFrameOrderNotArrivalOrder() {
        var c = TranscriptConsolidator()
        c.apply(result("third", 200, 300))
        c.apply(result("first", 0, 100))
        c.apply(result("second", 100, 200))
        XCTAssertEqual(c.committedText, "first second third")
    }

    /// The load-bearing rule: nothing that arrived volatile may end up committed.
    func testVolatileResultIsNeverCommitted() {
        var c = TranscriptConsolidator()
        c.apply(result("maybe", 0, 100, volatile: true))
        XCTAssertTrue(c.committed.isEmpty)
        XCTAssertEqual(c.committedText, "")
        XCTAssertEqual(c.displayText, "maybe")
    }

    func testEmptyVolatileRevokesItsRange() {
        var c = TranscriptConsolidator()
        c.apply(result("misheard", 0, 100, volatile: true))
        XCTAssertEqual(c.displayText, "misheard")

        c.apply(result("", 0, 100, volatile: true))
        XCTAssertEqual(c.displayText, "", "an empty volatile withdraws the hypothesis")
        XCTAssertTrue(c.provisional.isEmpty)
    }

    func testVolatileIsSupersededByAnOverlappingFinal() {
        var c = TranscriptConsolidator()
        c.apply(result("helo wrld", 0, 200, volatile: true))
        c.apply(result("hello world", 0, 200))
        XCTAssertEqual(c.committedText, "hello world")
        XCTAssertEqual(c.displayText, "hello world")
        XCTAssertTrue(c.provisional.isEmpty)
    }

    func testLaterFinalRevisesAnOverlappingCommittedResult() {
        var c = TranscriptConsolidator()
        c.apply(result("teh", 0, 100))
        c.apply(result("the", 0, 100))
        XCTAssertEqual(c.committed.count, 1)
        XCTAssertEqual(c.committedText, "the")
    }

    /// Half-open ranges: `[0,100)` and `[100,200)` touch but do not overlap, so the
    /// second must not evict the first.
    func testAdjacentRangesCoexist() {
        var c = TranscriptConsolidator()
        c.apply(result("one", 0, 100))
        c.apply(result("two", 100, 200))
        XCTAssertEqual(c.committed.count, 2)
        XCTAssertEqual(c.committedText, "one two")
    }

    func testEmptyFinalDeletesItsRangeWithoutLeavingAnEmptyRun() {
        var c = TranscriptConsolidator()
        c.apply(result("spurious", 0, 100))
        c.apply(result("", 0, 100))
        XCTAssertTrue(c.committed.isEmpty)
        XCTAssertEqual(c.committedText, "")
    }

    func testVolatileTailFollowsCommittedHead() {
        var c = TranscriptConsolidator()
        c.apply(result("settled", 0, 100))
        c.apply(result("guessing", 100, 200, volatile: true))
        XCTAssertEqual(c.committedText, "settled")
        XCTAssertEqual(c.displayText, "settled guessing")
    }

    func testANewVolatileReplacesTheOverlappingOldOne() {
        var c = TranscriptConsolidator()
        c.apply(result("hel", 0, 100, volatile: true))
        c.apply(result("hello", 0, 120, volatile: true))
        XCTAssertEqual(c.provisional.count, 1)
        XCTAssertEqual(c.displayText, "hello")
    }

    // MARK: Regressions found in review

    /// A zero-length final range overlaps nothing under a strict comparison, so it
    /// used to supersede nothing — leaving the hypothesis it was meant to promote on
    /// screen forever.
    func testAZeroLengthFinalStillSupersedesTheVolatileItLandsIn() {
        var c = TranscriptConsolidator()
        c.apply(result("guess", 0, 200, volatile: true))
        c.apply(result("actual", 100, 100))
        XCTAssertTrue(c.provisional.isEmpty, "the stale hypothesis must not survive")
        XCTAssertEqual(c.committedText, "actual")
    }

    func testAZeroLengthEmptyVolatileRevokesTheRangeItSitsIn() {
        var c = TranscriptConsolidator()
        c.apply(result("guess", 0, 200, volatile: true))
        c.apply(result("", 50, 50, volatile: true))
        XCTAssertEqual(c.displayText, "")
    }

    /// A provisional result whose range precedes committed text must render before it,
    /// not after — concatenating the two lists put it in the wrong place.
    func testDisplayTextIsOrderedByFrameNotByCommittedFirst() {
        var c = TranscriptConsolidator()
        c.apply(result("later", 1_000, 2_000))
        c.apply(result("earlier", 0, 500, volatile: true))
        XCTAssertEqual(c.displayText, "earlier later")
    }

    func testFrameRangeOverlap() {
        XCTAssertTrue(FrameRange(start: 0, end: 100).overlaps(FrameRange(start: 50, end: 150)))
        XCTAssertFalse(FrameRange(start: 0, end: 100).overlaps(FrameRange(start: 100, end: 200)))
        XCTAssertFalse(FrameRange(start: 100, end: 200).overlaps(FrameRange(start: 0, end: 100)))
        XCTAssertTrue(FrameRange(start: 0, end: 300).overlaps(FrameRange(start: 100, end: 200)))
    }

    // MARK: #118 §5 — runs with a provisional flag

    /// The seam the live transcript dims on is committed vs provisional — not "the tail".
    /// A hypothesis whose frames PRECEDE committed text sits in the middle of the ordered
    /// runs, flagged, with committed text after it. An implementation that dims the last
    /// run fails here; one that appends provisional after committed fails here.
    func testRunsFlagAProvisionalRunThatLandsMidText() {
        var c = TranscriptConsolidator()
        c.apply(result("later", 1_000, 2_000))
        c.apply(result("earlier", 0, 500, volatile: true))
        c.apply(result("last", 2_000, 3_000))
        XCTAssertEqual(c.runs.map(\.text), ["earlier", "later", "last"])
        XCTAssertEqual(c.runs.map(\.isProvisional), [true, false, false],
                       "the hypothesis is FIRST, not last — dimming the tail is wrong")
    }

    /// The ordinary shape too, so the flag is proven in both positions.
    func testRunsFlagATrailingHypothesis() {
        var c = TranscriptConsolidator()
        c.apply(result("settled", 0, 100))
        c.apply(result("guessing", 100, 200, volatile: true))
        XCTAssertEqual(c.runs.map(\.text), ["settled", "guessing"])
        XCTAssertEqual(c.runs.map(\.isProvisional), [false, true])
    }

    /// `displayText` is derived from `runs`, not computed alongside it — same words, same
    /// order, or the screen and the model disagree.
    func testDisplayTextIsTheJoinedRuns() {
        var c = TranscriptConsolidator()
        c.apply(result("later", 1_000, 2_000))
        c.apply(result("earlier", 0, 500, volatile: true))
        c.apply(result("", 300, 400, volatile: true))   // revokes "earlier"
        c.apply(result("middle", 500, 1_000, volatile: true))
        XCTAssertEqual(c.displayText, TranscriptText.join(c.runs.map(\.text)))
        XCTAssertEqual(c.runs.map(\.text), ["middle", "later"])
        XCTAssertEqual(c.runs.map(\.isProvisional), [true, false])
    }

    /// Promotion flips the flag without moving the run — and leaves a still-provisional
    /// run sitting BETWEEN two committed ones.
    ///
    /// The marker rides on a final result over a far range, not a zero-length one at a
    /// boundary: `FrameRange.supersededBy` treats a zero-length range at a neighbour's
    /// endpoint as contained, so a `[200,200)` final would evict `second` instead of
    /// leaving it provisional.
    func testPromotionFlipsTheFlagInPlace() {
        var c = TranscriptConsolidator()
        c.apply(result("first", 0, 100, volatile: true))
        c.apply(result("second", 100, 200, volatile: true))
        var third = result("third", 300, 400)
        third.finalizedThroughFrame = 100
        c.apply(third)
        XCTAssertEqual(c.runs.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(c.runs.map(\.isProvisional), [false, true, false],
                       "first was promoted, second is still a hypothesis, third arrived final")
    }
}
