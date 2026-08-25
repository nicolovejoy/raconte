import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Raconte

/// Task 2 (image capture plan): pure re-encode-to-thumbnail seam, lifted from
/// `JournalCoverStore.reencode`'s technique but returning nil on failure instead of
/// throwing — thumbnail generation must never fail the image add itself.
final class ImageThumbnailerTests: XCTestCase {

    func testValidJPEGProducesNonNilJPEGOutputWithinLongEdge() throws {
        let source = Self.makeJPEG(width: 800, height: 400, color: (255, 0, 0))
        let thumbnail = try XCTUnwrap(ImageThumbnailer.generate(from: source, longEdge: 512))
        let type = try XCTUnwrap(Self.imageType(of: thumbnail))
        XCTAssertEqual(type, UTType.jpeg.identifier)
        let (width, height) = try XCTUnwrap(Self.pixelSize(of: thumbnail))
        XCTAssertLessThanOrEqual(max(width, height), 512)
    }

    func testValidPNGProducesNonNilJPEGOutput() throws {
        let source = Self.makePNG(width: 300, height: 300, color: (0, 255, 0))
        let thumbnail = try XCTUnwrap(ImageThumbnailer.generate(from: source, longEdge: 128))
        let type = try XCTUnwrap(Self.imageType(of: thumbnail))
        XCTAssertEqual(type, UTType.jpeg.identifier)
        let (width, height) = try XCTUnwrap(Self.pixelSize(of: thumbnail))
        XCTAssertLessThanOrEqual(max(width, height), 128)
    }

    func testGarbageBytesReturnsNil() {
        XCTAssertNil(ImageThumbnailer.generate(from: Data("not an image".utf8)))
    }

    /// Orientation 6 ("rotate 90 CW to display correctly") on a landscape 100x50 source:
    /// `kCGImageSourceCreateThumbnailWithTransform: true` must apply that correction, so
    /// the output's pixel dimensions are portrait (swapped), not the raw stored 100x50.
    func testRotatedFixtureOutputReflectsCorrectedOrientation() throws {
        let source = Self.makeJPEG(width: 100, height: 50, color: (0, 0, 255), orientation: 6)
        let thumbnail = try XCTUnwrap(ImageThumbnailer.generate(from: source, longEdge: 512))
        let (width, height) = try XCTUnwrap(Self.pixelSize(of: thumbnail))
        XCTAssertLessThan(width, height, "orientation-corrected output should be portrait, not the raw landscape storage")
    }

    // MARK: Test helpers — pure CoreGraphics/ImageIO, no UIKit/AppKit

    static func makeJPEG(width: Int, height: Int, color: (UInt8, UInt8, UInt8),
                          orientation: Int? = nil, exif: [CFString: Any]? = nil) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255,
                             blue: CGFloat(color.2) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func makePNG(width: Int, height: Int, color: (UInt8, UInt8, UInt8)) -> Data {
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

    static func imageType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
