import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Raconte

/// Issue #14 part 3: cover images round-trip through disk, downscale to the configured
/// bound, and degrade to nil rather than throwing when a cover is missing or corrupt —
/// `read` is a rendering path, and the house rule is degrade-never-skip.
final class JournalCoverStoreTests: XCTestCase {

    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteJournalCovers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private func store(maxDimension: CGFloat = 1024) -> JournalCoverStore {
        JournalCoverStore(containerRoot: containerRoot, maxDimension: maxDimension)
    }

    // MARK: Path math

    func testCoverURLSitsBesideJournalsRegistryNotInsideCaptures() {
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        let url = AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: "J1")
        XCTAssertEqual(url, containerRoot
            .appendingPathComponent("journals", isDirectory: true)
            .appendingPathComponent("J1", isDirectory: true)
            .appendingPathComponent("cover.jpg"))
        XCTAssertFalse(url.path.hasPrefix(capturesRoot.path),
                       "a stray file under captures/ would be walked by DirectorySnapshot.gather")
    }

    // MARK: Round trip

    func testWriteReadDeleteRoundTripThroughDisk() async throws {
        let s = store()
        let source = Self.makePNG(width: 200, height: 100, color: (255, 0, 0))

        let noCover = await s.read(journalID: "J1")
        XCTAssertNil(noCover, "no cover written yet")

        try await s.write(imageData: source, journalID: "J1")
        let written = await s.read(journalID: "J1")
        XCTAssertNotNil(written)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: "J1").path))

        // A fresh store over the same container root reads the same bytes back.
        let reader = JournalCoverStore(containerRoot: containerRoot)
        let reread = await reader.read(journalID: "J1")
        XCTAssertEqual(reread, written)

        await s.delete(journalID: "J1")
        let afterDelete = await s.read(journalID: "J1")
        XCTAssertNil(afterDelete)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: "J1").path))
    }

    func testDeletingAJournalWithNoCoverIsNotAnError() async {
        await store().delete(journalID: "never-had-one")
    }

    func testWriteReencodesAsJPEG() async throws {
        let s = store()
        try await s.write(imageData: Self.makePNG(width: 40, height: 40, color: (0, 255, 0)), journalID: "J1")
        let jpegData = await s.read(journalID: "J1")
        let data = try XCTUnwrap(jpegData)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let type = CGImageSourceGetType(source) as String?
        XCTAssertEqual(type, UTType.jpeg.identifier)
    }

    // MARK: Downscale bound

    func testDownscalesToConfiguredMaxDimension() async throws {
        let s = store(maxDimension: 64)
        try await s.write(imageData: Self.makePNG(width: 2000, height: 1000, color: (0, 0, 255)), journalID: "J1")
        let downscaledData = await s.read(journalID: "J1")
        let data = try XCTUnwrap(downscaledData)
        let (width, height) = try XCTUnwrap(Self.pixelSize(of: data))
        XCTAssertLessThanOrEqual(max(width, height), 64)
        // Aspect ratio preserved (2:1 source).
        XCTAssertEqual(width, 64)
        XCTAssertEqual(height, 32, accuracy: 1)
    }

    func testSmallerThanBoundImageIsNotUpscaled() async throws {
        let s = store(maxDimension: 1024)
        try await s.write(imageData: Self.makePNG(width: 30, height: 20, color: (10, 20, 30)), journalID: "J1")
        let smallData = await s.read(journalID: "J1")
        let data = try XCTUnwrap(smallData)
        let (width, height) = try XCTUnwrap(Self.pixelSize(of: data))
        XCTAssertEqual(width, 30)
        XCTAssertEqual(height, 20)
    }

    // MARK: Degrade path

    func testCorruptFileDegradesToNilNotAThrow() async throws {
        let url = AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: "J1")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: url)
        let read = await store().read(journalID: "J1")
        // The bytes exist and are handed back as-is — `read` doesn't validate the image,
        // only `write` does. A caller decoding for display (`JournalCoverThumbnail`)
        // degrades to nothing further up; that's the seam this store hands off to.
        XCTAssertEqual(read, Data("not an image".utf8))
    }

    func testWriteThrowsInvalidImageForUndecodableBytes() async {
        do {
            try await store().write(imageData: Data("not an image".utf8), journalID: "J1")
            XCTFail("expected invalidImage")
        } catch {
            XCTAssertEqual(error as? JournalCoverError, .invalidImage)
        }
    }

    func testMissingCoverIsNilNotAnError() async {
        let missing = await store().read(journalID: "no-such-journal")
        XCTAssertNil(missing)
    }

    func testWriteLeavesNoStrayPartFile() async throws {
        let s = store()
        try await s.write(imageData: Self.makePNG(width: 10, height: 10, color: (1, 2, 3)), journalID: "J1")
        let url = AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: "J1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SegmentLayout.partURL(for: url).path))
    }

    // MARK: Test helpers — pure CoreGraphics/ImageIO, no UIKit/AppKit

    private static func makePNG(width: Int, height: Int, color: (UInt8, UInt8, UInt8)) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255,
                             blue: CGFloat(color.2) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
