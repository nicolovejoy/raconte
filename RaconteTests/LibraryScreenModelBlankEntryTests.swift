import XCTest
@testable import Raconte

/// Image capture plan Task 3: `LibraryScreenModel.createBlankEntry` and the image
/// pass-through methods (`addImage`/`removeImage`/`images(for:)`).
@MainActor
final class LibraryScreenModelBlankEntryTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScreenModelBlankEntry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    // MARK: createBlankEntry

    func testCreateBlankEntryUnfiledShowsUpAfterRescan() async throws {
        let model = model()
        let minted = await model.createBlankEntry(journalID: nil)
        let captureID = try XCTUnwrap(minted)

        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        // createBlankEntry already rescans; re-scan explicitly too to pin the contract
        // independent of that internal detail.
        await model.rescan()
        let item = try XCTUnwrap(model.items.first(where: { $0.captureID == captureID }))
        XCTAssertNil(item.journalID)
        XCTAssertTrue(item.images.isEmpty)
    }

    func testCreateBlankEntryWithJournalWritesEntryMetadata() async throws {
        let model = model()
        let minted = await model.createBlankEntry(journalID: "j1")
        let captureID = try XCTUnwrap(minted)

        let entryURL = SegmentLayout.entryMetadataURL(
            captureDirectory: SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID))
        let metadata = try EntryMetadataStore.read(url: entryURL)
        XCTAssertEqual(metadata.journalID, "j1")
    }

    /// Forces the failure through the real `LibraryScreenModel.createBlankEntry` call,
    /// not just the underlying primitive: `capturesRoot` itself is a regular FILE, so
    /// `FileManager.createDirectory` fails for any capture id the mint tries.
    func testCreateBlankEntryReturnsNilOnWriteFailure() async throws {
        let blockedContainerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScreenModelBlankEntryBlocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedContainerRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: blockedContainerRoot) }
        let blockedCapturesRoot = AppContainer.capturesRoot(containerRoot: blockedContainerRoot)
        try Data().write(to: blockedCapturesRoot) // a file, not a directory

        let model = LibraryScreenModel(capturesRoot: blockedCapturesRoot,
                                       journalsContainerRoot: blockedContainerRoot)
        let result = await model.createBlankEntry(journalID: nil)
        XCTAssertNil(result)
    }

    // MARK: Image pass-through

    func testAddImageRescansAndPopulatesImages() async throws {
        let model = model()
        let minted = await model.createBlankEntry(journalID: nil)
        let captureID = try XCTUnwrap(minted)

        let data = try XCTUnwrap(Self.onePixelPNG)
        let added = await model.addImage(captureID, data: data, sourceUTType: nil)
        XCTAssertTrue(added)

        let images = await model.images(for: captureID)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(model.items.first(where: { $0.captureID == captureID })?.images.count, 1)
    }

    func testAddImageReturnsFalseOnStoreFailure() async throws {
        let model = model()
        // No capture directory at all — ImageStore.addImage throws .captureMissing.
        let added = await model.addImage("01NOSUCHCAPTURE0000000001", data: Data([0, 1, 2]), sourceUTType: nil)
        XCTAssertFalse(added)
    }

    func testRemoveImageRoundTrips() async throws {
        let model = model()
        let minted = await model.createBlankEntry(journalID: nil)
        let captureID = try XCTUnwrap(minted)
        let data = try XCTUnwrap(Self.onePixelPNG)
        _ = await model.addImage(captureID, data: data, sourceUTType: nil)
        let firstImageID = await model.images(for: captureID).first?.id
        let imageID = try XCTUnwrap(firstImageID)

        await model.removeImage(captureID, imageID: imageID)

        let images = await model.images(for: captureID)
        XCTAssertTrue(images.isEmpty)
    }

    /// A minimal valid 1x1 PNG, so `ImageStore.addImage`'s ImageIO decode succeeds.
    private static let onePixelPNG: Data? = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
}
