import XCTest
@testable import Raconte

/// #121 entry point (c): the one decision between the framing view's Use and the "Replace
/// the original?" confirmation, pinned pure. Identity → nothing (no dialog, no write);
/// a real framing → confirm with the framed bytes; a framing that cannot be applied → nothing
/// (the viewer shows the alert; never a confirmation for bytes that do not exist).
final class ImageFullScreenViewerCropTests: XCTestCase {

    private let original = ImageThumbnailerTests.makePNG(width: 2, height: 1, color: (255, 0, 0))

    func testIdentityFramingDoesNothing() {
        XCTAssertEqual(ImageFullScreenViewer.cropOutcome(framing: .identity, original: original), .nothing)
    }

    func testARealFramingAsksToReplaceWithTheFramedBytes() throws {
        let outcome = ImageFullScreenViewer.cropOutcome(
            framing: ImageFraming(rotationQuarterTurns: 1, cropRect: .unit), original: original)
        guard case .confirmReplace(let framed) = outcome else { return XCTFail("expected confirmReplace, got \(outcome)") }
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: framed))
        XCTAssertEqual(size.width, 1); XCTAssertEqual(size.height, 2)
    }

    func testAFramingThatCannotBeAppliedDoesNothing() {
        XCTAssertEqual(ImageFullScreenViewer.cropOutcome(
            framing: ImageFraming(rotationQuarterTurns: 1, cropRect: .unit), original: Data("junk".utf8)), .nothing)
    }
}
