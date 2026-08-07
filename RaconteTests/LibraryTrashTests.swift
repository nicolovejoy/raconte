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
            EntryMetadata(journalID: "J1", originalDate: PartialDate(year: 1970, month: 1, day: 1)),
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))

        let model = model()
        await model.trashEntry(idA)
        await model.restoreEntry(idA)

        let restored = try metadata(idA)
        XCTAssertEqual(restored.journalID, "J1")
        XCTAssertEqual(restored.originalDate, PartialDate(year: 1970, month: 1, day: 1))
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

    // MARK: - Silent-swallow family (owner report 2026-08-03, part 2)

    /// The same `_ = try?` mistake `deleteEntryPermanently` had, one layer up: `trashEntry`
    /// used to report success even when the sidecar update threw. An unreadable
    /// `entry.json` is the read-side failure — `EntryMetadataStore.update` never gets to
    /// the write.
    func testTrashEntryReturnsFalseWhenSidecarUnreadable() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA))
        let corrupt = Data("{ broken".utf8)
        try corrupt.write(to: url)

        let trashed = await model().trashEntry(idA)

        XCTAssertFalse(trashed)
        XCTAssertEqual(try Data(contentsOf: url), corrupt, "an unreadable sidecar must not be overwritten")
    }

    /// Write-side failure: the sidecar reads fine but the directory is sealed against
    /// writes, so `AtomicFile.replace`'s `.part` + rename can't land. Mirrors
    /// `testDeleteNowReturnsFalseWhenRemovalFails`'s fixture.
    func testRestoreEntryReturnsFalseWhenWriteFails() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.trashEntry(idA)

        let dir = captureDir(idA)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }

        let restored = await model.restoreEntry(idA)

        XCTAssertFalse(restored)
        XCTAssertNotNil(try metadata(idA).trashedAt,
                        "a failed restore must leave the entry trashed, not half-undone")
        XCTAssertEqual(model.trashed.map(\.captureID), [idA])
    }

    func testMoveEntryReturnsFalseWhenSidecarUnreadable() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let url = SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA))
        let corrupt = Data("{ broken".utf8)
        try corrupt.write(to: url)

        let moved = await model().moveEntry(idA, toJournal: "J2")

        XCTAssertFalse(moved)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testSetBackdateReturnsFalseWhenWriteFails() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()

        let dir = captureDir(idA)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }

        let succeeded = await model.setBackdate(idA, to: Date(timeIntervalSince1970: 500_000))

        XCTAssertFalse(succeeded)
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

    /// Owner report 2026-08-03: "deleted it and it's still there." `removeItem` was
    /// `try?`, so a failed delete (permissions, a locked file, anything) still returned
    /// `true` — the caller believes the entry is gone while it sits untouched on disk.
    ///
    /// **Staged removal (#25) has landed, and this fixture was rewritten because of it.**
    /// Sealing the capture directory itself no longer reliably blocks anything — see
    /// `testDeleteNowSucceedsWhenTheStagedPurgeFails` below, where an unwritable *child*
    /// of the capture directory still lets the top-level `rename` through, since moving a
    /// directory doesn't touch its contents' permissions. The fixture that actually blocks
    /// the delete now is a sealed `capturesRoot`: `rename(2)` needs write permission on the
    /// SOURCE's parent to remove its directory entry, and that parent is `capturesRoot`,
    /// not the capture directory. (Measured directly against this filesystem with a
    /// standalone POSIX `rename()` probe before this test was written, not assumed.) This
    /// is exactly the inversion the original comment on this test predicted and named
    /// staged removal as the fix for.
    func testDeleteNowReturnsFalseWhenStagingFails() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.trashEntry(idA)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: capturesRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: capturesRoot.path)
        }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: capturesRoot.path),
                      "running as root — permissions cannot be made to bite")

        let deleted = await model.deleteEntryPermanently(idA)

        XCTAssertFalse(deleted)
        let dir = captureDir(idA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "the directory must survive a failed stage")
        XCTAssertNotNil(try metadata(idA).trashedAt,
                        "a failed permanent delete must not resurrect the entry")
        XCTAssertEqual(model.trashed.map(\.captureID), [idA])
    }

    // MARK: issue #25 — Delete Now stages, it does not walk

    /// GUARD — pins owner answer 3 (purge immediately after staging). **Mutation:**
    /// delete the `purge()` call from `deleteEntryPermanently` -> this must fail: the
    /// staged directory is left behind in `trash-pending/`.
    func testDeleteNowLeavesNothingStaged() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.trashEntry(idA)

        let deleted = await model.deleteEntryPermanently(idA)

        XCTAssertTrue(deleted)
        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        XCTAssertTrue(staged.isEmpty, "the purge that follows staging must have run")
    }

    /// RED — owner answer 1. Sealing `segments/` (inside the capture, not the capture
    /// directory's own mode, and not `trash-pending/` itself) leaves the top-level
    /// `rename` untouched: moving a directory to a new parent only needs write on the
    /// directory being moved and on both parent directories, never on its contents
    /// (measured directly, not assumed). So the stage succeeds and only the purge that
    /// follows fails.
    func testDeleteNowSucceedsWhenTheStagedPurgeFails() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.trashEntry(idA)

        let segments = SegmentLayout.segmentsDirectory(captureDirectory: captureDir(idA))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: segments.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: segments.path)
        }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: segments.path),
                      "running as root — permissions cannot be made to bite")

        let deleted = await model.deleteEntryPermanently(idA)

        XCTAssertTrue(deleted, "the rename landed — the entry is gone from the library regardless of the purge")
        XCTAssertFalse(model.items.map(\.captureID).contains(idA))
        XCTAssertFalse(model.trashed.map(\.captureID).contains(idA))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path))
        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        let staged = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
        XCTAssertEqual(staged.count, 1, "the staged directory must survive a failed purge")
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
