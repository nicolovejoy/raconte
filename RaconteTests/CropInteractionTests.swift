import XCTest
@testable import Raconte

final class CropInteractionTests: XCTestCase {
    private let a = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    private let b = CGRect(x: 0.2, y: 0.1, width: 0.8, height: 0.8)   // `a` after some drag
    private let c = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)   // after some pinch
    private let p1 = CGPoint(x: 100, y: 100)
    private let p2 = CGPoint(x: 240, y: 300)

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

    func testAPinchTakesOverFromADragAndReturnsToTheDragsStart() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)
        XCTAssertEqual(i.pinchChanged(current: b), a, "the pinch scales from where the drag began")
        XCTAssertNil(i.dragChanged(from: p1, current: b), "the drag is ignored while the pinch runs")
    }

    func testADragThatBeginsDuringAPinchIsIgnored() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        XCTAssertNil(i.dragChanged(from: p1, current: a))
    }

    func testTheDragThatLostToAPinchStaysIgnoredAfterThePinchEnds() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)
        _ = i.pinchChanged(current: b)
        i.pinchEnded()
        XCTAssertNil(i.dragChanged(from: p1, current: c), "its translation predates the pinch; applying it would jump")
        i.dragEnded()
        XCTAssertEqual(i.dragChanged(from: p1, current: c), c, "a new drag from the same point works once the old one ended")
    }

    func testANewDragAfterAPinchStartsFromTheScaledRect() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        i.pinchEnded()
        XCTAssertEqual(i.dragChanged(from: p2, current: c), c)
    }

    func testADragThatNeverEndedDoesNotBlockTheNextDrag() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)   // cancelled: dragEnded() never arrives
        XCTAssertEqual(i.dragChanged(from: p2, current: b), b)
    }

    func testAnIgnoredDragThatNeverEndedDoesNotBlockTheNextDrag() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        XCTAssertNil(i.dragChanged(from: p1, current: a))
        i.pinchEnded()                            // the ignored drag is cancelled, no dragEnded()
        XCTAssertEqual(i.dragChanged(from: p2, current: c), c)
    }

    func testASecondPinchStartsFromTheLiveRect() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        i.pinchEnded()
        XCTAssertEqual(i.pinchChanged(current: c), c)
    }
}
