import Foundation
import CoreGraphics
import ImageIO

/// Pure EXIF-capture-date reader (image capture plan Task 2). `DateTimeOriginal` is
/// preferred — "when the shutter fired" — with `DateTimeDigitized` ("when the file was
/// created", e.g. a scan) as fallback for cameras/scanners that only populate the
/// latter. Neither tag carries a timezone offset in ordinary EXIF, so the parse treats
/// the string as UTC — an approximation (the true instant depends on where the photo
/// was taken), same tradeoff every plain EXIF reader makes without a separate
/// `OffsetTimeOriginal` tag.
enum ImageEXIF {
    static func capturedAt(from data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }

        let dateString = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
        guard let dateString else { return nil }
        return Self.formatter().date(from: dateString)
    }

    // EXIF's own date format — NOT ISO8601: "yyyy:MM:dd HH:mm:ss". Fresh formatter per
    // call, matching `CaptureCoding`'s rationale: `DateFormatter` is non-Sendable, so a
    // shared `static let` is rejected under strict concurrency.
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }
}
