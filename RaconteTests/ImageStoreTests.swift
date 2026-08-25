import XCTest
import CryptoKit
@testable import Raconte

/// Task 2 (image capture plan): `ImageStore` — sha256-verified atomic writes of
/// originals + sidecar + thumbnail, ingest for sync, and the "needs thumbnail regen"
/// state on a failed thumbnail generation.
final class ImageStoreTests: XCTestCase {

    private var capturesRoot: URL!
    private let captureID = "01KYX77KK5QM15915EZBVXTQZ4"

    override func setUpWithError() throws {
        capturesRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RaconteImageStore-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: capturesRoot.deletingLastPathComponent())
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private static let defaultNow = Date(timeIntervalSince1970: 1_650_000_000)

    /// Deterministic, ascending-when-drained-in-order mint sequence — a test double for
    /// `ULID.make()`, not a real ULID. `@unchecked Sendable`: mutation is confined to
    /// this single-threaded test's actor calls, which are awaited serially, so there is
    /// no real data race — matches the house pattern of test-only unchecked seams for a
    /// closure-captured mutable box.
    final class SequenceIDs: @unchecked Sendable {
        private var ids: [String]
        init(_ ids: [String]) { self.ids = ids }
        func next() -> String { ids.isEmpty ? "fallback-\(UUID().uuidString)" : ids.removeFirst() }
    }

    private func store(now: @escaping @Sendable () -> Date = { ImageStoreTests.defaultNow },
                       mintImageID: @escaping @Sendable () -> String = { ULID.make() },
                       thumbnailer: @escaping @Sendable (Data) -> Data? = { ImageThumbnailer.generate(from: $0) })
    -> ImageStore {
        ImageStore(capturesRoot: capturesRoot, now: now, mintImageID: mintImageID, thumbnailer: thumbnailer)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: addImage — happy path

    func testAddImageWritesOrigSidecarAndThumbnailWithHashOfBytesActuallyOnDisk() async throws {
        let s = store(mintImageID: { "IMG001" })
        let source = ImageThumbnailerTests.makeJPEG(width: 40, height: 40, color: (10, 20, 30))

        let sidecar = try await s.addImage(captureID: captureID, data: source, sourceUTType: nil)

        XCTAssertEqual(sidecar.id, "IMG001")
        let origURL = SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory, imageID: "IMG001",
                                                      ext: sidecar.originalExtension)
        let sidecarURL = SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: "IMG001")
        let thumbURL = SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: "IMG001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: origURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbURL.path))

