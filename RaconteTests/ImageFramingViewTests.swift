import XCTest
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
