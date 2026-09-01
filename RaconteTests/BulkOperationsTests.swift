import XCTest
@testable import Raconte

/// #128 Task 2: the four bulk operations on `LibraryScreenModel`, each looping a
/// non-rescanning core and rescanning exactly ONCE at the end (`emptyTrash`'s structure,
/// not one rescan per entry — the whole point of the task).
///
/// Partial failure is injected for real — a corrupt `entry.json` makes
/// `EntryMetadataStore` throw for exactly that id (the same failure fixture
/// `LibraryTrashTests` uses throughout) — and every partial-failure test asserts BOTH
/// that the good entries landed and that `failed` names exactly the bad ones. A fixture
/// where everything succeeds would pass without exercising any of that.
@MainActor
final class BulkOperationsTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    private let idA = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private let idB = "01BBBBBBBBBBBBBBBBBBBBBBBB"
    private let idC = "01CCCCCCCCCCCCCCCCCCCCCCCC"

    /// Counts `libraryDidRescan()` notifications — one per PUBLISHED rescan. Attached
    /// right before the operation under test, so fixture setup's own rescans never
    /// pollute the count. Held strongly by the test (`rescanObserver` is weak).
    private final class RescanCounter: LibraryRescanObserver {
        var count = 0
        func libraryDidRescan() { count += 1 }
    }

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BulkOps-\(UUID().uuidString)", isDirectory: true)
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

    /// The per-id failure injection: an `entry.json` that does not decode, so
    /// `EntryMetadataStore.update`/`read` throws for exactly this capture and no other.
    @discardableResult
    private func corruptSidecar(_ id: String) throws -> Data {
        let corrupt = Data("{ broken".utf8)
        try corrupt.write(to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))
        return corrupt
    }

    // MARK: - bulkTrash

    func testBulkTrashTrashesEverythingAndRescansOnce() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        try writeCapture(idC, capturedAt: 3_000)
        let model = model()
        await model.rescan()

        let counter = RescanCounter()
        model.rescanObserver = counter
        let result = await model.bulkTrash([idA, idB, idC])

        XCTAssertEqual(result, LibraryScreenModel.BulkResult(succeeded: 3, failed: []))
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(Set(model.trashed.map(\.captureID)), [idA, idB, idC])
        for id in [idA, idB, idC] {
            XCTAssertNotNil(try metadata(id).trashedAt)
        }
        XCTAssertEqual(counter.count, 1,
                       "a bulk trash must rescan once after the loop, never once per entry")
    }

    func testBulkTrashPartialFailureNamesExactlyTheBadIdAndLandsTheRest() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        try writeCapture(idC, capturedAt: 3_000)
        let corrupt = try corruptSidecar(idB)
        let model = model()
        await model.rescan()

        let result = await model.bulkTrash([idA, idB, idC])

        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.failed, [idB], "failed must name exactly the bad id")
        XCTAssertNotNil(try metadata(idA).trashedAt)
        XCTAssertNotNil(try metadata(idC).trashedAt)
        XCTAssertEqual(try Data(contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idB))),
                       corrupt, "the unreadable sidecar must never be overwritten with a tombstone")
        XCTAssertEqual(model.items.map(\.captureID), [idB],
                       "the failed entry stays in the library; the trashed two leave it")
    }

    // MARK: - bulkRestore

    func testBulkRestoreRestoresEverythingAndRescansOnce() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = model()
        await model.trashEntry(idA)
        await model.trashEntry(idB)
        XCTAssertEqual(Set(model.trashed.map(\.captureID)), [idA, idB])

        let counter = RescanCounter()
        model.rescanObserver = counter
        let result = await model.bulkRestore([idA, idB])

        XCTAssertEqual(result, LibraryScreenModel.BulkResult(succeeded: 2, failed: []))
        XCTAssertTrue(model.trashed.isEmpty)
        XCTAssertEqual(Set(model.items.map(\.captureID)), [idA, idB])
        XCTAssertNil(try metadata(idA).trashedAt)
        XCTAssertNil(try metadata(idB).trashedAt)
        XCTAssertEqual(counter.count, 1)
    }

    func testBulkRestorePartialFailureKeepsTheBadOneTrashed() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = model()
        await model.trashEntry(idA)
        await model.trashEntry(idB)
        let corrupt = try corruptSidecar(idB)

        let result = await model.bulkRestore([idA, idB])

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, [idB])
        XCTAssertNil(try metadata(idA).trashedAt, "the good entry must actually be restored")
        XCTAssertEqual(try Data(contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idB))),
                       corrupt)
    }

    // MARK: - bulkMove

    func testBulkMoveMovesEverythingAndRescansOnce() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = model()
        await model.rescan()

        let counter = RescanCounter()
        model.rescanObserver = counter
        let result = await model.bulkMove([idA, idB], toJournal: "J1")

        XCTAssertEqual(result, LibraryScreenModel.BulkResult(succeeded: 2, failed: []))
        XCTAssertEqual(try metadata(idA).journalID, "J1")
        XCTAssertEqual(try metadata(idB).journalID, "J1")
        XCTAssertEqual(counter.count, 1)
    }

    func testBulkMovePartialFailureMovesOnlyTheGoodOnes() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        try writeCapture(idC, capturedAt: 3_000)
        let corrupt = try corruptSidecar(idB)
        let model = model()
        await model.rescan()

        let result = await model.bulkMove([idA, idB, idC], toJournal: "J1")

        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.failed, [idB])
        XCTAssertEqual(try metadata(idA).journalID, "J1")
        XCTAssertEqual(try metadata(idC).journalID, "J1")
        XCTAssertEqual(try Data(contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idB))),
                       corrupt)
    }

    /// A bulk move into a still-provisional default journal must promote it — the same
    /// `promoteProvisionalDefaultAfterEntrySave` chokepoint every single-entry
    /// `journalID` write already goes through. (It runs once after the loop, not per
    /// entry; the call is idempotent, so once-ness is a cost decision the code comments —
    /// what this test pins is that the call happens at all.)
    func testBulkMovePromotesAProvisionalDefaultJournal() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = model()
        let journal = try await model.journalStore.createProvisionalDefault(name: "Journal")
        await model.rescan()

        let result = await model.bulkMove([idA, idB], toJournal: journal.id)

        XCTAssertEqual(result.succeeded, 2)
        let after = try await model.journalStore.journal(id: journal.id)
        XCTAssertEqual(after?.provisionalDefault, false,
                       "filing entries into a provisional default must promote it")
    }

    // MARK: - bulkDeletePermanently

    func testBulkDeleteRemovesTrashedEntriesRefusesALiveOneAndRescansOnce() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        try writeCapture(idC, capturedAt: 3_000)
        let model = model()
        await model.trashEntry(idA)
        await model.trashEntry(idC)

        let counter = RescanCounter()
        model.rescanObserver = counter
        // idB is NOT trashed: the re-read-and-refuse rule must catch it even though the
        // caller handed it over as if it were deletable — the row is a snapshot.
        let result = await model.bulkDeletePermanently([idA, idB, idC])

        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.failed, [idB])
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idC).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idB).path),
                      "a live entry must survive a bulk permanent delete")
        XCTAssertEqual(model.items.map(\.captureID), [idB])
        XCTAssertTrue(model.trashed.isEmpty)
        XCTAssertEqual(counter.count, 1)
    }

    func testBulkDeleteRefusesAnUnreadableSidecarAndDeletesTheRest() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = model()
        await model.trashEntry(idA)
        await model.trashEntry(idB)
        let corrupt = try corruptSidecar(idB)

        let result = await model.bulkDeletePermanently([idA, idB])

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, [idB])
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idB).path))
        XCTAssertEqual(try Data(contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idB))),
                       corrupt)
    }

    /// One purge after the loop (never per item), and it actually ran — nothing may be
    /// left behind in `trash-pending/`.
    func testBulkDeleteLeavesNothingStaged() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = model()
        await model.trashEntry(idA)
        await model.trashEntry(idB)

        let result = await model.bulkDeletePermanently([idA, idB])

        XCTAssertEqual(result, LibraryScreenModel.BulkResult(succeeded: 2, failed: []))
        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        XCTAssertTrue(staged.isEmpty, "the single purge after the loop must have run")
    }

    /// An empty id list is a no-op: no staging root created, no rescan paid.
    func testBulkDeleteOnNoIdsNoOps() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.rescan()

        let counter = RescanCounter()
        model.rescanObserver = counter
        let result = await model.bulkDeletePermanently([])

        XCTAssertEqual(result, LibraryScreenModel.BulkResult(succeeded: 0, failed: []))
        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
        XCTAssertEqual(counter.count, 0)
    }

    // MARK: - The single-entry paths still behave exactly as before

    /// The extraction must not change `trashEntry`/`restoreEntry`/`moveEntry` behavior:
    /// they still rescan (once) per call, and still report a store failure as `false`.
    func testSingleEntryPathsStillRescanPerCall() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.rescan()

        let counter = RescanCounter()
        model.rescanObserver = counter

        let trashed = await model.trashEntry(idA)
        XCTAssertTrue(trashed)
        XCTAssertEqual(counter.count, 1)
        let restored = await model.restoreEntry(idA)
        XCTAssertTrue(restored)
        XCTAssertEqual(counter.count, 2)
        let moved = await model.moveEntry(idA, toJournal: "J1")
        XCTAssertTrue(moved)
        XCTAssertEqual(counter.count, 3)
        XCTAssertEqual(try metadata(idA).journalID, "J1")
    }
}