        // Never the caller's claimed value — a fresh hash of the bytes actually written.
        let onDisk = try Data(contentsOf: origURL)
        XCTAssertEqual(sidecar.sha256, sha256Hex(onDisk))
        XCTAssertEqual(onDisk, source)
        XCTAssertEqual(sidecar.bytes, source.count)
        XCTAssertEqual(sidecar.addedAt, Self.defaultNow)
    }

    // MARK: addImage — captureMissing

    func testAddImageOnMissingCaptureDirectoryThrowsCaptureMissing() async {
        let s = store()
        let source = ImageThumbnailerTests.makeJPEG(width: 10, height: 10, color: (1, 1, 1))
        do {
            _ = try await s.addImage(captureID: "no-such-capture", data: source, sourceUTType: nil)
            XCTFail("expected captureMissing")
        } catch {
            XCTAssertEqual(error as? ImageStoreError, .captureMissing)
        }
    }

    // MARK: addImage — invalidImage, no orphaned partial files

    func testAddImageWithNonImageBytesThrowsInvalidImageAndWritesNothing() async throws {
        let s = store()
        let before = try? FileManager.default.contentsOfDirectory(atPath: captureDirectory.path)

        do {
            _ = try await s.addImage(captureID: captureID, data: Data("not an image".utf8), sourceUTType: nil)
            XCTFail("expected invalidImage")
        } catch {
            XCTAssertEqual(error as? ImageStoreError, .invalidImage)
        }

        let after = try? FileManager.default.contentsOfDirectory(atPath: captureDirectory.path)
        XCTAssertEqual(before ?? [], after ?? [], "no orphaned partial files after a rejected add")
    }

    // MARK: images(captureID:) ordering + empty cases

    func testImagesReturnsSidecarsInAscendingIDOrderAfterThreeAdds() async throws {
        let ids = SequenceIDs(["IMG_C", "IMG_A", "IMG_B"])
        let s = store(mintImageID: { ids.next() })
        for _ in 0..<3 {
            _ = try await s.addImage(captureID: captureID,
                                     data: ImageThumbnailerTests.makeJPEG(width: 10, height: 10, color: (1, 2, 3)),
                                     sourceUTType: nil)
        }
        let images = await s.images(captureID: captureID)
        XCTAssertEqual(images.map(\.id), ["IMG_A", "IMG_B", "IMG_C"])
    }

    func testImagesForCaptureWithNoImagesDirectoryIsEmptyNotThrowing() async {
        let s = store()
        let images = await s.images(captureID: captureID)
        XCTAssertEqual(images, [])
    }

    func testImagesForUnknownCaptureIsEmptyNotThrowing() async {
        let s = store()
        let images = await s.images(captureID: "no-such-capture")
        XCTAssertEqual(images, [])
    }

    // MARK: removeImage

    func testRemoveImageDeletesOnlyThatImagesTrioAndLeavesSiblingIntact() async throws {
        let ids = SequenceIDs(["IMG_ONE", "IMG_TWO"])
        let s = store(mintImageID: { ids.next() })
        let dataOne = ImageThumbnailerTests.makeJPEG(width: 12, height: 12, color: (9, 9, 9))
        let dataTwo = ImageThumbnailerTests.makeJPEG(width: 14, height: 14, color: (8, 8, 8))
        let sidecarOne = try await s.addImage(captureID: captureID, data: dataOne, sourceUTType: nil)
        let sidecarTwo = try await s.addImage(captureID: captureID, data: dataTwo, sourceUTType: nil)

        await s.removeImage(captureID: captureID, imageID: "IMG_ONE")

        let origOne = SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory, imageID: "IMG_ONE",
                                                      ext: sidecarOne.originalExtension)
        let sidecarOneURL = SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: "IMG_ONE")
        let thumbOneURL = SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: "IMG_ONE")
        XCTAssertFalse(FileManager.default.fileExists(atPath: origOne.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarOneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbOneURL.path))

        let origTwo = SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory, imageID: "IMG_TWO",
                                                      ext: sidecarTwo.originalExtension)
        let sidecarTwoURL = SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: "IMG_TWO")
        let thumbTwoURL = SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: "IMG_TWO")
        XCTAssertTrue(FileManager.default.fileExists(atPath: origTwo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarTwoURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbTwoURL.path))
        let onDiskTwo = try Data(contentsOf: origTwo)
        XCTAssertEqual(sha256Hex(onDiskTwo), sidecarTwo.sha256)

        let remaining = await s.images(captureID: captureID)
        XCTAssertEqual(remaining.map(\.id), ["IMG_TWO"])
    }

    func testRemoveImageOnAlreadyAbsentIDIsANoOp() async {
        let s = store()
        await s.removeImage(captureID: captureID, imageID: "never-existed")
        let images = await s.images(captureID: captureID)
        XCTAssertEqual(images, [])
    }

    // MARK: Thumbnail-generation failure — explicit "needs regen" state

    /// The chosen shape (implementer's call, per the brief): NOT a flag on the sidecar
    /// (the sidecar's fields are fixed by the plan and carry nothing thumbnail-related)
    /// but the thumbnail file's own absence at `SegmentLayout.imageThumbnailURL` — a
    /// re-check based on presence/absence, made explicit here as the load-bearing
    /// behavior rather than left as an implicit side effect of "thumbnailer returned
    /// nil so we just didn't write a file."
    func testThumbnailGenerationFailureDoesNotFailAddImageAndLeavesThumbnailAbsent() async throws {
        let s = store(mintImageID: { "IMG_NOTHUMB" }, thumbnailer: { _ in nil })
        let source = ImageThumbnailerTests.makeJPEG(width: 30, height: 30, color: (5, 6, 7))

        let sidecar = try await s.addImage(captureID: captureID, data: source, sourceUTType: nil)

        let origURL = SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory, imageID: "IMG_NOTHUMB",
                                                      ext: sidecar.originalExtension)
        let sidecarURL = SegmentLayout.imageSidecarURL(captureDirectory: captureDirectory, imageID: "IMG_NOTHUMB")
        let thumbURL = SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: "IMG_NOTHUMB")
        XCTAssertTrue(FileManager.default.fileExists(atPath: origURL.path), "orig still lands")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path), "sidecar still lands")
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbURL.path),
                       "absence IS the observable needs-regen signal")

        // images(captureID:) still reports the sidecar normally — a missing thumbnail
        // does not make an image invisible.
        let images = await s.images(captureID: captureID)
        XCTAssertEqual(images.map(\.id), ["IMG_NOTHUMB"])
    }

    // MARK: ingest

    func testIngestWritesFetchedBytesVerbatimPlusSidecarAndAttemptsThumbnail() async throws {
        let s = store()
        let data = ImageThumbnailerTests.makeJPEG(width: 22, height: 22, color: (4, 5, 6))
        let sidecar = ImageSidecar(id: "IMG_INGEST", originalExtension: "jpg", mime: "image/jpeg",
                                   bytes: data.count, sha256: sha256Hex(data), width: 22, height: 22,
                                   capturedAt: nil, addedAt: Self.defaultNow)

        try await s.ingest(captureID: captureID, imageID: "IMG_INGEST", sidecar: sidecar, data: data)

        let origURL = SegmentLayout.imageOriginalURL(captureDirectory: captureDirectory, imageID: "IMG_INGEST", ext: "jpg")
        XCTAssertEqual(try Data(contentsOf: origURL), data)
        let images = await s.images(captureID: captureID)
        XCTAssertEqual(images, [sidecar])
        let thumbURL = SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: "IMG_INGEST")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbURL.path))
    }
}
