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

    // MARK: Pinch (#203)

    private func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 1e-9, file: file, line: line)
    }

    func testPinchGrowsAndShrinksAroundTheCentre() {
        assertRect(CropRectGesture.scaled(quarter, by: 1.2), 0.2, 0.2, 0.6, 0.6)
        assertRect(CropRectGesture.scaled(quarter, by: 0.5), 0.375, 0.375, 0.25, 0.25)
    }

    func testPinchKeepsTheShapeOfANonSquareRectangle() {
        // 0.4 x 0.8 is 1:2. The height fills the photo at 1.25x, so growth stops there.
        assertRect(CropRectGesture.scaled(CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.8), by: 2),
                   0.05, 0, 0.5, 1)
    }

    func testPinchOutStopsWhenASideFillsThePhoto() {
        assertRect(CropRectGesture.scaled(quarter, by: 10), 0, 0, 1, 1)
    }

    func testPinchOutAgainstAnEdgeSlidesToKeepGrowing() {
        assertRect(CropRectGesture.scaled(CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5), by: 1.5),
                   0, 0.125, 0.75, 0.75)
    }

    func testPinchInStopsWhenTheShorterSideReachesTheMinimum() {
        assertRect(CropRectGesture.scaled(quarter, by: 0.01), 0.45, 0.45, 0.1, 0.1)
        // 0.2 x 0.6: the width reaches 0.1 at 0.5x, so the height stops at 0.3.
        assertRect(CropRectGesture.scaled(CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.6), by: 0.1),
                   0.25, 0.35, 0.1, 0.3)
    }

    func testPinchWithANonsenseMagnificationChangesNothing() {
        for bad in [0, -1, CGFloat.nan, CGFloat.infinity] {
            XCTAssertEqual(CropRectGesture.scaled(quarter, by: bad), quarter, "\(bad)")
        }
    }
}
