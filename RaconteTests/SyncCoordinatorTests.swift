import XCTest
@testable import Raconte

/// M4 T4: the coordinator that turns "what is on disk" + "what was last uploaded" into
/// engine enqueues, driven here entirely through `FakeCloudEngine`.
///
/// **No CloudKit anywhere in this file, by construction** — `CloudEngineControl` takes
/// no CloudKit types, so a test can conform to it without the framework being reachable.
/// The real conformer (`CloudKitEngineControl`) is never built by the suite; the
/// composition root refuses to build it under XCTest at all
/// (`SyncCoordinator.live()`), which matters because `RaconteTests` is app-hosted and
/// therefore launches the real `ContentView`.
final class SyncCoordinatorTests: XCTestCase {

    private var containerRoot: URL!
    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private let deviceID = ULID.make()
    private let format = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32,
        interleaved: false, bytesPerFrame: 4)

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    // MARK: Fixtures

    private func bookkeeping() -> SyncBookkeepingStore {
        SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
    }

    private func scanner() -> SyncTreeScanner {
        SyncTreeScanner(containerRoot: containerRoot, deviceID: deviceID)
    }

    private func coordinator(_ store: SyncBookkeepingStore, _ engine: FakeCloudEngine) -> SyncCoordinator {
        SyncCoordinator(bookkeeping: store, scanner: scanner(), engine: engine)
    }

    /// Two finalized captures plus a journal — cardinality >= 2 in both shapes, so an
    /// implementation that enqueued only the first artifact, or only captures, or only
    /// journals, still fails.
    private let idOne = ULID.make()
    private let idTwo = ULID.make()
    private let journalID = ULID.make()

    private func buildArchive() throws {
        try writeJournal(journalID, name: "Practice")
        try writeFinalizedCapture(idOne, m4a: Data(repeating: 0xAB, count: 128))
        try writeFinalizedCapture(idTwo, m4a: Data(repeating: 0xCD, count: 256))
    }

    private func writeJournal(_ id: String, name: String) throws {
        let journal = Journal(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try JournalStore.encode(JournalRegistry(journals: [journal]))
            .write(to: AppContainer.journalsURL(containerRoot: containerRoot))
    }

    private func writeFinalizedCapture(_ id: String, m4a: Data) throws {
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        var manifest = Manifest(captureID: id, createdAt: createdAt, state: .complete,
                                stateSeq: 1, stateUpdatedAt: createdAt, format: format)
        manifest.final = FinalRef(path: "final/recording.m4a",
                                  verifiedAt: createdAt, durationFrames: 48_000)
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: directory))

        let finalDirectory = SegmentLayout.finalDirectory(captureDirectory: directory)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        try m4a.write(to: SegmentLayout.finalRecordingURL(captureDirectory: directory))
    }

    // MARK: launch(): first enable

    /// The initial-upload path (design §3, "belt and braces"): on first enable the
    /// ledger is empty, so the reconciliation scan must enqueue the entire existing
    /// archive. This is the test the brief's mutation check targets — deleting the
    /// reconciliation call from `launch()` leaves an app that syncs only what changes
    /// *after* it was installed, silently abandoning everything already recorded.
    func testLaunchWithEmptyLedgerEnqueuesTheWholeArchive() async throws {
        try buildArchive()
        let engine = FakeCloudEngine()
        await coordinator(bookkeeping(), engine).launch()

        let expected = Set(scanner().scan().artifacts.map(\.name))
        let enqueued = await engine.savedNameSet
        let saveCalls = await engine.saveCallCount
        XCTAssertFalse(expected.isEmpty, "fixture must produce artifacts or this test is vacuous")
        XCTAssertEqual(enqueued, expected)
        XCTAssertEqual(saveCalls, 1, "one batched enqueue, not one call per artifact")
    }

    /// The other half of the diff: an archive already fully uploaded enqueues NOTHING.
    /// Without this, an implementation that ignored the ledger and enqueued every
    /// scanned artifact on every launch would pass the test above.
    func testLaunchWithAFullyUploadedLedgerEnqueuesNothing() async throws {
        try buildArchive()
        let store = bookkeeping()
        for artifact in scanner().scan().artifacts {
            try await store.recordUpload(UploadedDigest(sha256: artifact.sha256, bytes: artifact.bytes),
                                         for: artifact.name.rawValue)
        }

        let engine = FakeCloudEngine()
        await coordinator(store, engine).launch()

        let enqueued = await engine.savedNameSet
        let saveCalls = await engine.saveCallCount
        XCTAssertEqual(enqueued, [])
        XCTAssertEqual(saveCalls, 0, "an empty plan must not call the engine at all")
    }

    /// Only what actually changed. Pins that `launch()` reconciles rather than
    /// re-uploading the archive whenever the ledger is merely non-empty.
    func testLaunchEnqueuesOnlyTheArtifactsWhoseDigestChanged() async throws {
        try buildArchive()
        let store = bookkeeping()
        let artifacts = scanner().scan().artifacts
        for artifact in artifacts {
            try await store.recordUpload(UploadedDigest(sha256: artifact.sha256, bytes: artifact.bytes),
                                         for: artifact.name.rawValue)
        }
        // One artifact's content moves on disk after that upload.
        try writeJournal(journalID, name: "Practice, renamed")

        let engine = FakeCloudEngine()
        await coordinator(store, engine).launch()

        let enqueued = await engine.savedNameSet
        XCTAssertEqual(enqueued, [.journal(id: journalID)])
    }

    // MARK: launch(): engine boot

    func testLaunchStartsTheEngineWithNoStateWhenNoneWasEverSaved() async throws {
        let engine = FakeCloudEngine()
        await coordinator(bookkeeping(), engine).launch()

        let startCalls = await engine.startCallCount
        let started = await engine.startedWith
        XCTAssertEqual(startCalls, 1)
        XCTAssertEqual(started, [nil])
    }

    /// The full round trip the engine actually performs: it emits an opaque state blob,
    /// which must be durable before the next launch resumes from it. `CKSyncEngine` owns
    /// cursors and change tokens — losing this blob costs a full resync.
    func testEngineStateRoundTripsThroughBookkeepingAcrossLaunches() async throws {
        let store = bookkeeping()
        let firstEngine = FakeCloudEngine(persistState: { [store] data in
            try? await store.saveEngineState(data)
        })
        await coordinator(store, firstEngine).launch()

        let blob = Data("opaque-ck-sync-engine-state".utf8)
        await firstEngine.emitStateUpdate(blob)

        // A fresh coordinator + engine, standing in for the next app launch.
        let secondEngine = FakeCloudEngine()
        await coordinator(store, secondEngine).launch()

        let started = await secondEngine.startedWith
        XCTAssertEqual(started, [blob])
    }

    // MARK: Composition root

    /// The one guard standing between this suite and the owner's live iCloud account.
    /// `RaconteTests` is app-hosted, so every run of every test in this project launches
    /// `ContentView`, which calls `SyncCoordinator.live()` — if that ever stopped
    /// refusing under XCTest, CI and every local run would open a real `CKSyncEngine`
    /// against the real container. This test asserts the refusal from inside the exact
    /// environment it is about.
    @MainActor
    func testTheCompositionRootRefusesToBuildALiveEngineUnderTheTestRunner() {
        XCTAssertTrue(SyncCoordinator.isHostedByTestRunner,
                      "this test is only meaningful while it runs under XCTest")
        // A throwaway library, so this test's own construction can never touch the real
        // container even if the guard were removed — the guard is what is under test, not
        // where the stores point.
        XCTAssertNil(SyncCoordinator.live(library: LibraryScreenModel(capturesRoot: capturesRoot)))
    }

    /// The gate's whole truth table. Both of its inputs read the running process and so
    /// cannot be varied inside a test — which is exactly why the decision they feed is
    /// pure and this can be pinned at all.
    ///
    /// The entitlement half is not redundant with the test-runner half: a macOS build
    /// made with `Raconte-nocloud.entitlements` (CI's recipe, and the tempting
    /// workaround for the owner-smoke build now that the shipping entitlements need a
    /// real certificate) is signed WITHOUT the iCloud keys yet runs in no test
    /// environment at all. `CKContainer(identifier:)` raises an Objective-C exception
    /// for an identifier the binary does not claim, and Swift cannot catch one — so this
    /// has to refuse before the engine is ever constructed.
    func testSyncIsRefusedUnlessBothOutsideATestRunnerAndProperlyEntitled() {
        XCTAssertTrue(SyncCoordinator.shouldSync(hostedByTestRunner: false, hasCloudKitEntitlement: true))
        XCTAssertFalse(SyncCoordinator.shouldSync(hostedByTestRunner: true, hasCloudKitEntitlement: true))
        XCTAssertFalse(SyncCoordinator.shouldSync(hostedByTestRunner: false, hasCloudKitEntitlement: false))
        XCTAssertFalse(SyncCoordinator.shouldSync(hostedByTestRunner: true, hasCloudKitEntitlement: false))
    }

    // MARK: noteLocalChange

    func testNoteLocalChangeEnqueuesExactlyThatRecord() async throws {
        let engine = FakeCloudEngine()
        let coordinator = coordinator(bookkeeping(), engine)

        await coordinator.noteLocalChange(.journal(id: journalID))

        let enqueued = await engine.savedNames
        let deleteCalls = await engine.deleteCallCount
        let startCalls = await engine.startCallCount
        XCTAssertEqual(enqueued, [[.journal(id: journalID)]])
        XCTAssertEqual(deleteCalls, 0)
        XCTAssertEqual(startCalls, 0, "a change hook must not boot the engine")
    }

    /// Two different hooks firing must produce two enqueues, not one coalesced or
    /// overwritten one.
    func testTwoLocalChangesEachReachTheEngine() async throws {
        let engine = FakeCloudEngine()
        let coordinator = coordinator(bookkeeping(), engine)

        await coordinator.noteLocalChange(.entry(captureID: idOne))
        await coordinator.noteLocalChange(.audio(captureID: idOne))

        let enqueued = await engine.savedNames
        XCTAssertEqual(enqueued, [[.entry(captureID: idOne)], [.audio(captureID: idOne)]])
    }

    // MARK: noteLocalDelete (#80, B2)

    /// A local delete must reach `enqueueDeletes`, never `enqueueSaves` — a record that
    /// is gone is not the same event as one whose content changed (`SyncHooks
    /// .noteLocalDelete`'s own doc comment). `JournalStore.deleteJournal` already fires
    /// this hook (B1); this pins the coordinator's half of the wire.
    func testNoteLocalDeleteEnqueuesExactlyThatRecordAsADelete() async throws {
        let engine = FakeCloudEngine()
        let coordinator = coordinator(bookkeeping(), engine)

        await coordinator.noteLocalDelete(.journal(id: journalID))

        let deleted = await engine.deletedNames
        let saved = await engine.savedNames
        let startCalls = await engine.startCallCount
        XCTAssertEqual(deleted, [[.journal(id: journalID)]])
        XCTAssertEqual(saved, [], "a delete must never also enqueue a save")
        XCTAssertEqual(startCalls, 0, "a delete hook must not boot the engine")
    }

    /// Gate finding (Minor 3): the deleted record's upload-ledger entry and archived
    /// system fields describe something that is gone from this device. Retiring them
    /// cannot cost an upload — `SyncPlanner.reconcile` iterates the DISK scan, which no
    /// longer contains the artifact — and leaving them means a resurrected record would
    /// be pushed against a change tag from before its own deletion.
    func testNoteLocalDeleteRetiresThatRecordsBookkeeping() async throws {
        let store = bookkeeping()
        let name = SyncRecordName.journal(id: journalID)
        try await store.recordUpload(UploadedDigest(sha256: "abc", bytes: 12), for: name.rawValue)
        try await store.saveSystemFields(Data("archived".utf8), for: name.rawValue)
        // A second record, to pin that this retires ONE name rather than wiping the store.
        let other = SyncRecordName.journal(id: ULID.make())
        try await store.recordUpload(UploadedDigest(sha256: "def", bytes: 34), for: other.rawValue)
        try await store.saveSystemFields(Data("kept".utf8), for: other.rawValue)

        await coordinator(store, FakeCloudEngine()).noteLocalDelete(name)

        let ledger = await store.ledger()
        let retiredFields = await store.systemFields(for: name.rawValue)
        let keptFields = await store.systemFields(for: other.rawValue)
        XCTAssertNil(ledger[name.rawValue])
        XCTAssertNil(retiredFields)
        XCTAssertNotNil(ledger[other.rawValue], "an unrelated record is untouched")
        XCTAssertNotNil(keptFields)
    }
}

