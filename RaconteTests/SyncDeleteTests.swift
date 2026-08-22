import XCTest
import CloudKit
@testable import Raconte

/// M4 T11: trash, purge, delete ingest (design §5). Three layers, per the repo's usual
/// split:
/// - A source-scan pin (R3) that `acceptRemoteEntryDeletion` routes through
///   `StagedRemover` alone, never a raw `removeItem` or `RecoveryExecutor`.
/// - `SyncRecordExchange.acceptRemoteEntryDeletion` orchestration: real filesystem, no
///   CloudKit server.
/// - `LibraryScreenModel`'s three outbound callers (`deleteEntryPermanently`,
///   `emptyTrash`, `sweepTrash`), each wired through a real `SyncCoordinator` +
///   `FakeCloudEngine` (design §5's "the delete wins" pin: a queued revision upload for
///   a captureID being deleted is DROPPED, never sent).
final class SyncDeleteSourceTests: XCTestCase {
    private var syncIngestSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // RaconteTests
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("Raconte/Sync/SyncIngest.swift")
            return strippingComments(try String(contentsOf: url))
        }
    }

    /// R3: the scan is scoped to `acceptRemoteEntryDeletion`'s OWN body text, not the
    /// whole file — `SyncIngest.swift`'s staging-cleanup helpers (`EntryAssembler
    /// .assemble`'s `pruneUnexpectedStagingContents`, this task's own
    /// `discardParkedState`) legitimately call `FileManager.default.removeItem` on
    /// paths under `sync/staging/`, and a whole-file scan would false-positive on that
    /// legal usage. A per-function scope is what lets both rules hold at once.
    func testEntryDeletionIngestUsesStagedRemoverNotRawRemoval() throws {
        let source = try syncIngestSource
        guard let body = functionBody("func acceptRemoteEntryDeletion(captureID: String) async",
                                      in: source) else {
            XCTFail("could not locate acceptRemoteEntryDeletion(captureID:) in SyncIngest.swift")
            return
        }
        XCTAssertFalse(body.contains("removeItem("),
                       "sync-in delete must route through StagedRemover, never a raw removeItem")
        XCTAssertFalse(body.contains("RecoveryExecutor"),
                       "sync-in delete must never touch RecoveryExecutor's quarantine semantics")
    }

    /// The mutation check the brief names: if `acceptRemoteEntryDeletion` routed the
    /// capture removal through a raw `FileManager.default.removeItem(at:)` instead of
    /// `StagedRemover`, this scan must fail. Simulated directly against a string,
    /// rather than actually mutating production code, so the check runs on every CI
    /// pass rather than only when someone remembers to hand-mutate the file.
    func testScanWouldFailIfTheIngestPathUsedRawRemoval() throws {
        let mutated = """
            func acceptRemoteEntryDeletion(captureID: String) async {
                try? FileManager.default.removeItem(at: someCaptureDirectory)
            }
            """
        let body = try XCTUnwrap(functionBody("func acceptRemoteEntryDeletion(captureID: String) async",
                                              in: mutated))
        XCTAssertTrue(body.contains("removeItem("),
                     "fixture sanity: the mutated body really contains a raw removal")
    }
}

