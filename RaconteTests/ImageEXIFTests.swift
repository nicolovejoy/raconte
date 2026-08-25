import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Raconte

/// Task 2 (image capture plan): pure EXIF `capturedAt` reader — `DateTimeOriginal`
/// preferred, `DateTimeDigitized` as fallback, nil on anything else. EXIF's own date
/// format (`"yyyy:MM:dd HH:mm:ss"`), not ISO8601.
final class ImageEXIFTests: XCTestCase {

    private static let expected: Date = {
        var components = DateComponents()
        components.year = 2024; components.month = 3; components.day = 15
        components.hour = 10; components.minute = 30; components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    func testDateTimeOriginalIsPreferredAndParsedCorrectly() {
        let data = ImageThumbnailerTests.makeJPEG(width: 20, height: 20, color: (1, 2, 3), exif: [
            kCGImagePropertyExifDateTimeOriginal: "2024:03:15 10:30:00",
            kCGImagePropertyExifDateTimeDigitized: "1999:01:01 00:00:00",
        ])
        XCTAssertEqual(ImageEXIF.capturedAt(from: data), Self.expected)
    }

    func testDateTimeDigitizedIsUsedWhenOriginalAbsent() {
        let data = ImageThumbnailerTests.makeJPEG(width: 20, height: 20, color: (1, 2, 3), exif: [
            kCGImagePropertyExifDateTimeDigitized: "2024:03:15 10:30:00",
        ])
        XCTAssertEqual(ImageEXIF.capturedAt(from: data), Self.expected)
    }

    func testNoExifDateReturnsNil() {
        let data = ImageThumbnailerTests.makeJPEG(width: 20, height: 20, color: (1, 2, 3))
        XCTAssertNil(ImageEXIF.capturedAt(from: data))
    }

    func testNonImageBytesReturnNil() {
        XCTAssertNil(ImageEXIF.capturedAt(from: Data("not an image".utf8)))
    }
}
