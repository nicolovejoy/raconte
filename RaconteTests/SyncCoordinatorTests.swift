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

    /// M4 T12: same coordinator, with an injected clock so `status()`'s timestamps are
    /// assertable (repo convention: inject clocks, never assert on live `Date()`).
    private func coordinator(_ store: SyncBookkeepingStore, _ engine: FakeCloudEngine,
                             now: @escaping @Sendable () -> Date) -> SyncCoordinator {
        SyncCoordinator(bookkeeping: store, scanner: scanner(), engine: engine, now: now)
    }

    /// Task 3's factory: bookkeeping + fake engine + coordinator, pre-tagged `.production`
    /// so the environment gate (#90) never wipes a name a test parks before calling
    /// `launch()`/`foregrounded()`/`retryParked()` — the same reason every gate test above
    /// tags its own store before exercising `launch()`. `bookkeeping()` points at a fresh
    /// root each call, so this factory always starts from empty parked state.
    private func makeCoordinator() async throws -> (SyncCoordinator, FakeCloudEngine, SyncBookkeepingStore) {
        let store = bookkeeping()
        try await store.saveEnvironmentTag(.production)
        let engine = FakeCloudEngine()
        let coordinator = SyncCoordinator(bookkeeping: store, scanner: scanner(), engine: engine,
                                          environment: .production)
        return (coordinator, engine, store)
    }

    /// Advances on every call — the frozen-clock trap (memory:
    /// frozen-clock-two-mints-coin-flip-order applies to any two writes compared for
    /// ordering): a launch-then-change sequence sharing one frozen clock could stamp
    /// `lastPushAt`/`lastFetchAt` with the identical instant, masking a bug that swapped
    /// which field a call updates.
    private final class AdvancingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { self.current = start }
        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            let value = current
            current = current.addingTimeInterval(1)
            return value
        }
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
        // #90: the coordinator fixture uses the gate's default `.production` — an
        // untagged store would otherwise get wiped at `launch()`, which is the gate
        // doing its job, not a bug in this reconcile test. Tag it to match.
        try await store.saveEnvironmentTag(.production)

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
        // #90: match the gate's default `.production` — see the sibling test above.
        try await store.saveEnvironmentTag(.production)

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

    // MARK: status() (M4 T12)

    /// Nothing has happened yet: every field is at its honest "don't know" default.
    /// Pins the defaults so a later test asserting a CHANGE cannot pass vacuously
    /// against a status that was already non-default before the coordinator did anything.
    func testStatusDefaultsBeforeAnyActivity() async throws {
        let status = await coordinator(bookkeeping(), FakeCloudEngine()).status()

        XCTAssertEqual(status, SyncStatus(accountState: "unknown", lastPushAt: nil, lastFetchAt: nil,
                                          pendingSaveCount: 0, pendingDeleteCount: 0, lastError: nil))
    }

    /// `launch()` now ends with a fetch kick (M4 T12, design §3) — `lastFetchAt` moves,
    /// `lastPushAt` does not (an empty archive enqueues nothing to push).
    func testLaunchStampsLastFetchAtButNotLastPushAtWhenNothingToUpload() async throws {
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = coordinator(bookkeeping(), FakeCloudEngine(), now: { clock.next() })

        await coordinator.launch()

        let status = await coordinator.status()
        XCTAssertNotNil(status.lastFetchAt)
        XCTAssertNil(status.lastPushAt, "an empty archive's launch reconciliation enqueues nothing")
    }

    /// The initial-upload path DOES push (`testLaunchWithEmptyLedgerEnqueuesTheWholeArchive`'s
    /// sibling): `lastPushAt` moves and `pendingSaveCount` reflects what the engine still
    /// has queued.
    func testLaunchWithAnUnsyncedArchiveStampsLastPushAtAndReportsPendingSaves() async throws {
        try buildArchive()
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = coordinator(bookkeeping(), FakeCloudEngine(), now: { clock.next() })

        await coordinator.launch()

        let expectedCount = scanner().scan().artifacts.count
        let status = await coordinator.status()
        XCTAssertNotNil(status.lastPushAt)
        XCTAssertEqual(status.pendingSaveCount, expectedCount)
        XCTAssertEqual(status.pendingDeleteCount, 0)
    }

    /// `noteLocalChange`/`noteLocalDelete` each stamp `lastPushAt` and move the matching
    /// pending count — discriminates save vs. delete rather than one shared counter that
    /// would pass even if the two were swapped.
    func testNoteLocalChangeAndDeleteEachStampLastPushAndTheirOwnPendingCount() async throws {
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let engine = FakeCloudEngine()
        let coordinator = coordinator(bookkeeping(), engine, now: { clock.next() })

        await coordinator.noteLocalChange(.journal(id: journalID))
        let afterChange = await coordinator.status()
        XCTAssertNotNil(afterChange.lastPushAt)
        XCTAssertEqual(afterChange.pendingSaveCount, 1)
        XCTAssertEqual(afterChange.pendingDeleteCount, 0)

        let firstPushAt = afterChange.lastPushAt
        await coordinator.noteLocalDelete(.entry(captureID: idOne))
        let afterDelete = await coordinator.status()
        XCTAssertNotEqual(afterDelete.lastPushAt, firstPushAt, "the clock must have advanced")
        XCTAssertEqual(afterDelete.pendingSaveCount, 1, "the earlier save is still pending")
        XCTAssertEqual(afterDelete.pendingDeleteCount, 1)
    }

    /// A save the engine confirms landed must leave the pending count — otherwise
    /// "pending" would only ever grow, which is not what the field claims to mean.
    func testAConfirmedSaveLeavesThePendingSaveCount() async throws {
        let engine = FakeCloudEngine()
        let coordinator = coordinator(bookkeeping(), engine)
        await coordinator.noteLocalChange(.journal(id: journalID))
        let beforeConfirm = await coordinator.status()
        XCTAssertEqual(beforeConfirm.pendingSaveCount, 1)

        await engine.confirmSaved([.journal(id: journalID)])

        let afterConfirm = await coordinator.status()
        XCTAssertEqual(afterConfirm.pendingSaveCount, 0)
    }

    /// Account state and the last error are the engine's to report (M4 T12,
    /// `EngineSnapshot`) — driven here through the fake exactly as a real
    /// `CKSyncEngineDelegate` callback would set them.
    func testAccountStateAndLastErrorSurfaceFromTheEngineSnapshot() async throws {
        let engine = FakeCloudEngine()
        let coordinator = coordinator(bookkeeping(), engine)
        let initial = await coordinator.status()
        XCTAssertEqual(initial.accountState, "unknown")
        XCTAssertNil(initial.lastError)

        await engine.setAccountState("signed in")
        await engine.emitError("network unavailable")

        let status = await coordinator.status()
        XCTAssertEqual(status.accountState, "signed in")
        XCTAssertEqual(status.lastError, "network unavailable")
    }

    // MARK: #90 environment gate

    /// The money test — the exact stranding this issue exists to fix: a ledger
    /// claiming "uploaded" (written under dev) must not suppress the production
    /// re-push. Mismatch ⇒ wipe ⇒ engine starts stateless ⇒ reconcile re-enqueues.
    func testLaunchWithMismatchedTagWipesAndReenqueues() async throws {
        try buildArchive()
        let store = bookkeeping()
        for artifact in scanner().scan().artifacts {
            try await store.recordUpload(UploadedDigest(sha256: artifact.sha256, bytes: artifact.bytes),
                                         for: artifact.name.rawValue)
        }
        try await store.saveEnvironmentTag(.development)
        try await store.saveEngineState(Data("blob".utf8))
        let seededLedger = await store.ledger()
        XCTAssertFalse(seededLedger.isEmpty)  // adversarial guard: fixture is real

        let engine = FakeCloudEngine()
        let coordinator = SyncCoordinator(bookkeeping: store, scanner: scanner(),
                                          engine: engine, environment: .production)
        await coordinator.launch()

        let started = await engine.startedWith
        XCTAssertEqual(started, [nil])                       // never resumed stale state
        let ledgerAfter = await store.ledger()
        // Reconcile re-enqueued the capture, and recording an upload is the push
        // path's job — at launch-time the wiped ledger stays empty.
        XCTAssertTrue(ledgerAfter.isEmpty)
        let saved = await engine.savedNameSet
        XCTAssertFalse(saved.isEmpty)                        // the stranded record pushes again
        let tag = await store.environmentTag()
        XCTAssertEqual(tag, .production)
    }

    /// Same seed, matching tag: nothing is wiped, the engine resumes its state.
    func testLaunchWithMatchingTagPreservesBookkeeping() async throws {
        try buildArchive()
        let store = bookkeeping()
        for artifact in scanner().scan().artifacts {
            try await store.recordUpload(UploadedDigest(sha256: artifact.sha256, bytes: artifact.bytes),
                                         for: artifact.name.rawValue)
        }
        try await store.saveEnvironmentTag(.production)
        try await store.saveEngineState(Data("blob".utf8))
        let seededLedger = await store.ledger()
        XCTAssertFalse(seededLedger.isEmpty)

        let engine = FakeCloudEngine()
        let coordinator = SyncCoordinator(bookkeeping: store, scanner: scanner(),
                                          engine: engine, environment: .production)
        await coordinator.launch()

        let started = await engine.startedWith
        XCTAssertEqual(started, [Data("blob".utf8)])
        let ledgerAfter = await store.ledger()
        XCTAssertEqual(ledgerAfter, seededLedger)
        let tag = await store.environmentTag()
        XCTAssertEqual(tag, .production)
    }

    /// Pre-tag upgrade (today's phones): bookkeeping exists, no tag — wipe.
    func testLaunchWithUntaggedExistingBookkeepingWipes() async throws {
        try buildArchive()
        let store = bookkeeping()
        for artifact in scanner().scan().artifacts {
            try await store.recordUpload(UploadedDigest(sha256: artifact.sha256, bytes: artifact.bytes),
                                         for: artifact.name.rawValue)
        }
        try await store.saveEngineState(Data("blob".utf8))
        let seededLedger = await store.ledger()
        XCTAssertFalse(seededLedger.isEmpty)

        let engine = FakeCloudEngine()
        let coordinator = SyncCoordinator(bookkeeping: store, scanner: scanner(),
                                          engine: engine, environment: .production)
        await coordinator.launch()

        let started = await engine.startedWith
        XCTAssertEqual(started, [nil])
        let ledgerAfter = await store.ledger()
        XCTAssertTrue(ledgerAfter.isEmpty)
        let tag = await store.environmentTag()
        XCTAssertEqual(tag, .production)
    }

    /// Fresh install: nothing on disk — tag written, no wipe path taken, and the
    /// engine starts stateless because there was never state.
    func testLaunchFreshInstallWritesTag() async throws {
        // A store over a root that does NOT exist yet, rather than the class's
        // `bookkeeping()` fixture (which points at a root the archive fixtures may
        // already have created).
        let engine = FakeCloudEngine()
        let freshRoot = containerRoot.appendingPathComponent("fresh-sync", isDirectory: true)
        let freshStore = SyncBookkeepingStore(root: freshRoot)
        let coordinator = SyncCoordinator(bookkeeping: freshStore, scanner: scanner(),
                                          engine: engine, environment: .development)
        await coordinator.launch()

        let tag = await freshStore.environmentTag()
        XCTAssertEqual(tag, .development)
        let started = await engine.startedWith
        XCTAssertEqual(started, [nil])
    }

    // MARK: Refetch parked records on launch and foreground (#85 part 3)

    /// Real ULID-shaped audio record name — a short fake id would parse to nil and skip
    /// the code under test (repo idiom: real ULIDs in fixtures).
    private var parkedAudioName: String { "a.\(idOne).0" }

    func testLaunchRefetchesParkedNames() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()
        await bookkeeping.park(parkedAudioName, reason: "sha256 mismatch")

        await coordinator.launch()

        let calls = await engine.refetchCalls
        XCTAssertEqual(calls, [[parkedAudioName]])
        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked[parkedAudioName]?.attempts, 1)
    }

    func testForegroundedRefetchesParkedNames() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()
        await bookkeeping.park(parkedAudioName, reason: "sha256 mismatch")

        await coordinator.foregrounded()

        let calls = await engine.refetchCalls
        XCTAssertEqual(calls, [[parkedAudioName]])
        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked[parkedAudioName]?.attempts, 1)
    }

    func testNothingParkedMeansNoRefetchCall() async throws {
        let (coordinator, engine, _) = try await makeCoordinator()

        await coordinator.foregrounded()

        let calls = await engine.refetchCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testANameGoneFromTheServerIsUnparked() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()
        await bookkeeping.park(parkedAudioName, reason: "sha256 mismatch")
        await engine.setRefetchOutcome(RefetchOutcome(delivered: [], goneFromServer: [parkedAudioName], failed: []))

        await coordinator.retryParked(includingExhausted: true)

        let parked = await bookkeeping.parkedRecords()
        XCTAssertNil(parked[parkedAudioName])
    }

    /// The mirror of the test above: a refetch that fails for any OTHER reason leaves
    /// the name parked (so the next `retryParked()` tries again), but the attempt still
    /// counted — without this, an implementation that unparked on ANY outcome, not just
    /// `.unknownItem`, would still pass `testANameGoneFromTheServerIsUnparked` alone.
    func testAFailedRefetchStaysParked() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()
        await bookkeeping.park(parkedAudioName, reason: "sha256 mismatch")
        await engine.setRefetchOutcome(RefetchOutcome(delivered: [], goneFromServer: [], failed: [parkedAudioName]))

        await coordinator.retryParked(includingExhausted: true)

        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked[parkedAudioName]?.attempts, 1)
        XCTAssertEqual(parked[parkedAudioName]?.reason, "sha256 mismatch")
    }

    // MARK: Fix wave finding 2 — retryParked's retry budget

    /// A name that has already exhausted `SyncCoordinator.maxRetryAttempts` (10) must
    /// still be retried by `launch()` — a fresh app launch is exactly the moment a stuck
    /// record deserves another try, regardless of how many times it has already failed.
    func testLaunchRefetchesAnExhaustedParkedName() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()
        await bookkeeping.park(parkedAudioName, reason: "sha256 mismatch")
        for _ in 0..<10 { await bookkeeping.noteRetryAttempt(parkedAudioName) }
        let parkedBefore = await bookkeeping.parkedRecords()
        XCTAssertEqual(parkedBefore[parkedAudioName]?.attempts, 10)

        await coordinator.launch()

        let calls = await engine.refetchCalls
        XCTAssertEqual(calls.last, [parkedAudioName])
    }

    /// The mirror: `foregrounded()` must NOT retry a name whose `attempts` already
    /// reached the budget — a foreground happens far more often than a launch, and
    /// retrying a name that will never resolve on every foreground forever is exactly
    /// the unbounded behavior this finding fixes.
    func testForegroundedSkipsAnExhaustedParkedName() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()
        await bookkeeping.park(parkedAudioName, reason: "sha256 mismatch")
        for _ in 0..<10 { await bookkeeping.noteRetryAttempt(parkedAudioName) }

        await coordinator.foregrounded()

        let calls = await engine.refetchCalls
        XCTAssertTrue(calls.isEmpty, "an exhausted name must not be refetched by foregrounded()")
        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked[parkedAudioName]?.attempts, 10, "and its attempts count must not rise either")
    }

    /// A name one attempt short of exhausted (9) is still within budget: `launch()`
    /// retries it. Pins the boundary at `< 10`, not `<= 10` or `< 9`. Companion to
    /// `testANameWithNineAttemptsIsRefetchedByForegrounded` immediately below — two
    /// separate coordinators/stores, since `makeCoordinator()` shares this test
    /// method's one `containerRoot` and a single combined test would double-count
    /// attempts across both calls.
    func testANameWithNineAttemptsIsRefetchedByLaunch() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()
        await bookkeeping.park(parkedAudioName, reason: "sha256 mismatch")
        for _ in 0..<9 { await bookkeeping.noteRetryAttempt(parkedAudioName) }

        await coordinator.launch()

        let calls = await engine.refetchCalls
        XCTAssertEqual(calls.last, [parkedAudioName])
    }

    /// The `foregrounded()` half of the pin above.
    func testANameWithNineAttemptsIsRefetchedByForegrounded() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()
        await bookkeeping.park(parkedAudioName, reason: "sha256 mismatch")
        for _ in 0..<9 { await bookkeeping.noteRetryAttempt(parkedAudioName) }

        await coordinator.foregrounded()

        let calls = await engine.refetchCalls
        XCTAssertEqual(calls.last, [parkedAudioName])
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
    /// #85 part 3: every `refetch(recordNames:)` call, in order.
    private(set) var refetchCalls: [[String]] = []
    /// #85 part 3: what the next (and every subsequent) `refetch` call answers — a test
    /// drives it through `setRefetchOutcome`, never a direct assignment across the actor
    /// boundary, matching this type's existing test-driver methods below.
    var refetchOutcome = RefetchOutcome(delivered: [], goneFromServer: [], failed: [])
    private let persistState: SyncEngineStatePersistence?

    // M4 T12: live pending sets (mirrors `CKSyncEngine.State.pendingRecordZoneChanges`
    // conceptually — a name is pending until something confirms it, exactly like the
    // production `snapshot()` reading `engine.state.pendingRecordZoneChanges`) plus the
    // account/error state a test can drive directly, standing in for delegate events
    // `CloudKitEngineControl` would otherwise observe from CloudKit.
    private var pendingSaveNames: Set<SyncRecordName> = []
    private var pendingDeleteNames: Set<SyncRecordName> = []
    private var accountState = "unknown"
    private var lastError: String?

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

    func enqueueSaves(_ names: [SyncRecordName]) async {
        savedNames.append(names)
        pendingSaveNames.formUnion(names)
    }

    func enqueueDeletes(_ names: [SyncRecordName]) async {
        deletedNames.append(names)
        // Mirrors `PendingEngineChanges.bufferDeletes`: the delete wins over any
        // still-pending save for the same name.
        for name in names { pendingSaveNames.remove(name) }
        pendingDeleteNames.formUnion(names)
    }

    func dropPendingSaves(_ names: [SyncRecordName]) async {
        droppedNames.append(names)
        for name in names { pendingSaveNames.remove(name) }
    }

    func fetchNow() async { fetchCallCount += 1 }

    func refetch(recordNames: [String]) async -> RefetchOutcome {
        refetchCalls.append(recordNames)
        return refetchOutcome
    }

    /// Test-only driver — sets what the next `refetch` call answers.
    func setRefetchOutcome(_ outcome: RefetchOutcome) {
        refetchOutcome = outcome
    }

    func snapshot() async -> EngineSnapshot {
        EngineSnapshot(accountState: accountState, pendingSaveCount: pendingSaveNames.count,
                       pendingDeleteCount: pendingDeleteNames.count, lastError: lastError)
    }

    func emitStateUpdate(_ data: Data) async { await persistState?(data) }

    /// Test-only driver, standing in for a `CKSyncEngine` `.accountChange` event.
    func setAccountState(_ state: String) async { accountState = state }

    /// Test-only driver, standing in for any of the delegate's error-surfacing branches.
    func emitError(_ message: String) async { lastError = message }

    /// Test-only driver, standing in for `sentRecordZoneChanges` confirming a save
    /// actually landed — removes it from the pending set.
    func confirmSaved(_ names: [SyncRecordName]) async {
        for name in names { pendingSaveNames.remove(name) }
    }
}
