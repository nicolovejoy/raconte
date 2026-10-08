import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Raconte

/// #121: the pure framing core. Every rule the view and the model lean on is pinned here
/// with synthetic images, so it needs no camera and no simulator.
final class ImageFramingTests: XCTestCase {

    // MARK: Fixtures

    /// A 32×16 image: left half red, right half blue. (Not 2×1: JPEG chroma subsampling blends
    /// neighbouring pixels, so a 1-pixel red/blue pair comes back purple and no rotation could pass.) Returned as PNG unless `jpegProperties`
    /// is given, in which case a JPEG carrying those properties (EXIF date, orientation…).
    private func redBlue(jpegProperties: [CFString: Any]? = nil, space: CGColorSpace? = nil) -> Data {
        let image = Self.redBlueImage(space: space)
        let output = NSMutableData()
        let type = jpegProperties == nil ? UTType.png : UTType.jpeg
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, jpegProperties as CFDictionary?)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func redBlueImage(space: CGColorSpace? = nil) -> CGImage {
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 16, y: 0, width: 16, height: 16))
        return context.makeImage()!
    }

    /// RGB of the pixel at (x, y) with y DOWN (row 0 is the top row), read through a fresh
    /// RGBA8 context so the source's own pixel format does not matter.
    static func rgb(of data: Data, x: Int, y: Int) -> (UInt8, UInt8, UInt8)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return (buffer[i], buffer[i + 1], buffer[i + 2])
    }

    /// RGB at a FRACTION of the image (0…1, y down) — the centre of a quadrant, clear of the
    /// JPEG chroma bleed at colour edges.
    static func rgb(of data: Data, fx: Double, fy: Double) -> (UInt8, UInt8, UInt8)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return rgb(of: data, x: min(image.width - 1, Int(fx * Double(image.width))),
                   y: min(image.height - 1, Int(fy * Double(image.height))))
    }

    private func isRed(_ p: (UInt8, UInt8, UInt8)?) -> Bool { p.map { $0.0 > 200 && $0.2 < 60 } ?? false }
    private func isBlue(_ p: (UInt8, UInt8, UInt8)?) -> Bool { p.map { $0.2 > 200 && $0.0 < 60 } ?? false }

    private func tiffOrientation(of data: Data) -> UInt32? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] else { return nil }
        return tiff[kCGImagePropertyTIFFOrientation] as? UInt32
    }

    private func colorSpaceName(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.colorSpace?.name as String?
    }

    private func exifPixelX(of data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        return exif[kCGImagePropertyExifPixelXDimension] as? Int
    }

    private func orientation(of data: Data) -> UInt32? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyOrientation] as? UInt32
    }

    // MARK: Identity

    func testIdentityIsByteIdenticalAndIsIdentity() {
        let data = redBlue()
        XCTAssertTrue(ImageFraming.identity.isIdentity)
        XCTAssertEqual(ImageFraming.identity.apply(to: data), data, "identity must not re-encode")
    }

    func testFourTurnsAndAFullRectIsIdentity() {
        let framing = ImageFraming(rotationQuarterTurns: 4, cropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(framing.normalisedTurns, 0)
        XCTAssertTrue(framing.isIdentity)
    }

    // MARK: Rotate

    func testOneClockwiseTurnSwapsDimensionsAndPutsTheLeftEdgeOnTop() throws {
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: redBlue()))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 16); XCTAssertEqual(size.height, 32)
        XCTAssertTrue(isRed(Self.rgb(of: out, fx: 0.5, fy: 0.25)), "left (red) becomes top after a clockwise turn")
        XCTAssertTrue(isBlue(Self.rgb(of: out, fx: 0.5, fy: 0.75)))
    }

    func testThreeTurnsIsOneCounterClockwiseTurn() throws {
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 3, cropRect: .unit).apply(to: redBlue()))
        XCTAssertTrue(isBlue(Self.rgb(of: out, fx: 0.5, fy: 0.25)), "left (red) becomes BOTTOM after a counter-clockwise turn")
        XCTAssertTrue(isRed(Self.rgb(of: out, fx: 0.5, fy: 0.75)))
    }

    func testRotatedAdvancesOneTurnAndResetsTheRect() {
        let framing = ImageFraming(rotationQuarterTurns: 3, cropRect: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        let next = framing.rotated()
        XCTAssertEqual(next.normalisedTurns, 0)
        XCTAssertEqual(next.cropRect, .unit)
    }

    // MARK: Crop

    func testCropKeepsOnlyTheRequestedUnitRect() throws {
        // Right half of [red|blue] is blue, 16×16.
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 0,
                                             cropRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)).apply(to: redBlue()))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 16); XCTAssertEqual(size.height, 16)
        XCTAssertTrue(isBlue(Self.rgb(of: out, fx: 0.5, fy: 0.5)))
    }

    func testCropIsAppliedAfterTheRotation() throws {
        // One clockwise turn gives [red on top, blue below]; the top half of THAT is red.
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1,
                                             cropRect: CGRect(x: 0, y: 0, width: 1, height: 0.5)).apply(to: redBlue()))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 16); XCTAssertEqual(size.height, 16)
        XCTAssertTrue(isRed(Self.rgb(of: out, fx: 0.5, fy: 0.5)))
    }

    func testClampedPullsAnOutOfBoundsRectInsideAndUpToTheMinimumSide() {
        let wild = ImageFraming.clamped(CGRect(x: -0.5, y: 0.9, width: 3, height: 0.01))
        XCTAssertEqual(wild.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(wild.maxX, 1, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(wild.height, ImageFraming.minimumSide - 1e-9)
        XCTAssertLessThanOrEqual(wild.maxY, 1 + 1e-9)
    }

    func testADegenerateRectIsTreatedAsFull() throws {
        // A rect that rounds to no pixels must fall back to the full image,
        // never return nil (a nil here would drop the owner's photo at the picker).
        // Needs a 2×1 source: on anything larger the minimum side (0.1) already yields real pixels.
        let tiny = ImageThumbnailerTests.makePNG(width: 2, height: 1, color: (255, 0, 0))
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .zero).apply(to: tiny))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 1); XCTAssertEqual(size.height, 2)
    }

    // MARK: Metadata and orientation

    func testEXIFDateSurvivesTheReencode() throws {
        let input = redBlue(jpegProperties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:03:15 10:30:00"] as [CFString: Any],
        ])
        let expected = try XCTUnwrap(ImageEXIF.capturedAt(from: input), "sanity: the fixture carries a date")
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: input))
        XCTAssertEqual(ImageEXIF.capturedAt(from: out), expected, "#191: a re-encode must keep the photo's own date")
    }

    func testOutputCarriesOrientationOneAndNoStalePixelDimensions() throws {
        let input = redBlue(jpegProperties: [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 32,
                                             kCGImagePropertyExifPixelYDimension: 16] as [CFString: Any],
        ])
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 2, cropRect: .unit).apply(to: input))
        XCTAssertEqual(orientation(of: out), CGImagePropertyOrientation.up.rawValue)
        XCTAssertEqual(tiffOrientation(of: out), CGImagePropertyOrientation.up.rawValue)
        // Two turns of the displayed 16×32 image keep it 16×32, so the stale source width (32)
        // is distinguishable. Sanity first: the input really carries 32.
        XCTAssertEqual(try XCTUnwrap(exifPixelX(of: input)), 32)
        XCTAssertNotEqual(try XCTUnwrap(exifPixelX(of: out)), 32, "the stale source width must not survive")
    }

    /// Review Focus 1. Orientation 6 (`.right`) means "rotate 90° CW to display": the 32×16
    /// [red|blue] bitmap DISPLAYS as 16×32 red-over-blue. One more clockwise turn of the DISPLAYED
    /// image gives 32×16 [blue|red], stored upright (orientation 1).
    func testOrientationSixSourceIsUprightedBeforeTheTurn() throws {
        let input = redBlue(jpegProperties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue])
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: input))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 32); XCTAssertEqual(size.height, 16)
        XCTAssertTrue(isBlue(Self.rgb(of: out, fx: 0.25, fy: 0.5)))
        XCTAssertTrue(isRed(Self.rgb(of: out, fx: 0.75, fy: 0.5)))
        XCTAssertEqual(orientation(of: out), CGImagePropertyOrientation.up.rawValue)
        XCTAssertEqual(tiffOrientation(of: out), CGImagePropertyOrientation.up.rawValue)
    }

    // MARK: Colour space

    func testDisplayP3SourceStaysDisplayP3AfterARotation() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let input = redBlue(jpegProperties: [:], space: p3)
        XCTAssertEqual(colorSpaceName(of: input), CGColorSpace.displayP3 as String, "sanity: the fixture is tagged P3")
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: input))
        XCTAssertEqual(colorSpaceName(of: out), CGColorSpace.displayP3 as String, "a rotate must not collapse P3 to DeviceRGB")
    }

    func testSRGBishSourceKeepsItsColorSpaceAfterARotation() throws {
        let input = redBlue(jpegProperties: [:])
        let before = try XCTUnwrap(colorSpaceName(of: input))
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: input))
        XCTAssertEqual(colorSpaceName(of: out), before, "the DeviceRGB fallback path must not change the space")
    }

    func testNonImageBytesReturnNil() {
        XCTAssertNil(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: Data("nope".utf8)))
    }
}

extension CGRect {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
}
