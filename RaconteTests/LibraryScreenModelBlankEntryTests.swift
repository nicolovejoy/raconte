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

    // MARK: Sync hooks (final review I1/I2)

    /// I2: without this the ONLY producer that discovers a locally added image is
    /// `SyncPlanner.reconcile`, which runs once at `SyncCoordinator.live()` composition
    /// — so the photo would first reach the server at the next app launch.
    func testAddImageEnqueuesTheImageAsALocalChange() async throws {
        let model = model()
        let hooks = DeletionRecordingSyncHooks()
        model.attach(syncHooks: hooks)
        let minted = await model.createBlankEntry(journalID: nil)
        let captureID = try XCTUnwrap(minted)

        let png = try XCTUnwrap(Self.onePixelPNG)
        let added = await model.addImage(captureID, data: png, sourceUTType: nil)
        XCTAssertTrue(added)

        let mintedImageID = await model.images(for: captureID).first?.id
        let imageID = try XCTUnwrap(mintedImageID)
        let changed = await hooks.changedNames
        XCTAssertEqual(changed, [.image(captureID: captureID, imageID: imageID)],
                       "the minted sidecar's own id, not a re-derived one")
        let deleted = await hooks.deletedNames
        XCTAssertTrue(deleted.isEmpty, "an add is not a delete")
    }

    /// The failure path must stay silent: nothing was written, so there is nothing to
    /// push, and enqueueing a name for a record that does not exist would leave the
    /// engine retrying it.
    func testAddImageFiresNoHookWhenTheStoreRefuses() async throws {
        let model = model()
        let hooks = DeletionRecordingSyncHooks()
        model.attach(syncHooks: hooks)

        let added = await model.addImage("01NOSUCHCAPTURE0000000001", data: Data([0, 1, 2]), sourceUTType: nil)
        XCTAssertFalse(added)

        let changed = await hooks.changedNames
        XCTAssertTrue(changed.isEmpty)
    }

    /// I1: `SyncPlanner.reconcile` never infers a delete from an artifact's absence from
    /// a scan (deliberately — see its doc comment), so without the explicit verb the
    /// server record survives forever and a wipe/resync writes the "removed" image back
    /// into `images/`.
    func testRemoveImageEnqueuesTheImageAsALocalDelete() async throws {
        let model = model()
        let hooks = DeletionRecordingSyncHooks()
        model.attach(syncHooks: hooks)
        let minted = await model.createBlankEntry(journalID: nil)
        let captureID = try XCTUnwrap(minted)
        let png = try XCTUnwrap(Self.onePixelPNG)
        _ = await model.addImage(captureID, data: png, sourceUTType: nil)
        let mintedImageID = await model.images(for: captureID).first?.id
        let imageID = try XCTUnwrap(mintedImageID)
        await hooks.reset()

        await model.removeImage(captureID, imageID: imageID)

        let deleted = await hooks.deletedNames
        XCTAssertEqual(deleted, [.image(captureID: captureID, imageID: imageID)])
        let changed = await hooks.changedNames
        XCTAssertTrue(changed.isEmpty, "a delete is not a change — the two verbs are distinct")
    }

    /// The sync-INBOUND write path (`SyncIngest.ingestImage`/park rehydration) goes
    /// through `ImageStore.ingest`, never through the model — so an arriving image can
    /// never echo back out as a local change and start a two-device ping-pong. Pinned
    /// here because the property is the whole reason I1/I2's hooks live on
    /// `LibraryScreenModel` rather than inside `ImageStore`'s write helpers, which both
    /// paths share. (`ImageStore` has no `syncHooks` at all; this asserts the observable
    /// consequence — an ingest writing the same trio moves neither queue.)
    func testIngestNeverEchoesBackAsALocalChangeOrDelete() async throws {
        let model = model()
        let hooks = DeletionRecordingSyncHooks()
        model.attach(syncHooks: hooks)
        let minted = await model.createBlankEntry(journalID: nil)
        let captureID = try XCTUnwrap(minted)
        let data = try XCTUnwrap(Self.onePixelPNG)

        let store = ImageStore(capturesRoot: capturesRoot)
        let sidecar = ImageSidecar(id: "01FOREIGNIMAGE000000000001", originalExtension: "png",
                                   mime: "image/png", bytes: data.count,
                                   sha256: ImageStore.sha256Hex(data), width: 1, height: 1,
                                   capturedAt: nil, addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.ingest(captureID: captureID, imageID: sidecar.id, sidecar: sidecar, data: data)

        // The bytes really landed — this is not a vacuous "nothing happened" assertion.
        let images = await model.images(for: captureID)
        XCTAssertEqual(images.map(\.id), [sidecar.id])

        let changed = await hooks.changedNames
        let deleted = await hooks.deletedNames
        XCTAssertTrue(changed.isEmpty, "an inbound write must never echo back as a local change")
        XCTAssertTrue(deleted.isEmpty)
    }

    // MARK: Thumbnail self-heal (final review I4)

    /// The model's read path repairs a torn thumbnail from the `.orig` rather than
    /// degrading to the placeholder forever.
    func testThumbnailDataRegeneratesATornThumbnail() async throws {
        let model = model()
        let minted = await model.createBlankEntry(journalID: nil)
        let captureID = try XCTUnwrap(minted)
        let jpeg = ImageThumbnailerTests.makeJPEG(width: 40, height: 40, color: (9, 8, 7))
        _ = await model.addImage(captureID, data: jpeg, sourceUTType: nil)
        let mintedImageID = await model.images(for: captureID).first?.id
        let imageID = try XCTUnwrap(mintedImageID)

        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        let thumbURL = SegmentLayout.imageThumbnailURL(captureDirectory: directory, imageID: imageID)
        try Data("not a jpeg".utf8).write(to: thumbURL)

        let read = await model.thumbnailData(captureID: captureID, imageID: imageID)
        let healed = try XCTUnwrap(read, "the read self-heals instead of returning the torn bytes")
        XCTAssertNotEqual(healed, Data("not a jpeg".utf8))
        XCTAssertNotNil(ImageStore.decodeImageInfo(data: healed, sourceUTType: nil))
    }

    /// An image whose ORIGINAL is also gone has nothing to regenerate from, so the read
    /// still degrades to nil — the placeholder path stays reachable.
    func testThumbnailDataStaysNilWhenTheOriginalIsGoneToo() async throws {
        let model = model()
        let minted = await model.createBlankEntry(journalID: nil)
        let captureID = try XCTUnwrap(minted)
        let jpeg = ImageThumbnailerTests.makeJPEG(width: 40, height: 40, color: (1, 2, 3))
        _ = await model.addImage(captureID, data: jpeg, sourceUTType: nil)
        let firstSidecar = await model.images(for: captureID).first
        let sidecar = try XCTUnwrap(firstSidecar)

        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        try FileManager.default.removeItem(
            at: SegmentLayout.imageThumbnailURL(captureDirectory: directory, imageID: sidecar.id))
        try FileManager.default.removeItem(
            at: SegmentLayout.imageOriginalURL(captureDirectory: directory, imageID: sidecar.id,
                                               ext: sidecar.originalExtension))

        let result = await model.thumbnailData(captureID: captureID, imageID: sidecar.id)
        XCTAssertNil(result)
    }

    /// A minimal valid 1x1 PNG, so `ImageStore.addImage`'s ImageIO decode succeeds.
    private static let onePixelPNG: Data? = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
}
