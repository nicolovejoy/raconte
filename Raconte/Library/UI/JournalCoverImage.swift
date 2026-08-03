import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A journal's cover thumbnail, decoded from `LibraryScreenModel.journalCovers` bytes.
/// Renders nothing (not a placeholder icon) when there is no cover or the bytes don't
/// decode — chips and the capture header already read fine without one, and a broken
/// silhouette would read as an error state that doesn't exist here.
struct JournalCoverThumbnail: View {
    let data: Data?
    var size: CGFloat = 24

    var body: some View {
        if let data, let image = Self.decode(data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
        }
    }

    #if os(iOS)
    static func decode(_ data: Data) -> Image? {
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
    }
    #else
    static func decode(_ data: Data) -> Image? {
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
    }
    #endif
}

/// The cover at a size you can actually recognize — the picker sheet's confirmation
/// view (owner feedback: the header/chip thumbnails are too small to tell whether the
/// set image is the intended one). Fixed height, full width, `scaledToFill` crop.
struct JournalCoverPreview: View {
    let data: Data
    var height: CGFloat = 180

    var body: some View {
        if let image = JournalCoverThumbnail.decode(data) {
            image
                .resizable()
                .scaledToFill()
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipped()
        }
    }
}
