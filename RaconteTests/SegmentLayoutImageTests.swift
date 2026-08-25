import XCTest
@testable import Raconte

final class SegmentLayoutImageTests: XCTestCase {
    private let captureDirectory = URL(fileURLWithPath: "/tmp/captures/cap-1", isDirectory: true)
    private let imageID = "img-42"

    func testImagesDirectory() {
        XCTAssertEqual(
            SegmentLayout.imagesDirectory(captureDirectory: captureDirectory).path,
            captureDirectory.appendingPathComponent("images", isDirectory: true).path)
    }

    func testImageThumbnailsDirectory() {
        XCTAssertEqual(
            SegmentLayout.imageThumbnailsDirectory(captureDirectory: captureDirectory).path,
            captureDirectory.appendingPathComponent("images", isDirectory: true)
                .appendingPathComponent("thumbnails", isDirectory: true).path)
    }

    func testImageOriginalURL() {
        XCTAssertEqual(
            SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory, imageID: imageID, ext: "heic").path,
            captureDirectory.appendingPathComponent("images", isDirectory: true)
                .appendingPathComponent("img-42.heic").path)
    }

    func testImageOriginalURLUsesGivenExtensionVerbatim() {
        XCTAssertEqual(
            SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory, imageID: imageID, ext: "png").path,
            captureDirectory.appendingPathComponent("images", isDirectory: true)
                .appendingPathComponent("img-42.png").path)
    }

    func testImageSidecarURL() {
        XCTAssertEqual(
            SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: imageID).path,
            captureDirectory.appendingPathComponent("images", isDirectory: true)
                .appendingPathComponent("img-42.json").path)
    }

    func testImageThumbnailURL() {
        XCTAssertEqual(
            SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: imageID).path,
            captureDirectory.appendingPathComponent("images", isDirectory: true)
                .appendingPathComponent("thumbnails", isDirectory: true)
                .appendingPathComponent("img-42.jpg").path)
    }

    /// The thumbnail is always a `.jpg`, regardless of the original's format — a
    /// generated re-encode, not a copy.
    func testImageThumbnailURLAlwaysEndsInJpgRegardlessOfOriginalExtension() {
        for ext in ["heic", "png", "gif", "tiff", "webp"] {
            let original = SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory, imageID: imageID, ext: ext)
            XCTAssertFalse(original.path.hasSuffix(".jpg"))
            let thumbnail = SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: imageID)
            XCTAssertTrue(thumbnail.path.hasSuffix(".jpg"), "expected .jpg thumbnail for original ext \(ext)")
        }
    }
}
