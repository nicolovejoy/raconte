import XCTest
@testable import Raconte

/// M3 T5 at the model layer: trash, restore, Delete Now, and the launch sweep as
/// `LibraryScreenModel` exposes them — including what each one does to the three lists
/// the screens read (`items`, `recent`, `trashed`).
@MainActor
final class LibraryTrashTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    private let idA = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private let idB = "01BBBBBBBBBBBBBBBBBBBBBBBB"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func writeCapture(_ id: String, capturedAt: Double, frames: Int = 48_000) throws {
        let segs = SegmentLayout.segmentsDirectory(captureDirectory: captureDir(id))
        try FileManager.default.createDirectory(at: segs, withIntermediateDirectories: true)
        try Data(count: frames * 4).write(to: SegmentLayout.pcmURL(segmentsDirectory: segs, index: 0))

        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let created = Date(timeIntervalSince1970: capturedAt)
        let manifest = Manifest(captureID: id, createdAt: created, state: .captured,
                                stateSeq: 1, stateUpdatedAt: created, format: format)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDir(id)))
    }

    private func metadata(_ id: String) throws -> EntryMetadata {
        try EntryMetadataStore.read(url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
    }

    // MARK: - Trash / restore

    func testTrashRemovesFromListAndRecentAndAddsToTrash() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)

        let model = model()
        await model.rescan()
        XCTAssertEqual(Set(model.items.map(\.captureID)), [idA, idB])

        await model.trashEntry(idA)

        XCTAssertEqual(model.items.map(\.captureID), [idB])
        XCTAssertEqual(model.recent.map(\.captureID), [idB])
        XCTAssertEqual(model.trashed.map(\.captureID), [idA])
        XCTAssertNotNil(try metadata(idA).trashedAt)
        // Nothing left the disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path))
    }

    func testRestorePutsTheEntryBack() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.trashEntry(idA)
        XCTAssertEqual(model.trashed.map(\.captureID), [idA])

        await model.restoreEntry(idA)

        XCTAssertEqual(model.items.map(\.captureID), [idA])
        XCTAssertTrue(model.trashed.isEmpty)
        XCTAssertNil(try metadata(idA).trashedAt)
    }

    /// Trashing preserves everything else in the sidecar — it is a field edit through
    /// `update`, not a rewrite.
    func testTrashAndRestorePreserveJournalAndBackdate() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try EntryMetadataStore.write(
            EntryMetadata(journalID: "J1", originalDate: Date(timeIntervalSince1970: 500)),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        await model.trashEntry(idA)
        await model.restoreEntry(idA)

        let restored = try metadata(idA)
        XCTAssertEqual(restored.journalID, "J1")
        XCTAssertEqual(restored.originalDate, Date(timeIntervalSince1970: 500))
        XCTAssertNil(restored.trashedAt)
    }

    /// An `entry.json` we cannot parse is never overwritten with a tombstone. The entry
    /// stays visible in the library, marked as degraded, exactly as it was.
    func testTrashingAnUnreadableSidecarChangesNothing() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA))
        let corrupt = Data("{ broken".utf8)
        try corrupt.write(to: url)

        let model = model()
        await model.trashEntry(idA)

        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertEqual(model.items.map(\.captureID), [idA])
        XCTAssertTrue(model.trashed.isEmpty)
    }

    // MARK: - Delete Now

    func testDeleteNowRemovesATrashedEntry() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.trashEntry(idA)

        let deleted = await model.deleteEntryPermanently(idA)

        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path))
        XCTAssertTrue(model.trashed.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
    }

    /// The disk decides, not the row the button was drawn from.
    func testDeleteNowRefusesAnEntryThatIsNotTrashed() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.rescan()

        let deleted = await model.deleteEntryPermanently(idA)

        XCTAssertFalse(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path))
    }

    func testDeleteNowRefusesAnUnreadableSidecar() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try Data("{ broken".utf8).write(
            to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let deleted = await model().deleteEntryPermanently(idA)

        XCTAssertFalse(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path))
    }

    // MARK: - Sweep

    func testSweepRemovesExpiredEntriesAndRepublishesTheLists() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        try EntryMetadataStore.write(
            EntryMetadata(trashedAt: Date().addingTimeInterval(-40 * 86_400)),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        await model.rescan()
        XCTAssertEqual(model.trashed.map(\.captureID), [idA])

        await model.sweepTrash()

        XCTAssertEqual(model.lastSweep?.deleted, [idA])
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path))
        XCTAssertTrue(model.trashed.isEmpty)
        XCTAssertEqual(model.items.map(\.captureID), [idB])
    }

    func testSweepLeavesAFreshlyTrashedEntryAlone() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.trashEntry(idA)

        await model.sweepTrash()

        XCTAssertEqual(model.lastSweep?.deleted, [])
        XCTAssertEqual(model.trashed.map(\.captureID), [idA])
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path))
    }
}
