import XCTest
@testable import Raconte

/// Image capture plan Task 3: the scan populates `EntryListItem.images` via
/// `ImageStore.readSidecars`, and a capture with images but no audio is not skipped
/// (Task 1's `imagesPresent` fix to `holdsIrreplaceableArtifacts`).
final class LibraryScannerImagesTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let captureID = "01CCCCCCCCCCCCCCCCCCCCCCCC"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScannerImages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private func scanner() -> LibraryScanner {
        LibraryScanner(capturesRoot: capturesRoot, containerRoot: containerRoot)
    }

    private func writeSidecar(id: String, addedAt: Date) throws {
        let sidecar = ImageSidecar(id: id, originalExtension: "jpg", mime: "image/jpeg",
                                   bytes: 100, sha256: "abc", width: 10, height: 10,
                                   capturedAt: nil, addedAt: addedAt)
        try ImageStore.writeSidecar(sidecar, captureDirectory: captureDirectory)
    }

    func testImagesPopulatedAndNotSkipped() async throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        // ULID order: "A" sorts before "B".
        try writeSidecar(id: "01AAAAAAAAAAAAAAAAAAAAAAAA", addedAt: Date(timeIntervalSince1970: 1_000))
        try writeSidecar(id: "01BBBBBBBBBBBBBBBBBBBBBBBB", addedAt: Date(timeIntervalSince1970: 2_000))

        let result = await scanner().scan()

        let item = try XCTUnwrap(result.items.first(where: { $0.captureID == captureID }))
        XCTAssertEqual(item.images.count, 2)
        XCTAssertEqual(item.leadingThumbnail?.id, "01AAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertFalse(result.skipped.contains(where: { $0.captureID == captureID }))
    }

    func testNoImagesYieldsEmptyArray() async throws {
        // A capture with real audio but no images/ directory at all.
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try Data(count: 48_000 * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))

        let result = await scanner().scan()

        let item = try XCTUnwrap(result.items.first(where: { $0.captureID == captureID }))
        XCTAssertTrue(item.images.isEmpty)
        XCTAssertNil(item.leadingThumbnail)
    }
}