/// Extracts the textual body of the function beginning with `signature`, up to and
/// including its balanced closing brace — a per-function scope for a source scan (R3),
/// not a whole-file one. Brace matching over already comment-stripped source; assumes
/// no unmatched `{`/`}` inside a string literal in the scanned function, true for this
/// file as of this writing.
private func functionBody(_ signature: String, in source: String) -> String? {
    guard let sigRange = source.range(of: signature) else { return nil }
    guard let openBrace = source[sigRange.upperBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = openBrace
    while index < source.endIndex {
        let char = source[index]
        if char == "{" { depth += 1 }
        if char == "}" {
            depth -= 1
            if depth == 0 {
                return String(source[sigRange.lowerBound...index])
            }
        }
        index = source.index(after: index)
    }
    return nil
}

// MARK: - Ingest orchestration (SyncRecordExchange.acceptRemoteEntryDeletion)

final class SyncDeleteIngestTests: XCTestCase {
    private var containerRoot: URL!
    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private let deviceID = ULID.make()

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncDeleteIngest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }
    private var bookkeeping: SyncBookkeepingStore {
        SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
    }

    private func exchange(engine: FakeCloudEngine? = nil) async -> SyncRecordExchange {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let exchange = SyncRecordExchange(journalStore: journalStore,
                                          coverStore: JournalCoverStore(containerRoot: containerRoot),
                                          bookkeeping: bookkeeping, deviceID: deviceID,
                                          containerRoot: containerRoot)
        if let engine {
            await exchange.attach(engine: engine)
        }
        return exchange
    }

    private func writeFinalizedCapture(withRevision: Bool = false, ownMarkerStream: Bool = false,
                                       foreignMarkerDeviceID: String? = nil) async throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        var manifest = Manifest(captureID: captureID, createdAt: createdAt, state: .complete,
                                stateSeq: 1, stateUpdatedAt: createdAt, format: format)
        manifest.final = FinalRef(path: "final/recording.m4a", verifiedAt: createdAt, durationFrames: 48_000)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))

        let finalDirectory = SegmentLayout.finalDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 128).write(to: SegmentLayout.finalRecordingURL(
            captureDirectory: captureDirectory))

        try EntryMetadataStore.write(.defaults, url: SegmentLayout.entryMetadataURL(
            captureDirectory: captureDirectory))

        if withRevision {
            let revision = TranscriptRevision(id: ULID.make(), source: .machineLive, createdAt: createdAt,
                                              spans: [TranscriptSpan(text: "hello", anchor: .none)],
                                              parentID: nil)
            _ = try await TranscriptRevisionStore(capturesRoot: capturesRoot)
                .append(revision, captureID: captureID)
        }
        if ownMarkerStream {
            let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
            try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: SegmentLayout.markerLogURL(captureDirectory: captureDirectory))
        }
        if let foreignMarkerDeviceID {
            let transcriptDir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
            try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: SegmentLayout.foreignMarkerLogURL(
                captureDirectory: captureDirectory, deviceID: foreignMarkerDeviceID))
        }
    }

    // MARK: Behavioral: stage + purge

    func testAcceptRemoteEntryDeletionStagesAndPurgesTheCaptureDirectory() async throws {
        try await writeFinalizedCapture()
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path), "fixture sanity")

        await exchange().acceptRemoteEntryDeletion(captureID: captureID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "the capture must be gone from captures/")
        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        XCTAssertTrue(leftover.isEmpty, "present-then-purged: nothing should remain staged")
    }

    // MARK: Unknown / already-deleted — silent no-op

    func testAcceptRemoteEntryDeletionForUnknownCaptureIsASilentNoOp() async throws {
        // No fixture written at all — captureID was never seen locally.
        await exchange().acceptRemoteEntryDeletion(captureID: captureID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
        let stagingRoot = AppContainer.trashPendingRoot(containerRoot: containerRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path),
                      "nothing should ever have been staged for a capture that never existed")
    }

    func testAcceptRemoteEntryDeletionForAnAlreadyDeletedCaptureIsASilentNoOp() async throws {
        try await writeFinalizedCapture()
        let engine = FakeCloudEngine()
        let ex = await exchange(engine: engine)
        await ex.acceptRemoteEntryDeletion(captureID: captureID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path), "fixture sanity")

        // A redelivered deletion event, or a second device's independent purge already
        // reflected here — must not crash or do anything observable a second time.
        await ex.acceptRemoteEntryDeletion(captureID: captureID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))
    }

    // MARK: Parked state discard

    func testAcceptRemoteEntryDeletionDiscardsParkedState() async throws {
        // A parked revision this device could not apply yet because the capture had
        // not arrived (an ordinary in-flight park) — simulated directly at its known
        // location rather than via the full ingest path, matching this suite's usual
        // "test the effect, not the whole call chain" style for fixture setup.
        let stagingDir = AppContainer.syncStagingCaptureURL(containerRoot: containerRoot, captureID: captureID)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: AppContainer.syncStagingPendingRevisionsURL(
            containerRoot: containerRoot, captureID: captureID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDir.path), "fixture sanity")

        await exchange().acceptRemoteEntryDeletion(captureID: captureID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path),
                      "sync/staging/<captureID>/ must be gone — nothing may revive a deleted entry's parked state")
    }

    // MARK: Pending-work drop (design §5, "the delete wins") — fake-engine

    func testAcceptRemoteEntryDeletionDropsQueuedRevisionUploadForTheDeletedCapture() async throws {
        try await writeFinalizedCapture(withRevision: true)
        let revisionID = try XCTUnwrap(TranscriptRevisionStore.loadChain(
            captureDirectory: captureDirectory)?.revisions.first?.id)
        let engine = FakeCloudEngine()
        let ex = await exchange(engine: engine)

        await ex.acceptRemoteEntryDeletion(captureID: captureID)

        let dropped = await engine.droppedNameSet
        XCTAssertTrue(dropped.contains(.revision(id: revisionID)),
                     "a queued revision upload for the deleted capture must be dropped, not sent")
        XCTAssertTrue(dropped.contains(.audio(captureID: captureID)))
        let deleted = await engine.deletedNames
        XCTAssertTrue(deleted.isEmpty, "children never get an explicit CK delete — they cascade with the Entry")
    }

    func testAcceptRemoteEntryDeletionDropsMarkerStreamFamily() async throws {
        let foreignDeviceID = ULID.make()
        try await writeFinalizedCapture(ownMarkerStream: true, foreignMarkerDeviceID: foreignDeviceID)
        let engine = FakeCloudEngine()
        let ex = await exchange(engine: engine)

        await ex.acceptRemoteEntryDeletion(captureID: captureID)

        let dropped = await engine.droppedNameSet
        XCTAssertTrue(dropped.contains(.markerStream(captureID: captureID, deviceID: DeviceIdentity.stable())))
        XCTAssertTrue(dropped.contains(.markerStream(captureID: captureID, deviceID: foreignDeviceID)))
    }

    // MARK: Ledger + system-fields retirement

    func testAcceptRemoteEntryDeletionClearsLedgerAndSystemFieldsForEntryAndFamily() async throws {
        try await writeFinalizedCapture(withRevision: true)
        let revisionID = try XCTUnwrap(TranscriptRevisionStore.loadChain(
            captureDirectory: captureDirectory)?.revisions.first?.id)
        let entryName = SyncRecordName.entry(captureID: captureID)
        let audioName = SyncRecordName.audio(captureID: captureID)
        let revisionName = SyncRecordName.revision(id: revisionID)
        let store = bookkeeping
        for name in [entryName, audioName, revisionName] {
            try await store.recordUpload(UploadedDigest(sha256: "abc", bytes: 1), for: name.rawValue)
            try await store.saveSystemFields(Data("archived".utf8), for: name.rawValue)
        }
        // An unrelated record must survive untouched.
        let otherID = ULID.make()
        let other = SyncRecordName.entry(captureID: otherID)
        try await store.recordUpload(UploadedDigest(sha256: "def", bytes: 2), for: other.rawValue)

        await exchange().acceptRemoteEntryDeletion(captureID: captureID)

        let ledger = await store.ledger()
        XCTAssertNil(ledger[entryName.rawValue])
        XCTAssertNil(ledger[audioName.rawValue])
        XCTAssertNil(ledger[revisionName.rawValue])
        XCTAssertNotNil(ledger[other.rawValue], "an unrelated capture's ledger entry is untouched")
        let entryFields = await store.systemFields(for: entryName.rawValue)
        let audioFields = await store.systemFields(for: audioName.rawValue)
        XCTAssertNil(entryFields)
        XCTAssertNil(audioFields)
    }
}

