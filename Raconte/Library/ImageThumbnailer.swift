import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Pure re-encode-to-JPEG-thumbnail seam (image capture plan Task 2), lifted from
/// `JournalCoverStore.reencode`'s technique — `CGImageSourceCreateThumbnailAtIndex`
/// decodes directly at the target size rather than materializing a full-resolution
/// bitmap first, and `kCGImageSourceCreateThumbnailWithTransform: true` bakes in the
/// EXIF orientation correction so the output's pixel dimensions are always the
/// as-displayed ones, never the raw stored ones.
///
/// Returns `nil` on any failure instead of throwing, unlike `JournalCoverStore
/// .reencode`: thumbnail generation is a nice-to-have derived from the original, and
/// per the design doc's degrade-never-skip rule a failed thumbnail must never fail the
/// image add itself. `ImageStore.addImage` treats a nil result here as "leave the
/// thumbnail file absent" — see that type's doc comment for why absence, not a sidecar
/// flag, is the chosen "needs regen" signal.
enum ImageThumbnailer {
    static func generate(from data: Data, longEdge: CGFloat = 512, quality: CGFloat = 0.7) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