/// A `CloudEngineControl` that records what it was asked to do. An actor because the
/// protocol is `Sendable` and the coordinator calls it across an actor boundary.
///
/// `persistState` mirrors how the production wrapper is wired in the composition root:
/// the engine writes its own state blob straight to `SyncBookkeepingStore`, since it is
/// constructed before the coordinator exists. `emitStateUpdate` stands in for
/// `CKSyncEngine.Event.stateUpdate`.
actor FakeCloudEngine: CloudEngineControl {
    private(set) var startedWith: [Data?] = []
    private(set) var savedNames: [[SyncRecordName]] = []
    private(set) var deletedNames: [[SyncRecordName]] = []
    /// M4 T11: every `dropPendingSaves` call, in order — the fake-engine pin for
    /// design §5's "the delete wins": a not-yet-sent save for a deleted capture's
    /// child record must be withdrawn, never sent.
    private(set) var droppedNames: [[SyncRecordName]] = []
    private(set) var fetchCallCount = 0
    private let persistState: SyncEngineStatePersistence?

    init(persistState: SyncEngineStatePersistence? = nil) {
        self.persistState = persistState
    }

    var startCallCount: Int { startedWith.count }
    var saveCallCount: Int { savedNames.count }
    var deleteCallCount: Int { deletedNames.count }
    var dropCallCount: Int { droppedNames.count }
    var savedNameSet: Set<SyncRecordName> { Set(savedNames.flatMap { $0 }) }
    var droppedNameSet: Set<SyncRecordName> { Set(droppedNames.flatMap { $0 }) }

    func start(stateData: Data?) async { startedWith.append(stateData) }
    func enqueueSaves(_ names: [SyncRecordName]) async { savedNames.append(names) }
    func enqueueDeletes(_ names: [SyncRecordName]) async { deletedNames.append(names) }
    func dropPendingSaves(_ names: [SyncRecordName]) async { droppedNames.append(names) }
    func fetchNow() async { fetchCallCount += 1 }

    func emitStateUpdate(_ data: Data) async { await persistState?(data) }
}
