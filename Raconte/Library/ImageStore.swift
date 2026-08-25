import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One image attached to a capture — `images/<id>.json` (image capture plan Task 2).
struct ImageSidecar: Codable, Sendable, Equatable {
    var id: String
    var originalExtension: String
    var mime: String
    var bytes: Int
    var sha256: String
    var width: Int?
    var height: Int?
    /// EXIF `DateTimeOriginal`/`DateTimeDigitized`, if present — see `ImageEXIF`.
    var capturedAt: Date?
    var addedAt: Date
}

enum ImageStoreError: Error, Equatable {
    /// There is no `captures/<id>/` to add into — same rationale as
    /// `EntryMetadataError.captureMissing`: writing anyway could recreate a capture
    /// directory a staged removal just moved away.
    case captureMissing
    /// The bytes handed to `addImage` don't decode as an image (ImageIO). Nothing is
    /// written — see `addImage`'s doc comment for the ordering that guarantees this.
    case invalidImage
}

/// Persists images attached to a capture: `images/<id>.<ext>` (original, verbatim
/// bytes), `images/<id>.json` (`ImageSidecar`), `images/thumbnails/<id>.jpg`
/// (generated preview). Mirrors `EntryMetadataStore`'s split of pure static seams + an
/// actor, though image writes are write-once — there is no read-modify-write here, so
/// the actor's job is narrower than `EntryMetadataStore.update`'s: serializing
/// concurrent adds to the same capture directory, the same reason
/// `JournalCoverStore`'s actor exists.
///
/// Pure ImageIO/CoreGraphics, not UIKit/AppKit — must build and test on macOS with no
/// platform `#if`, matching `JournalCoverStore`.
///
/// **Crash-ordering (design doc): orig, then sidecar, then thumbnail.** An orphaned
/// `.orig` with no sidecar is invisible to every reader (`images(captureID:)` only
/// lists `.json` files) — exactly like an orphaned `.pcm` with no manifest entry is
/// invisible to the capture recovery scan. A sidecar with no thumbnail is not an
/// orphan at all; it is the ordinary "needs thumbnail regen" state (see `addImage`).
actor ImageStore {
    nonisolated let capturesRoot: URL
    private let now: @Sendable () -> Date
    private let mintImageID: @Sendable () -> String
    /// Test seam for the "thumbnail generation failed" path (Task 2 brief): defaults to
    /// the real `ImageThumbnailer.generate`. Not part of the brief's literal init
    /// signature, but purely additive — every existing/implied call site that doesn't
    /// pass it keeps calling the real thumbnailer, so nothing downstream is affected by
    /// its presence.
    private let thumbnailer: @Sendable (Data) -> Data?

    init(capturesRoot: URL, now: @escaping @Sendable () -> Date = { Date() },
         mintImageID: @escaping @Sendable () -> String = { ULID.make() },
         thumbnailer: @escaping @Sendable (Data) -> Data? = { ImageThumbnailer.generate(from: $0) }) {
        self.capturesRoot = capturesRoot
        self.now = now
        self.mintImageID = mintImageID
        self.thumbnailer = thumbnailer
    }

    nonisolated func captureDirectory(captureID: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    /// Verifies `data` decodes as an image (ImageIO), mints an id, then writes `.orig` +
    /// sidecar + thumbnail atomically-in-sequence. Thumbnail generation failure does
    /// NOT fail the add (degrade-never-skip) — it just leaves the thumbnail file
    /// absent, which is this store's whole "needs thumbnail regen" signal (implementer's
    /// call, per the brief: not a flag on `ImageSidecar` — that struct's shape is fixed
    /// by the plan and carries nothing thumbnail-related — but the thumbnail file's own
    /// presence/absence at `SegmentLayout.imageThumbnailURL`, checked wherever "does
    /// this image have a usable thumbnail" needs an answer).
    func addImage(captureID: String, data: Data, sourceUTType: String?) async throws -> ImageSidecar {
        let directory = captureDirectory(captureID: captureID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ImageStoreError.captureMissing
        }
        guard let info = Self.decodeImageInfo(data: data, sourceUTType: sourceUTType) else {
            throw ImageStoreError.invalidImage
        }

        let imageID = mintImageID()
        let sidecar = ImageSidecar(id: imageID, originalExtension: info.ext, mime: info.mime,
                                   bytes: data.count, sha256: Self.sha256Hex(data),
                                   width: info.width, height: info.height,
                                   capturedAt: ImageEXIF.capturedAt(from: data), addedAt: now())

        try Self.writeOriginal(data, captureDirectory: directory, imageID: imageID, ext: info.ext)
        try Self.writeSidecar(sidecar, captureDirectory: directory)
        writeThumbnailIfPossible(data, captureDirectory: directory, imageID: imageID)

        return sidecar
    }

    /// Every sidecar for a capture, ULID order (== display order, since `mintImageID`
    /// is `ULID.make` by default). Empty for a capture with no images / no `images/`
    /// directory / an unknown captureID — never throws, matching `EntryMetadataStore
    /// .read`'s "absent is not an error" stance for the common case.
    func images(captureID: String) -> [ImageSidecar] {
        let directory = SegmentLayout.imagesDirectory(captureDirectory: captureDirectory(captureID: captureID))
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let sidecars: [ImageSidecar] = entries
            .filter { $0.pathExtension == SegmentLayout.sidecarExtension }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decodeSidecar(data)
            }
        return sidecars.sorted { $0.id < $1.id }
    }

    /// Removes the `.orig`/`.json`/thumbnail trio for one image. Not an error if
    /// already absent (idempotent, matching `JournalCoverStore.delete`'s convention).
    /// Finds the orig/sidecar pair by filename stem (`<imageID>.*` directly under
    /// `images/`) rather than by first reading the sidecar for its extension — so a
    /// removal still cleans up a stray orig even if its sidecar is itself missing or
    /// corrupt.
    func removeImage(captureID: String, imageID: String) async {
        let directory = captureDirectory(captureID: captureID)
        let imagesDirectory = SegmentLayout.imagesDirectory(captureDirectory: directory)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: imagesDirectory, includingPropertiesForKeys: nil) {
            for url in entries where url.deletingPathExtension().lastPathComponent == imageID {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.removeItem(
            at: SegmentLayout.imageThumbnailURL(captureDirectory: directory, imageID: imageID))
    }

    /// Ingest path (mirrors `JournalCoverStore.ingest`): writes fetched bytes verbatim
    /// — sha256-verified by the CALLER before this is invoked, same division of labor
    /// as `EntryAssembler.assemble`'s audio verify-then-write — plus the sender's own
    /// sidecar, unmodified. Also attempts a local thumbnail from the same bytes (they're
    /// already in hand); a failure there leaves the thumbnail absent, same "needs regen"
    /// state as a local `addImage` thumbnail failure — there is nothing ingest-specific
    /// about that state.
    func ingest(captureID: String, imageID: String, sidecar: ImageSidecar, data: Data) throws {
        let directory = captureDirectory(captureID: captureID)
        try Self.writeOriginal(data, captureDirectory: directory, imageID: imageID, ext: sidecar.originalExtension)
        try Self.writeSidecar(sidecar, captureDirectory: directory)
        writeThumbnailIfPossible(data, captureDirectory: directory, imageID: imageID)
    }

    // MARK: Private helpers

    private func writeThumbnailIfPossible(_ data: Data, captureDirectory: URL, imageID: String) {
        guard let thumbnail = thumbnailer(data) else { return }
        let thumbnailsDirectory = SegmentLayout.imageThumbnailsDirectory(captureDirectory: captureDirectory)
        guard (try? FileManager.default.createDirectory(
            at: thumbnailsDirectory, withIntermediateDirectories: true)) != nil else { return }
        let url = SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: imageID)
        try? AtomicFile.replace(at: url, writing: thumbnail)
    }

    // MARK: Pure seams (sync; no actor hop, so format/decode logic is testable on its own)

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeSidecar(_ data: Data) throws -> ImageSidecar {
        try CaptureCoding.decoder().decode(ImageSidecar.self, from: data)
    }

    static func encodeSidecar(_ sidecar: ImageSidecar) throws -> Data {
        try CaptureCoding.lineEncoder().encode(sidecar)
    }

    static func writeOriginal(_ data: Data, captureDirectory: URL, imageID: String, ext: String) throws {
        let imagesDirectory = SegmentLayout.imagesDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let url = SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory, imageID: imageID, ext: ext)
        try AtomicFile.replace(at: url, writing: data)
    }

    static func writeSidecar(_ sidecar: ImageSidecar, captureDirectory: URL) throws {
        let imagesDirectory = SegmentLayout.imagesDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let url = SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: sidecar.id)
        try AtomicFile.replace(at: url, writing: try encodeSidecar(sidecar))
    }

    /// Decodes `data` as an image and reports what `addImage` needs to mint a sidecar:
    /// the extension/MIME to file it under and its pixel dimensions. Returns nil for
    /// anything ImageIO can't decode, or that decodes with no readable pixel
    /// dimensions — `addImage` maps that to `.invalidImage`.
    ///
    /// `sourceUTType` (from the caller — e.g. PHPickerResult's own type identifier)
    /// wins when it names a real `UTType`; otherwise the extension/MIME are derived
    /// from what ImageIO itself detected the bytes to be
    /// (`CGImageSourceGetType`), so a caller that doesn't know the source type still
    /// gets a sensible answer.
    static func decodeImageInfo(data: Data, sourceUTType: String?)
    -> (ext: String, mime: String, width: Int?, height: Int?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let detectedType = CGImageSourceGetType(source) as String?
        let uttype = sourceUTType.flatMap { UTType($0) } ?? detectedType.flatMap { UTType($0) }
        let ext = uttype?.preferredFilenameExtension ?? "bin"
        let mime = uttype?.preferredMIMEType ?? "application/octet-stream"
        return (ext, mime, width, height)
    }
}
