import XCTest
@testable import Raconte

final class CropInteractionTests: XCTestCase {
    private let a = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    private let b = CGRect(x: 0.2, y: 0.1, width: 0.8, height: 0.8)   // `a` after some drag
    private let c = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)   // after some pinch
    private let p1 = CGPoint(x: 100, y: 100)
    private let p2 = CGPoint(x: 240, y: 300)
    private let p3 = CGPoint(x: 60, y: 420)

    func testADragAppliesToTheRectItStartedFrom() {
        var i = CropInteraction()
        XCTAssertEqual(i.dragChanged(from: p1, current: a), a)
        XCTAssertEqual(i.dragChanged(from: p1, current: b), a, "later updates keep the start, not the live rect")
    }

    func testAPinchAppliesToTheRectItStartedFrom() {
        var i = CropInteraction()
        XCTAssertEqual(i.pinchChanged(current: a), a)
        XCTAssertEqual(i.pinchChanged(current: c), a)
    }

    func testAPinchStartsFromTheLiveRectAndSilencesTheDrag() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)
        XCTAssertEqual(i.pinchChanged(current: b), b, "the pinch scales the rectangle as it is, never a remembered one")
        XCTAssertNil(i.dragChanged(from: p1, current: b), "the drag is ignored while the pinch runs")
    }

    func testADragThatBeginsDuringAPinchIsIgnored() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        XCTAssertNil(i.dragChanged(from: p1, current: a))
    }

    func testTheDragThatLostToAPinchStaysIgnoredUntilItEnds() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)
        _ = i.pinchChanged(current: b)
        i.pinchEnded()
        XCTAssertNil(i.dragChanged(from: p1, current: c), "its translation predates the pinch; applying it would jump")
        i.dragEnded(from: p1)
        XCTAssertEqual(i.dragChanged(from: p1, current: c), c, "a new drag from the same point works once the old one ended")
    }

    func testBothFingersOfAPinchStayIgnoredAfterIt() {
        // Two fingers on two handles: two drags, both silenced by the pinch.
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        XCTAssertNil(i.dragChanged(from: p1, current: a))
        XCTAssertNil(i.dragChanged(from: p2, current: a))
        i.pinchEnded()
        XCTAssertNil(i.dragChanged(from: p1, current: c))
        XCTAssertNil(i.dragChanged(from: p2, current: c), "the second ignored drag must not be forgotten")
        i.dragEnded(from: p1)
        XCTAssertNil(i.dragChanged(from: p2, current: c), "ending one finger does not revive the other")
    }

    func testANewDragAfterAPinchStartsFromTheScaledRect() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        i.pinchEnded()
        XCTAssertEqual(i.dragChanged(from: p2, current: c), c)
    }

    func testASecondFingerOnAnotherHandleTakesOverAndTheFirstIsIgnored() {
        var i = CropInteraction()
        XCTAssertEqual(i.dragChanged(from: p1, current: a), a)
        XCTAssertEqual(i.dragChanged(from: p2, current: b), b, "the newer drag starts from the live rect")
        XCTAssertNil(i.dragChanged(from: p1, current: c), "the displaced drag is never re-based")
        XCTAssertEqual(i.dragChanged(from: p2, current: c), b)
    }

    func testEndingAnIgnoredDragLeavesTheOwnerAlone() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)
        _ = i.dragChanged(from: p2, current: b)
        i.dragEnded(from: p1)
        XCTAssertEqual(i.dragChanged(from: p2, current: c), b)
    }

    func testADragThatNeverEndedBlocksNeitherTheNextDragNorTheNextPinch() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)   // cancelled: dragEnded never arrives; the rect is now b
        XCTAssertEqual(i.dragChanged(from: p2, current: b), b)
        i.dragEnded(from: p2)
        XCTAssertEqual(i.pinchChanged(current: c), c, "a pinch never returns to a dead drag's start")
    }

    func testAnIgnoredDragThatNeverEndedDoesNotBlockTheNextDrag() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        XCTAssertNil(i.dragChanged(from: p1, current: a))
        i.pinchEnded()                            // the ignored drag is cancelled, no dragEnded
        XCTAssertEqual(i.dragChanged(from: p3, current: c), c)
    }

    func testASecondPinchStartsFromTheLiveRect() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        i.pinchEnded()
        XCTAssertEqual(i.pinchChanged(current: c), c)
    }
}
