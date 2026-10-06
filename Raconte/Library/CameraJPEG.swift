import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// JPEG encode for a camera shot that KEEPS the camera's metadata (#181).
///
/// `UIImage.jpegData` re-encodes the pixels and nothing else: no `DateTimeOriginal`, no
/// `{TIFF}` make/model. `UIImagePickerController` hands the camera's metadata over
/// separately as `info[.mediaMetadata]`, so a camera shot only carries a date if this
/// encode writes it back — and `ImageEXIF.capturedAt` (hence the backdate suggestion on
/// add) reads nothing else. Pure CoreGraphics/ImageIO so it pins on macOS without a camera.
enum CameraJPEG {
    static func encode(image: CGImage,
                       orientation: CGImagePropertyOrientation,
                       metadata: [CFString: Any]?,
                       quality: Double = 0.9) -> Data? {
        var properties = metadata ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        // The picker's orientation is authoritative: `cgImage` is the raw sensor bitmap
        // and `imageOrientation` is how it displays. Set it at the top level AND inside
        // `{TIFF}` — the camera metadata carries its own Orientation there, and a stale
        // value would have one reader rotate the photo and another not.
        properties[kCGImagePropertyOrientation] = orientation.rawValue
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = orientation.rawValue
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
