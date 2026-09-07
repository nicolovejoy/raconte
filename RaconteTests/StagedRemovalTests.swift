import XCTest
@testable import Raconte

/// `StagedRemover` (#25): atomic rename of a whole capture directory into
/// `trash-pending/`, then a purge. This step adds the mechanism only — nothing calls it
/// yet, so behaviour on disk is unchanged; these tests exercise the type directly.
final class StagedRemovalTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private var trashPendingRoot: URL { AppContainer.trashPendingRoot(containerRoot: containerRoot) }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedRemoval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
    }

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    private func remover(mintStagingID: (@Sendable () -> String)? = nil) -> StagedRemover {
        if let mintStagingID {
            return StagedRemover(capturesRoot: capturesRoot, containerRoot: containerRoot,
                                 mintStagingID: mintStagingID)
        }
        return StagedRemover(capturesRoot: capturesRoot, containerRoot: containerRoot)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// A finalized capture: an `.m4a` and a transcript, i.e. everything
    /// `holdsIrreplaceableArtifacts` protects. Fixture shape copied from
    /// `TrashSweeperTests.swift:8-47`.
    @discardableResult
    private func writeCapture(_ id: String, trashedAt: Date?) throws -> URL {
        let dir = captureDir(id)
        let final = SegmentLayout.finalDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64)
            .write(to: SegmentLayout.finalRecordingURL(captureDirectory: dir))
        let transcript = SegmentLayout.transcriptDirectory(captureDirectory: dir)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: SegmentLayout.liveTranscriptURL(captureDirectory: dir))
        if let trashedAt {
            try EntryMetadataStore.write(EntryMetadata(trashedAt: trashedAt),
                                         url: SegmentLayout.entryMetadataURL(captureDirectory: dir))
        }
        return dir
    }

    // MARK: - 1.1 / 1.2 — stage moves the whole directory, and only that directory

    func testStageRenamesTheWholeDirectoryOutOfCapturesRoot() throws {
        try writeCapture("idA", trashedAt: now)
        let name = try remover().stage(captureID: "idA")

        XCTAssertFalse(exists(captureDir("idA")), "captures/idA must be gone")
        let stagedDir = AppContainer.trashPendingURL(containerRoot: containerRoot, name: name)
        XCTAssertTrue(exists(SegmentLayout.finalRecordingURL(captureDirectory: stagedDir)))
        let metadata = try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(captureDirectory: stagedDir))
        XCTAssertNotNil(metadata.trashedAt)
    }

    func testStageLeavesCapturesRootOtherwiseUntouched() throws {
        try writeCapture("idA", trashedAt: now)
        try writeCapture("idB", trashedAt: nil)

        _ = try remover().stage(captureID: "idA")

        XCTAssertTrue(exists(captureDir("idB")), "captures/idB must be untouched")
    }

    // MARK: - 1.3 / 1.4 — invisibility to every scanner

    func testStagedDirectoryIsInvisibleToDirectorySnapshotGather() throws {
        try writeCapture("idA", trashedAt: now)
        _ = try remover().stage(captureID: "idA")

        let snapshot = DirectorySnapshot.gather(capturesRoot: capturesRoot)
        XCTAssertTrue(snapshot.captures.isEmpty)
    }

    func testStagedDirectoryIsInvisibleToLibraryScanAndToTrashSweeperGather() async throws {
        try writeCapture("idA", trashedAt: now)
        _ = try remover().stage(captureID: "idA")

        let scanResult = await LibraryScanner(capturesRoot: capturesRoot, containerRoot: containerRoot)
            .scan()
        XCTAssertTrue(scanResult.items.isEmpty)
        XCTAssertTrue(scanResult.skipped.isEmpty)

        let candidates = TrashSweeper.gather(capturesRoot: capturesRoot)
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - 1.5 — the #25 assertion

    func testStageFailsCleanlyWhenCapturesRootIsUnwritable() throws {
        try writeCapture("idA", trashedAt: now)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: capturesRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: capturesRoot.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: capturesRoot.path),
                      "running as root — permissions cannot be made to bite")

        XCTAssertThrowsError(try remover().stage(captureID: "idA")) { error in
            guard case StagedRemovalError.posix = error else {
                return XCTFail("expected .posix, got \(error)")
            }
        }

        let metadata = try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir("idA")))
        XCTAssertNotNil(metadata.trashedAt, "entry.json must still decode with trashedAt set")
        XCTAssertTrue(exists(SegmentLayout.finalRecordingURL(captureDirectory: captureDir("idA"))))
        if exists(trashPendingRoot) {
            let children = try FileManager.default.contentsOfDirectory(atPath: trashPendingRoot.path)
            XCTAssertTrue(children.isEmpty, "trash-pending/ must be empty or absent")
        }
    }

    // MARK: - 1.6 — missing source

    func testStageOfAMissingCaptureThrowsCaptureDirectoryMissing() {
        XCTAssertThrowsError(try remover().stage(captureID: "nope")) { error in
            XCTAssertEqual(error as? StagedRemovalError, .captureDirectoryMissing)
        }
    }

    // MARK: - 1.7 — collision-proof naming

    func testTwoStagingsOfTheSameCaptureIDCannotCollide() throws {
        // Capture the counter mutation via a class box since the closure must be @Sendable.
        final class Box: @unchecked Sendable {
            var counter = 0
            func next() -> String { counter += 1; return "COUNTER\(counter)" }
        }
        let box = Box()
        let mint: @Sendable () -> String = { box.next() }

        try writeCapture("idA", trashedAt: now)
        let firstName = try remover(mintStagingID: mint).stage(captureID: "idA")

        try writeCapture("idA", trashedAt: now)
        let secondName = try remover(mintStagingID: mint).stage(captureID: "idA")

        XCTAssertNotEqual(firstName, secondName)
        let children = try FileManager.default.contentsOfDirectory(atPath: trashPendingRoot.path)
        XCTAssertEqual(Set(children), Set([firstName, secondName]))
        for name in [firstName, secondName] {
            let dir = AppContainer.trashPendingURL(containerRoot: containerRoot, name: name)
            XCTAssertTrue(exists(SegmentLayout.finalRecordingURL(captureDirectory: dir)))
        }
    }

    // MARK: - 1.8–1.11 — purge

    func testPurgeRemovesEveryStagedDirectory() throws {
        try writeCapture("idA", trashedAt: now)
        try writeCapture("idB", trashedAt: now)
        let r = remover()
        _ = try r.stage(captureID: "idA")
        _ = try r.stage(captureID: "idB")

        let result = r.purge()

        XCTAssertEqual(result.removed.count, 2)
        XCTAssertTrue(result.failed.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: trashPendingRoot.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPurgeReportsWhatItCannotRemoveAndLeavesItForNextLaunch() throws {
        try writeCapture("idA", trashedAt: now)
        let r = remover()
        let name = try r.stage(captureID: "idA")

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: trashPendingRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trashPendingRoot.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: trashPendingRoot.path),
                      "running as root — permissions cannot be made to bite")

        let result = r.purge()

        XCTAssertEqual(result.failed, [name])
        XCTAssertTrue(exists(AppContainer.trashPendingURL(containerRoot: containerRoot, name: name)))
    }

    func testPurgeOverAnAbsentStagingRootIsAnEmptySuccess() {
        let result = remover().purge()
        XCTAssertTrue(result.isEmpty)
    }

    func testPurgeIsIdempotent() throws {
        try writeCapture("idA", trashedAt: now)
        let r = remover()
        _ = try r.stage(captureID: "idA")

        let first = r.purge()
        let second = r.purge()

        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
    }

    // MARK: - 1.12 — backup exclusion

    func testStagingRootIsExcludedFromBackup() throws {
        // Probe the actual capability first: on GitHub Actions macOS runners, backupd is
        // unreachable over XPC — "_CSBackupIsItemExcluded_Remote(): XPC error for
        // connection com.apple.backupd.sandbox.xpc: Connection invalid" (observed
        // 2026-08-07) — so isExcludedFromBackup can neither be set nor read back there,
        // independent of what StagedRemover does. Measure the environment rather than
        // assume it, so any future sandbox with the same limitation is covered too.
        let probeDir = containerRoot.appendingPathComponent("backup-probe-\(UUID().uuidString)",
                                                              isDirectory: true)
        try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        var probeURL = probeDir
        var probeValues = URLResourceValues()
        probeValues.isExcludedFromBackup = true
        var probeSetSucceeded = true
        do {
            try probeURL.setResourceValues(probeValues)
        } catch {
            probeSetSucceeded = false
        }
        let probeReadBack = try? probeURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        try XCTSkipIf(!probeSetSucceeded || probeReadBack?.isExcludedFromBackup != true,
                      "backupd unreachable in this environment — the backup-exclusion flag "
                      + "cannot be measured (seen on GitHub Actions runners)")

        try writeCapture("idA", trashedAt: now)
        _ = try remover().stage(captureID: "idA")

        let values = try trashPendingRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - #81: quarantine (repair primitive, never a deletion)

    /// Mirrors `testStageRenamesTheWholeDirectoryOutOfCapturesRoot` — same one-way
    /// `rename(2)`, different destination. The garbage `entry.json` is the whole reason
    /// this exists (#81): quarantine must move it intact, not attempt to read or repair it.
    func testQuarantineMovesTheWholeCaptureDirectoryOutOfCaptures() throws {
        let id = "idA"
        try writeCapture(id, trashedAt: nil)
        try Data("{ not json".utf8).write(
            to: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(id)))

        let name = try remover().quarantine(captureID: id)

        XCTAssertFalse(exists(captureDir(id)), "captures/idA must be gone")
        let moved = AppContainer.quarantineURL(containerRoot: containerRoot, name: name)
        XCTAssertTrue(exists(SegmentLayout.finalRecordingURL(captureDirectory: moved)),
                      "the audio must survive intact under quarantine/")
        XCTAssertTrue(name.hasSuffix("-\(id)"))
    }

    func testQuarantineOfAMissingCaptureThrowsCaptureDirectoryMissing() {
        XCTAssertThrowsError(try remover().quarantine(captureID: "nope")) { error in
            XCTAssertEqual(error as? StagedRemovalError, .captureDirectoryMissing)
        }
    }

    /// `purge()` only ever visits `trash-pending/` — a quarantined capture must survive
    /// a purge untouched, since quarantine is a repair holding pen, not a deletion stage.
    func testPurgeLeavesQuarantineAlone() throws {
        let id = "idA"
        let otherID = "idB"
        try writeCapture(id, trashedAt: nil)
        try writeCapture(otherID, trashedAt: now)
        let r = remover()

        _ = try r.quarantine(captureID: id)
        _ = try r.stage(captureID: otherID)
        let result = r.purge()

        XCTAssertEqual(result.removed.count, 1, "purge must have actually run, on the staged capture")
        XCTAssertTrue(result.failed.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: trashPendingRoot.path)
        XCTAssertTrue(remaining.isEmpty, "trash-pending/ must be empty after purge")

        let quarantined = try FileManager.default.contentsOfDirectory(
            atPath: AppContainer.quarantineRoot(containerRoot: containerRoot).path)
        XCTAssertEqual(quarantined.count, 1)
    }

    // MARK: - 1.13 — crash-then-next-launch sweep

    func testStageThenCrashLeavesNothingScannableAndIsSweptByTheNextPurge() throws {
        try writeCapture("idA", trashedAt: now)
        _ = try remover().stage(captureID: "idA")
        // No purge here — this *is* the crash.

        XCTAssertTrue(DirectorySnapshot.gather(capturesRoot: capturesRoot).captures.isEmpty)

        // A fresh launch: a brand new StagedRemover value.
        let nextLaunch = remover()
        let result = nextLaunch.purge()

        XCTAssertFalse(result.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: trashPendingRoot.path)
        XCTAssertTrue(remaining.isEmpty)
        let captures = try FileManager.default.contentsOfDirectory(atPath: capturesRoot.path)
        XCTAssertTrue(captures.isEmpty)
        XCTAssertTrue(DirectorySnapshot.gather(capturesRoot: capturesRoot).captures.isEmpty)
    }
}
