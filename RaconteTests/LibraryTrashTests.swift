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

    // MARK: issue #25 step 3 — restore against a vanished directory

    /// RED. Trash an entry, then stage it away directly (simulating a permanent delete
    /// that raced the restore tap, or a pre-fix half-destroyed directory a fresh stage
    /// swept up). `restoreEntry` must report failure and must not recreate
    /// `captures/<id>/` — that would be exactly the resurrection vector §0.3.6 names.
    func testRestoreOfAnEntryWhoseDirectoryVanishedReportsFailure() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.trashEntry(idA)

        let remover = StagedRemover(capturesRoot: capturesRoot, containerRoot: containerRoot)
        _ = try remover.stage(captureID: idA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path))

        let restored = await model.restoreEntry(idA)

        XCTAssertFalse(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path),
                       "restore must not recreate the capture directory")
    }

    // MARK: - Empty Trash (owner ask, 2026-08-22): bulk permanent delete

    private let idC = "01CCCCCCCCCCCCCCCCCCCCCCCC"

    /// The straightforward case: everything trashed goes, the result counts it.
    func testEmptyTrashRemovesAllTrashedEntries() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        try writeCapture(idC, capturedAt: 3_000)
        let model = model()
        await model.trashEntry(idA)
        await model.trashEntry(idB)
        await model.trashEntry(idC)
        XCTAssertEqual(Set(model.trashed.map(\.captureID)), [idA, idB, idC])

        let result = await model.emptyTrash()

        XCTAssertEqual(result, LibraryScreenModel.EmptyTrashResult(deleted: 3, failed: 0))
        XCTAssertTrue(model.trashed.isEmpty)
        for id in [idA, idB, idC] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(id).path))
        }
    }

    /// A live entry sitting alongside the trash must survive byte-identically — Empty
    /// Trash only ever touches what is actually trashed on disk.
    func testEmptyTrashLeavesNonTrashedEntriesUntouched() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = model()
        await model.trashEntry(idA)
        await model.rescan()
        XCTAssertEqual(model.trashed.map(\.captureID), [idA])
        XCTAssertEqual(model.items.map(\.captureID), [idB])
        let beforeManifest = try Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: captureDir(idB)))

        let result = await model.emptyTrash()

        XCTAssertEqual(result, LibraryScreenModel.EmptyTrashResult(deleted: 1, failed: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idB).path),
                      "a live entry must not be touched by Empty Trash")
        let afterManifest = try Data(contentsOf: SegmentLayout.manifestURL(captureDirectory: captureDir(idB)))
        XCTAssertEqual(beforeManifest, afterManifest, "the live entry's own files must be byte-identical")
        XCTAssertEqual(model.items.map(\.captureID), [idB])
    }

    /// Restore-race pin (task review, 2026-08-22). The unreadable-sidecar test above
    /// only pins the READ-THROW half of the per-item guard — dropping the whole
    /// `try? read(...)` call changes the counts, so that test catches it. It does NOT
    /// construct a state where the read SUCCEEDS but says `isTrashed == false`, which is
    /// the guard's actual purpose: refusing an item restored between the stale
    /// `trashed` snapshot and the loop reaching it. A mutant that keeps the read but
    /// drops the `isTrashed` condition would pass every other test in this file.
    ///
    /// Fixture: trash idA (model.trashed now lists it), then overwrite its sidecar
    /// directly back to not-trashed via the static write seam — deliberately WITHOUT
    /// another `rescan()`, so `model.trashed` still holds the stale row. `emptyTrash()`
    /// must re-read the sidecar itself and refuse, per the existing guard semantics
    /// (a refusal counts in `failed`, matching every other guard-refusal case in this
    /// file — asserted, not assumed).
    func testEmptyTrashRefusesAnEntryRestoredBetweenTheSnapshotAndTheLoop() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.trashEntry(idA)
        XCTAssertEqual(model.trashed.map(\.captureID), [idA])

        // Flip the sidecar back to not-trashed directly on disk, bypassing
        // `model.restoreEntry` (which would rescan and correctly drop idA from
        // `model.trashed`). This is exactly the race: a restore lands after the list
        // was drawn but before `emptyTrash()`'s own loop re-reads the disk.
        try EntryMetadataStore.write(
            EntryMetadata(), url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))
        XCTAssertFalse(try metadata(idA).isTrashed, "sidecar must actually say not-trashed for this to pin anything")

        let result = await model.emptyTrash()

        XCTAssertEqual(result, LibraryScreenModel.EmptyTrashResult(deleted: 0, failed: 1),
                       "the restored entry must be refused, not deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path),
                      "a restored entry's directory must survive Empty Trash")
    }

    /// An unreadable sidecar is the same per-item guard `deleteEntryPermanently` uses:
    /// the disk decides, not the stale row the button was drawn from. The other two
    /// trashed entries must still go.
    func testEmptyTrashCountsAnUnreadableSidecarAsFailedAndDeletesTheRest() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        try writeCapture(idC, capturedAt: 3_000)
        let model = model()
        await model.trashEntry(idA)
        await model.trashEntry(idB)
        await model.trashEntry(idC)

        let corruptURL = SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idC))
        let corrupt = Data("{ broken".utf8)
        try corrupt.write(to: corruptURL)
        // Deliberately no `rescan()` here: a rescan against a now-unreadable sidecar
        // decodes to `.defaults` (isTrashed == false) and would move idC out of
        // `trashed` entirely before `emptyTrash()` even runs — which would prove
        // nothing about the per-item guard this test exists to pin. Leaving the stale
        // `trashed` snapshot (from the trash calls above, when the sidecar was still
        // valid) in place is exactly the "over-include, guard refuses" case the brief
        // names: `emptyTrash()` must catch the now-unreadable sidecar itself.
        XCTAssertEqual(Set(model.trashed.map(\.captureID)), [idA, idB, idC])

        let result = await model.emptyTrash()

        XCTAssertEqual(result, LibraryScreenModel.EmptyTrashResult(deleted: 2, failed: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idB).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idC).path),
                      "the entry with the unreadable sidecar must be left alone")
        XCTAssertEqual(try Data(contentsOf: corruptURL), corrupt)
    }

    /// A staging failure on one item (sealed `capturesRoot`, `testDeleteNowReturnsFalseWhenStagingFails`'s
    /// technique) must not abort the loop — every other item still gets processed. With
    /// `capturesRoot` itself sealed, every rename in the batch fails the same way, so all
    /// three count as `failed` and all three directories survive.
    func testEmptyTrashStagingFailureOnOneItemDoesNotAbortTheRest() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        try writeCapture(idB, capturedAt: 2_000)
        let model = model()
        await model.trashEntry(idA)
        await model.trashEntry(idB)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: capturesRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: capturesRoot.path)
        }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: capturesRoot.path),
                      "running as root — permissions cannot be made to bite")

        let result = await model.emptyTrash()

        XCTAssertEqual(result, LibraryScreenModel.EmptyTrashResult(deleted: 0, failed: 2),
                       "every rename fails identically while capturesRoot is sealed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idA).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDir(idB).path))
    }

    /// Purge failure after a successful stage still counts as `deleted` — same
    /// one-way-door semantics as `deleteEntryPermanently`
    /// (`testDeleteNowSucceedsWhenTheStagedPurgeFails`'s technique): the rename is the
    /// deletion, the purge only reclaims bytes, and a purge failure retries at the next
    /// launch.
    func testEmptyTrashCountsAnItemAsDeletedEvenWhenItsPurgeFails() async throws {
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

        let result = await model.emptyTrash()

        XCTAssertEqual(result, LibraryScreenModel.EmptyTrashResult(deleted: 1, failed: 0),
                       "the rename landed — the entry is gone from the library regardless of the purge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDir(idA).path))
        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        let staged = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
        XCTAssertEqual(staged.count, 1, "the staged directory must survive a failed purge")
    }

    /// Nothing to do: no staging root is even created, matching `deleteEntryPermanently`'s
    /// "the disk decides" discipline applied to the whole batch at once.
    func testEmptyTrashOnAnEmptyTrashNoOps() async throws {
        try writeCapture(idA, capturedAt: 1_000)
        let model = model()
        await model.rescan()
        XCTAssertTrue(model.trashed.isEmpty)

        let result = await model.emptyTrash()

        XCTAssertEqual(result, LibraryScreenModel.EmptyTrashResult(deleted: 0, failed: 0))
        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path),
                       "an empty trash must not even create the staging root")
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
