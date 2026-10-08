import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// #121: a framing — rotate in quarter turns, then crop — expressed independently of pixel
/// size and of how a view scaled its preview. `cropRect` is in UNIT coordinates (0…1) of
/// the ROTATED image, y down (origin top-left, the UI's convention and `CGImage.cropping`'s).
///
/// Pure ImageIO/CoreGraphics — no UIKit/AppKit, no platform `#if` — so it builds and pins on
/// macOS with synthetic images, the same rule `ImageStore`/`CameraJPEG` follow.
struct ImageFraming: Equatable, Sendable {
    var rotationQuarterTurns: Int
    var cropRect: CGRect

    static let identity = ImageFraming(rotationQuarterTurns: 0, cropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    /// Smallest crop side, in unit space — a rect thinner than this is useless and is where
    /// a drag handle crossing its opposite edge would otherwise invert the rect.
    static let minimumSide: CGFloat = 0.1

    /// `rotationQuarterTurns` folded into 0…3 (negative and ≥4 values included).
    var normalisedTurns: Int { ((rotationQuarterTurns % 4) + 4) % 4 }

    var isIdentity: Bool {
        normalisedTurns == 0 && Self.clamped(cropRect) == Self.identity.cropRect
    }

    /// One more clockwise quarter turn. The crop rect resets to the full image: a rect chosen
    /// against the previous orientation has no meaning against the new one.
    func rotated() -> ImageFraming {
        ImageFraming(rotationQuarterTurns: normalisedTurns + 1, cropRect: Self.identity.cropRect)
    }

    /// `rect` pulled inside the unit square and grown to `minimumSide` where it is thinner —
    /// the one clamp the view, the gesture helper and `apply` all share.
    static func clamped(_ rect: CGRect) -> CGRect {
        var r = rect.standardized
        r.size.width = min(max(r.width, minimumSide), 1)
        r.size.height = min(max(r.height, minimumSide), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }

    /// The rotated-then-cropped image as JPEG (quality 0.9), metadata carried through,
    /// orientation written as 1 (`.up`) because the pixels are now upright. Identity returns
    /// `data` byte-for-byte. nil only when `data` does not decode or the encode fails.
    func apply(to data: Data) -> Data? {
        if isIdentity { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        // Transform-applied decode: the bitmap comes out as it DISPLAYS, so the turn below is
        // relative to what the owner saw, not to the raw sensor orientation (Review Focus 1).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let rotated = Self.rotate(upright, quarterTurns: normalisedTurns) else { return nil }

        let cropped = Self.crop(rotated, unitRect: Self.clamped(cropRect)) ?? rotated

        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        // Geometry that described the SOURCE: ImageIO rewrites the top-level pair from the real
        // pixels, and a stale EXIF pixel dimension pair would lie about the output.
        metadata.removeValue(forKey: kCGImagePropertyPixelWidth)
        metadata.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        // `CameraJPEG.encode` writes the orientation top-level AND in `{TIFF}`.
        return CameraJPEG.encode(image: cropped, orientation: .up, metadata: metadata)
    }

    // MARK: Pixel steps

    /// `quarterTurns` clockwise turns (0…3) as a fresh bitmap. CoreGraphics' drawing space is
    /// y-up, where a positive angle is counter-clockwise on screen — hence the negation.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 { return image }
        let w = image.width, h = image.height
        let (outW, outH) = turns % 2 == 0 ? (w, h) : (h, w)
        // Draw in the source's own colour space so a Display P3 photo stays P3; DeviceRGB only
        // when the source is untagged or its space cannot back an RGBA8 context (gray, indexed).
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context = image.colorSpace.flatMap(makeContext) ?? makeContext(CGColorSpaceCreateDeviceRGB())
        else { return nil }
        context.interpolationQuality = .none  // a quarter turn moves whole pixels; never resample
        context.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return context.makeImage()
    }

    /// `unitRect` (already clamped) applied in pixels. nil when the rounded rect has no pixels —
    /// the caller falls back to the uncropped image rather than failing the framing.
    static func crop(_ image: CGImage, unitRect: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pixelRect = CGRect(x: (unitRect.minX * w).rounded(.down),
                               y: (unitRect.minY * h).rounded(.down),
                               width: (unitRect.width * w).rounded(),
                               height: (unitRect.height * h).rounded())
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }
}
