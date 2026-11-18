import XCTest
import SwiftUI
@testable import Raconte

/// #121: the two pure layout rules `ImageFramingView` leans on. The view itself is
/// exercised by `ImageCaptureUITests` (Task 8); nothing here instantiates SwiftUI.
final class ImageFramingViewTests: XCTestCase {

    func testFittedRectLetterboxesALandscapeImageInAPortraitContainer() {
        let r = ImageFramingLayout.fittedImageRect(imageSize: CGSize(width: 200, height: 100),
                                                   in: CGSize(width: 100, height: 300))
        XCTAssertEqual(r.width, 100, accuracy: 1e-9)
        XCTAssertEqual(r.height, 50, accuracy: 1e-9)
        XCTAssertEqual(r.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(r.midY, 150, accuracy: 1e-9, "centred vertically")
    }

    func testFittedRectPillarboxesAPortraitImageInALandscapeContainer() {
        let r = ImageFramingLayout.fittedImageRect(imageSize: CGSize(width: 100, height: 200),
                                                   in: CGSize(width: 300, height: 100))
        XCTAssertEqual(r.height, 100, accuracy: 1e-9)
        XCTAssertEqual(r.width, 50, accuracy: 1e-9)
        XCTAssertEqual(r.midX, 150, accuracy: 1e-9)
    }

    func testFittedRectOfAZeroSizeIsEmptyNotNaN() {
        let r = ImageFramingLayout.fittedImageRect(imageSize: .zero, in: CGSize(width: 100, height: 100))
        XCTAssertFalse(r.width.isNaN); XCTAssertFalse(r.height.isNaN)
        XCTAssertEqual(r.width, 0)
    }

    // MARK: - #201 margins: the handles stay off the edge of the screen

    private let margins = EdgeInsets(top: 24, leading: 60, bottom: 60, trailing: 60)

    /// A wide image is limited by the width: it must stop at the side margins, not at the
    /// container's edges, and sit centred in the space the margins leave.
    func testFittedRectOfAWideImageStopsAtTheSideMargins() {
        let r = ImageFramingLayout.fittedImageRect(imageSize: CGSize(width: 200, height: 100),
                                                   in: CGSize(width: 400, height: 800), margins: margins)
        XCTAssertEqual(r.minX, 60, accuracy: 1e-9)
        XCTAssertEqual(r.maxX, 340, accuracy: 1e-9)
        XCTAssertEqual(r.height, 140, accuracy: 1e-9, "aspect kept")
        XCTAssertEqual(r.midY, (24 + 740) / 2, accuracy: 1e-9, "centred between the top and bottom margins")
    }

    /// A tall image is limited by the height: it must stop at the top and bottom margins.
    func testFittedRectOfATallImageStopsAtTheTopAndBottomMargins() {
        let r = ImageFramingLayout.fittedImageRect(imageSize: CGSize(width: 100, height: 400),
                                                   in: CGSize(width: 400, height: 800), margins: margins)
        XCTAssertEqual(r.minY, 24, accuracy: 1e-9)
        XCTAssertEqual(r.maxY, 740, accuracy: 1e-9)
        XCTAssertEqual(r.width, 179, accuracy: 1e-9, "aspect kept")
        XCTAssertEqual(r.midX, (60 + 340) / 2, accuracy: 1e-9, "centred between the side margins")
    }

    /// Margins that leave no room (a tiny window) give an empty rect, never a negative one.
    func testFittedRectWithMarginsLargerThanTheContainerIsEmpty() {
        let r = ImageFramingLayout.fittedImageRect(imageSize: CGSize(width: 100, height: 100),
                                                   in: CGSize(width: 100, height: 50), margins: margins)
        XCTAssertEqual(r.width, 0); XCTAssertEqual(r.height, 0)
        XCTAssertFalse(r.minX.isNaN); XCTAssertFalse(r.minY.isNaN)
    }

    /// Owner rule (#201): handles at least 3/8 inch inside the edge of the screen. An iPhone
    /// is about 153 pt to the inch, so 3/8 inch is about 57.4 pt. The top is exempt: the
    /// container starts below the navigation bar, already far from the screen's edge, and
    /// needs only room for the handle's hit target.
    func testTouchMarginsKeepTheHandlesThreeEighthsOfAnInchFromTheSidesAndBottom() {
        let threeEighthsInch = 0.375 * 153.0
        let m = ImageFramingLayout.touchMargins
        XCTAssertGreaterThanOrEqual(m.leading, threeEighthsInch)
        XCTAssertGreaterThanOrEqual(m.trailing, threeEighthsInch)
        XCTAssertGreaterThanOrEqual(m.bottom, threeEighthsInch)
        XCTAssertGreaterThanOrEqual(m.top, ImageFramingLayout.handleHitSize / 2)
    }

    /// With a pointer there is no finger to make room for, but a handle centred on the
    /// image's edge must still lie wholly inside the window.
    func testPointerMarginsKeepTheWholeHandleInsideTheWindow() {
        let m = ImageFramingLayout.pointerMargins
        for side in [m.top, m.leading, m.bottom, m.trailing] {
            XCTAssertGreaterThanOrEqual(side, ImageFramingLayout.handleHitSize / 2)
        }
    }

    func testUnitDeltaDividesByTheLaidOutImageSize() {
        let d = ImageFramingLayout.unitDelta(CGSize(width: 50, height: -25),
                                             in: CGRect(x: 10, y: 10, width: 200, height: 100))
        XCTAssertEqual(d.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(d.height, -0.25, accuracy: 1e-9)
    }

    func testUnitDeltaOverAnEmptyRectIsZero() {
        let d = ImageFramingLayout.unitDelta(CGSize(width: 50, height: 50), in: .zero)
        XCTAssertEqual(d, .zero)
    }
}
