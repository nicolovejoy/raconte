import XCTest
@testable import Raconte

/// T7 Mark Voices (issue #56) Task 6 — the drag gesture's pure math, fully unit-tested
/// so `VoiceMarkingView` itself can stay dumb (SwiftUI body rendering isn't reachable
/// from `RaconteTests`).
final class TokenSelectionTests: XCTestCase {

    // MARK: - tokenIndex

    func testTapHitTestFindsTheContainingTokenRect() {
        let frames: [(id: Int, rect: CGRect)] = [
            (id: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 16)),
            (id: 1, rect: CGRect(x: 24, y: 0, width: 20, height: 16)),
        ]
        let hit = TokenSelection.tokenIndex(at: CGPoint(x: 30, y: 8), frames: frames)
        XCTAssertEqual(hit, 1)
    }

    func testMissReturnsNil() {
        let frames: [(id: Int, rect: CGRect)] = [
            (id: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 16)),
        ]
        // Well outside even the 3pt vertical slop, and outside horizontally too.
        let hit = TokenSelection.tokenIndex(at: CGPoint(x: 500, y: 500), frames: frames)
        XCTAssertNil(hit)
    }

    /// Two overlapping rects both contain the point — the SMALLEST id wins,
    /// deterministically, rather than whichever `frames` happens to list last.
    func testTapHitTestPicksTheSmallestIDWhenRectsOverlap() {
        let frames: [(id: Int, rect: CGRect)] = [
            (id: 5, rect: CGRect(x: 0, y: 0, width: 20, height: 16)),
            (id: 2, rect: CGRect(x: 0, y: 0, width: 20, height: 16)),
        ]
        let hit = TokenSelection.tokenIndex(at: CGPoint(x: 10, y: 8), frames: frames)
        XCTAssertEqual(hit, 2)
    }

    /// A token rect is expanded 3pt vertically before the hit test — a drag that
    /// wanders slightly between two lines of wrapped text must still catch the token
    /// it's nearest to, rather than falling into the inter-line gap and losing the
    /// selection.
    func testVerticalSlopCatchesBetweenLineDrags() {
        let frames: [(id: Int, rect: CGRect)] = [
            (id: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 16)),
        ]
        // 2pt below the rect's bottom edge (16) — inside the 3pt vertical expansion,
        // outside the rect itself.
        let hit = TokenSelection.tokenIndex(at: CGPoint(x: 10, y: 18), frames: frames)
        XCTAssertEqual(hit, 0)

        // 4pt below — outside even the expanded rect.
        let miss = TokenSelection.tokenIndex(at: CGPoint(x: 10, y: 20), frames: frames)
        XCTAssertNil(miss)
    }

    // MARK: - selectedRange

    func testRangeIsOrderedRegardlessOfDragDirection() {
        let placeable = Set(0...10)
        let forward = TokenSelection.selectedRange(anchor: 2, current: 5, placeable: placeable)
        let backward = TokenSelection.selectedRange(anchor: 5, current: 2, placeable: placeable)
        XCTAssertEqual(forward, 2...5)
        XCTAssertEqual(backward, 2...5)
    }

    /// Endpoints clamp INWARD to the nearest placeable id inside the range — a drag
    /// that starts or ends on a non-placeable token (no timed frames) must not extend
    /// the mark to include it.
    func testEndpointsClampInwardToPlaceableTokens() {
        let placeable: Set<Int> = [1, 2, 3]
        let range = TokenSelection.selectedRange(anchor: 0, current: 4, placeable: placeable)
        XCTAssertEqual(range, 1...3)
    }

    /// A range containing no placeable token at all (e.g. dragging entirely across
    /// typed/unplaceable words) is nil — nothing here can be marked.
    func testRangeWithNoPlaceableTokenIsNil() {
        let placeable: Set<Int> = [10, 11]
        let range = TokenSelection.selectedRange(anchor: 0, current: 3, placeable: placeable)
        XCTAssertNil(range)
    }

    /// A single-token drag (anchor == current) that IS placeable resolves to a
    /// one-element range — the range machinery isn't only for multi-word drags.
    func testSingleTokenRangeResolvesWhenPlaceable() {
        let placeable: Set<Int> = [3]
        let range = TokenSelection.selectedRange(anchor: 3, current: 3, placeable: placeable)
        XCTAssertEqual(range, 3...3)
    }
}
