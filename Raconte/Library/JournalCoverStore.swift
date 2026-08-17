import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum JournalCoverError: Error, Equatable {
    /// The source bytes could not be decoded as an image, or re-encoding failed.
    /// Distinct from "no cover" — see `JournalCoverStore.read`, which never throws.
    case invalidImage
}

/// Persists a journal's cover image at `journals/<id>/cover.jpg` (issue #14 part 3).
///
/// An actor for the same read-modify-... reason as `JournalStore`, though there is no
/// read-modify-write here — `write`/`delete` are independent single-file operations, so
/// the serialization is only there to keep two concurrent picks from interleaving their
/// atomic replaces. Pure ImageIO/CoreGraphics, not UIKit — the store must build and be
/// testable on macOS, and thumbnail generation this way never materializes a full-size
/// decoded bitmap for a multi-megapixel photo library selection.
///
/// Unlike `JournalStore`/`EntryMetadataStore`, `read` never distinguishes absent from
/// unreadable: a cover is decoration, not identity data, and nothing is ever built *from*
/// what `read` returns except a thumbnail. Degrading a corrupt or missing file to "no
/// cover" is exactly today's no-cover appearance — the house degrade-never-skip rule,
/// applied at the simplest point it can be.
actor JournalCoverStore {
    nonisolated let containerRoot: URL
    private let maxDimension: CGFloat
    private let compressionQuality: CGFloat

    /// M4 T5. The cover's bytes live here, but its last-writer-wins stamp
    /// (`Journal.modified["cover"]`) lives in `journals.json` — the only place a per-field
    /// stamp map exists, and the thing a receiving device reads to decide whether a
    /// fetched cover is newer than its own. Routing that stamp through `JournalStore`
    /// rather than writing the registry from this actor keeps `journals.json`
    /// single-writer, which is the whole reason `JournalStore` is an actor. Nil in tests
    /// and in any build without sync, in which case covers behave exactly as before M4.
    private var journalStore: JournalStore?

    init(containerRoot: URL, maxDimension: CGFloat = 1024, compressionQuality: CGFloat = 0.8,
         journalStore: JournalStore? = nil) {
        self.containerRoot = containerRoot
        self.maxDimension = maxDimension
        self.compressionQuality = compressionQuality
        self.journalStore = journalStore
    }

    /// Same after-the-fact wiring as `JournalStore.attach(syncHooks:)`, and for the same
    /// composition-root ordering reason.
    func attach(journalStore: JournalStore) {
        self.journalStore = journalStore
    }

    nonisolated func url(journalID: String) -> URL {
        AppContainer.journalCoverURL(containerRoot: containerRoot, journalID: journalID)
    }

    // MARK: Reads

    /// The cover's JPEG bytes, or nil if there is none or it could not be read/decoded.
    func read(journalID: String) -> Data? {
        Self.read(url: url(journalID: journalID))
    }

    // MARK: Writes

    /// Re-encodes `imageData` (any ImageIO-decodable format) as a JPEG downscaled to
    /// `maxDimension` on its longest side and writes it atomically. Throws
    /// `.invalidImage` for bytes that don't decode as an image — the caller (a picker
    /// sheet) is expected to surface that, unlike a failed `read`.
    func write(imageData: Data, journalID: String) async throws {
        let jpeg = try Self.reencode(imageData, maxDimension: maxDimension,
                                     compressionQuality: compressionQuality)
        try writeBytes(jpeg, journalID: journalID)
        // Stamped after the bytes are down, never before: a stamp claiming a cover that
        // failed to write would make every other device fetch nothing and believe it was
        // up to date. The stamp is also what fires the sync hook (`stampCoverModified`),
        // so a cover change reaches the engine through exactly one path.
        try? await journalStore?.stampCoverModified(id: journalID)
    }

    /// Ingest path (M4 T5): writes the fetched cover's bytes **verbatim**, with no
    /// re-encode and no stamp.
    ///
    /// Verbatim because the sending device already put these bytes through `write` —
    /// re-encoding here would add a second JPEG generation for nothing, and would leave
    /// two devices holding covers that differ byte-for-byte, so each one's journal digest
    /// would differ and both would keep pushing the same image at each other.
    ///
    /// No stamp because the merged journal written alongside this already carries the
    /// remote's `modified["cover"]`; stamping "now" here would restamp a received cover as
    /// a local edit — the same echo `applySyncMerge` exists to avoid.
    func ingest(imageData: Data, journalID: String) throws {
        try writeBytes(imageData, journalID: journalID)
    }

    private func writeBytes(_ data: Data, journalID: String) throws {
        let url = url(journalID: journalID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AtomicFile.replace(at: url, writing: data)
    }

    /// Removes the cover, if any. Not an error when there was none.
    func delete(journalID: String) async {
        try? FileManager.default.removeItem(at: url(journalID: journalID))
        // Stamped even though nothing is left on disk: "there is no cover" is itself an
        // edit that has to beat the other device's older "here is a cover", and the
        // Journal record's cover field is cleared explicitly for the same reason
        // (`SyncRecordBuilders.journalRecord`).
        try? await journalStore?.stampCoverModified(id: journalID)
    }

    // MARK: Pure seams (sync, so tests can exercise the format without an actor hop)

    static func read(url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Downscales via `CGImageSourceCreateThumbnailAtIndex`, which decodes directly to
    /// the target size rather than materializing the source image at full resolution
    /// first — the difference matters for a photo-library selection that can be tens of
    /// megapixels.
    static func reencode(_ data: Data, maxDimension: CGFloat, compressionQuality: CGFloat) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw JournalCoverError.invalidImage
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw JournalCoverError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw JournalCoverError.invalidImage
        }
        let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw JournalCoverError.invalidImage }
        return output as Data
    }
}
