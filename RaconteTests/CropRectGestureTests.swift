import XCTest
@testable import Raconte

/// #121: the drag math behind `ImageFramingView`'s crop rectangle, in unit space. Pinned
/// here so clamping is a tested rule, not something eyeballed on a simulator.
final class CropRectGestureTests: XCTestCase {

    private let quarter = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    func testMoveSlidesWithoutResizing() {
        let moved = CropRectGesture.moved(quarter, by: CGSize(width: 0.1, height: -0.1))
        XCTAssertEqual(moved.minX, 0.35, accuracy: 1e-9)
        XCTAssertEqual(moved.minY, 0.15, accuracy: 1e-9)
        XCTAssertEqual(moved.size, quarter.size)
    }

    func testMoveStopsAtTheBounds() {
        let moved = CropRectGesture.moved(quarter, by: CGSize(width: 5, height: 5))
        XCTAssertEqual(moved.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.size, quarter.size, "a move never changes the size, even at the edge")
    }

    func testResizingTheRightEdgeMovesOnlyThatEdge() {
        let resized = CropRectGesture.resized(quarter, handle: .right, by: CGSize(width: 0.1, height: 0.3))
        XCTAssertEqual(resized.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(resized.maxX, 0.85, accuracy: 1e-9)
        XCTAssertEqual(resized.minY, 0.25, accuracy: 1e-9)
        XCTAssertEqual(resized.maxY, 0.75, accuracy: 1e-9, "an edge handle ignores the perpendicular delta")
    }

    func testResizingACornerMovesBothOfItsEdges() {
        let resized = CropRectGesture.resized(quarter, handle: .topLeft, by: CGSize(width: -0.1, height: -0.1))
        XCTAssertEqual(resized.minX, 0.15, accuracy: 1e-9)
        XCTAssertEqual(resized.minY, 0.15, accuracy: 1e-9)
        XCTAssertEqual(resized.maxX, 0.75, accuracy: 1e-9)
        XCTAssertEqual(resized.maxY, 0.75, accuracy: 1e-9)
    }

    func testResizeStopsAtTheBounds() {
        let resized = CropRectGesture.resized(quarter, handle: .bottomRight, by: CGSize(width: 2, height: 2))
        XCTAssertEqual(resized.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(resized.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(resized.minX, 0.25, accuracy: 1e-9)
    }

    func testResizeNeverInvertsAndStopsAtTheMinimumSide() {
        // Dragging the left edge far past the right edge.
        let resized = CropRectGesture.resized(quarter, handle: .left, by: CGSize(width: 0.9, height: 0))
        XCTAssertEqual(resized.width, ImageFraming.minimumSide, accuracy: 1e-9)
        XCTAssertEqual(resized.maxX, 0.75, accuracy: 1e-9, "the opposite edge stays put")
        XCTAssertGreaterThan(resized.width, 0)
    }

    func testResizeResultIsAlwaysClamped() {
        for handle in CropHandle.allCases {
            let r = CropRectGesture.resized(quarter, handle: handle, by: CGSize(width: -3, height: 3))
            XCTAssertEqual(r, ImageFraming.clamped(r), "\(handle)")
        }
    }
}
