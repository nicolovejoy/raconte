import XCTest
import CoreGraphics
import ImageIO
@testable import Raconte

/// #181: a camera shot's metadata survives the JPEG encode. `UIImage.jpegData` threw
/// the picker's `mediaMetadata` away, so `ImageEXIF.capturedAt` was nil for every
/// camera photo and the backdate suggestion only ever fired from library picks.
final class CameraJPEGTests: XCTestCase {

    private static let expected: Date = {
        var components = DateComponents()
        components.year = 2024; components.month = 3; components.day = 15
        components.hour = 10; components.minute = 30; components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private func image(width: Int = 24, height: Int = 16) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The picker's `mediaMetadata` shape: nested `{Exif}` / `{TIFF}` dictionaries.
    private func cameraMetadata(tiffOrientation: Int = 1) -> [CFString: Any] {
        [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:03:15 10:30:00",
                kCGImagePropertyExifDateTimeDigitized: "2024:03:15 10:30:00",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFOrientation: tiffOrientation,
            ] as [CFString: Any],
        ]
    }

    private func properties(of data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    func testCaptureDateSurvivesTheEncode() throws {
        let data = try XCTUnwrap(CameraJPEG.encode(image: image(), orientation: .up,
                                                   metadata: cameraMetadata()))
        XCTAssertEqual(ImageEXIF.capturedAt(from: data), Self.expected,
                       "the camera's DateTimeOriginal must reach the bytes the store reads")
        let tiff = properties(of: data)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "Apple",
                       "the whole metadata set is carried, not just the date")
    }

    func testNoMetadataStillEncodesAValidJPEGWithNoDate() throws {
        let data = try XCTUnwrap(CameraJPEG.encode(image: image(width: 24, height: 16),
                                                   orientation: .up, metadata: nil))
        XCTAssertNil(ImageEXIF.capturedAt(from: data))
        let props = properties(of: data)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 24)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 16)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
    }

    /// `UIImage.cgImage` is the raw sensor bitmap; the picker's orientation is what
    /// makes a portrait shot display as portrait. It has to be written, and it has to
    /// win over whatever the camera metadata's own `{TIFF}` Orientation says, or a
    /// reader honouring one tag and a reader honouring the other disagree.
    func testPickerOrientationIsWrittenAndOverridesStaleTIFFOrientation() throws {
        let data = try XCTUnwrap(CameraJPEG.encode(image: image(), orientation: .right,
                                                   metadata: cameraMetadata(tiffOrientation: 1)))
        let props = properties(of: data)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? UInt32, CGImagePropertyOrientation.right.rawValue)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFOrientation] as? UInt32, CGImagePropertyOrientation.right.rawValue)
    }

    func testOrientationIsWrittenWithoutAnyMetadata() throws {
        let data = try XCTUnwrap(CameraJPEG.encode(image: image(), orientation: .left, metadata: nil))
        XCTAssertEqual(properties(of: data)[kCGImagePropertyOrientation] as? UInt32,
                       CGImagePropertyOrientation.left.rawValue)
    }
}