// MARK: - Outbound wiring (LibraryScreenModel's three permanent-delete callers)

@MainActor
final class LibraryScreenModelDeleteSyncTests: XCTestCase {
    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let idA = ULID.make()
    private let idB = ULID.make()

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteLibraryDeleteSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private func model() -> LibraryScreenModel {
        LibraryScreenModel(capturesRoot: capturesRoot, journalsContainerRoot: containerRoot)
    }

    private func coordinator(engine: FakeCloudEngine) -> SyncCoordinator {
        SyncCoordinator(bookkeeping: SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot)),
                        scanner: SyncTreeScanner(containerRoot: containerRoot, deviceID: ULID.make()),
                        engine: engine)
    }

    private func captureDir(_ id: String) -> URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
    }

    /// A finalized, trashed capture with one revision — enough content to exercise
    /// the family (audio + revision) on the deletion paths under test.
    @discardableResult
    private func writeTrashedFinalizedCapture(_ id: String, trashedAt: Date) async throws -> String {
        let directory = captureDir(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        var manifest = Manifest(captureID: id, createdAt: createdAt, state: .complete,
                                stateSeq: 1, stateUpdatedAt: createdAt, format: format)
        manifest.final = FinalRef(path: "final/recording.m4a", verifiedAt: createdAt, durationFrames: 48_000)
        try CaptureCoding.encoder().encode(manifest).write(to: SegmentLayout.manifestURL(captureDirectory: directory))
        let finalDirectory = SegmentLayout.finalDirectory(captureDirectory: directory)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 64).write(to: SegmentLayout.finalRecordingURL(captureDirectory: directory))

        // Appended BEFORE the trash stamp — `TranscriptRevisionStore.append` refuses
        // (`.trashedCapture`) once the sidecar reports `trashedAt != nil`.
        let revisionID = ULID.make()
        let revision = TranscriptRevision(id: revisionID, source: .machineLive, createdAt: createdAt,
                                          spans: [TranscriptSpan(text: "hi", anchor: .none)], parentID: nil)
        _ = try await TranscriptRevisionStore(capturesRoot: capturesRoot).append(revision, captureID: id)

        try EntryMetadataStore.write(EntryMetadata(trashedAt: trashedAt),
                                     url: SegmentLayout.entryMetadataURL(captureDirectory: directory))
        return revisionID
    }

    // MARK: deleteEntryPermanently ("Delete Now")

    func testDeleteEntryPermanentlyEnqueuesEntryDeleteAndDropsFamilySaves() async throws {
        let revisionID = try await writeTrashedFinalizedCapture(idA, trashedAt: Date())
        let engine = FakeCloudEngine()
        let m = model()
        m.attach(syncHooks: coordinator(engine: engine))

        let deleted = await m.deleteEntryPermanently(idA)

        XCTAssertTrue(deleted)
        let deletes = await engine.deletedNames
        XCTAssertEqual(deletes, [[.entry(captureID: idA)]],
                       "only the Entry gets a real CK delete — children cascade server-side")
        let dropped = await engine.droppedNameSet
        XCTAssertTrue(dropped.contains(.audio(captureID: idA)))
        XCTAssertTrue(dropped.contains(.revision(id: revisionID)))
    }

    /// Layer-1 no-op: an entry that is not (or no longer) trashed must fire no sync
    /// calls at all — `deleteEntryPermanently` refuses before ever staging.
    func testDeleteEntryPermanentlyOnAnUntrashedEntryFiresNoSyncCalls() async throws {
        _ = try await writeTrashedFinalizedCapture(idA, trashedAt: Date())
        try EntryMetadataStore.write(.defaults, url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(idA)))
        let engine = FakeCloudEngine()
        let m = model()
        m.attach(syncHooks: coordinator(engine: engine))

        let deleted = await m.deleteEntryPermanently(idA)

        XCTAssertFalse(deleted)
        let deletes = await engine.deletedNames
        let dropped = await engine.droppedNames
        XCTAssertTrue(deletes.isEmpty)
        XCTAssertTrue(dropped.isEmpty)
    }

    // MARK: emptyTrash (bulk)

    func testEmptyTrashEnqueuesEntryDeleteForEveryTrashedEntry() async throws {
        _ = try await writeTrashedFinalizedCapture(idA, trashedAt: Date())
        _ = try await writeTrashedFinalizedCapture(idB, trashedAt: Date())
        let engine = FakeCloudEngine()
        let m = model()
        m.attach(syncHooks: coordinator(engine: engine))
        await m.rescan()

        let result = await m.emptyTrash()

        XCTAssertEqual(result.deleted, 2)
        let deletes = await engine.deletedNames.flatMap { $0 }
        XCTAssertEqual(Set(deletes), [.entry(captureID: idA), .entry(captureID: idB)])
    }

    // MARK: sweepTrash (30-day launch sweep)

    func testSweepTrashEnqueuesEntryDeleteForExpiredEntries() async throws {
        let longAgo = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        _ = try await writeTrashedFinalizedCapture(idA, trashedAt: longAgo)
        let engine = FakeCloudEngine()
        let m = model()
        m.attach(syncHooks: coordinator(engine: engine))

        await m.sweepTrash()

        let deletes = await engine.deletedNames
        XCTAssertEqual(deletes, [[.entry(captureID: idA)]])
        let dropped = await engine.droppedNameSet
        XCTAssertTrue(dropped.contains(.audio(captureID: idA)))
    }

    // MARK: Independent devices — local purge + independent sweep, no interference

    /// Design §5: "both devices sweeping independently ... is fine." Two SEPARATE
    /// containers (standing in for two devices), each holding its own copy of the
    /// same captureID's content. Device A permanently deletes it via "Delete Now";
    /// device B, entirely independently, sweeps it past retention. Neither knows
    /// about the other — this pins that BOTH reach `enqueueDeletes` cleanly with no
    /// crash or cross-talk; the actual "second CK delete is a no-op" guarantee is
    /// CloudKit server behavior this fake cannot model, but the app-level half (each
    /// device independently and safely queuing its own delete) is exactly what this
    /// asserts.
    func testLocalPurgeOnOneDeviceAndIndependentSweepOnAnotherBothEnqueueDeleteCleanly() async throws {
        let containerRootA = containerRoot!
        let containerRootB = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteLibraryDeleteSync-deviceB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: AppContainer.capturesRoot(containerRoot: containerRootB),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: containerRootB) }

        _ = try await writeTrashedFinalizedCapture(idA, trashedAt: Date())
        let modelA = model()
        let engineA = FakeCloudEngine()
        modelA.attach(syncHooks: coordinator(engine: engineA))

        let modelB = LibraryScreenModel(capturesRoot: AppContainer.capturesRoot(containerRoot: containerRootB),
                                        journalsContainerRoot: containerRootB)
        let directoryB = SegmentLayout.captureDirectory(
            capturesRoot: AppContainer.capturesRoot(containerRoot: containerRootB), captureID: idA)
        try FileManager.default.createDirectory(at: directoryB, withIntermediateDirectories: true)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let format = AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false, bytesPerFrame: 4)
        var manifest = Manifest(captureID: idA, createdAt: createdAt, state: .complete,
                                stateSeq: 1, stateUpdatedAt: createdAt, format: format)
        manifest.final = FinalRef(path: "final/recording.m4a", verifiedAt: createdAt, durationFrames: 48_000)
        try CaptureCoding.encoder().encode(manifest).write(to: SegmentLayout.manifestURL(captureDirectory: directoryB))
        try FileManager.default.createDirectory(at: SegmentLayout.finalDirectory(captureDirectory: directoryB),
                                                 withIntermediateDirectories: true)
        try Data(repeating: 0xEF, count: 32).write(to: SegmentLayout.finalRecordingURL(captureDirectory: directoryB))
        let longAgo = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        try EntryMetadataStore.write(EntryMetadata(trashedAt: longAgo),
                                     url: SegmentLayout.entryMetadataURL(captureDirectory: directoryB))
        let engineB = FakeCloudEngine()
        let bookkeepingB = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRootB))
        let coordinatorB = SyncCoordinator(bookkeeping: bookkeepingB,
                                           scanner: SyncTreeScanner(containerRoot: containerRootB,
                                                                    deviceID: ULID.make()),
                                           engine: engineB)
        modelB.attach(syncHooks: coordinatorB)

        let deletedOnA = await modelA.deleteEntryPermanently(idA)
        await modelB.sweepTrash()

        XCTAssertTrue(deletedOnA)
        let deletesA = await engineA.deletedNames
        let deletesB = await engineB.deletedNames
        XCTAssertEqual(deletesA, [[.entry(captureID: idA)]])
        XCTAssertEqual(deletesB, [[.entry(captureID: idA)]])
        _ = containerRootA
    }
}
