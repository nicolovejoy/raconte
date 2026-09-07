import Foundation
import os
#if os(macOS)
import Security
#endif

/// The app's one sync brain (M4 §3): it decides *what* to sync and *when*, and hands the
/// result to a `CloudEngineControl` that knows how. An actor because it serializes the
/// launch reconciliation against the change hooks Tasks 5+ install at the six existing
/// write chokepoints.
///
/// Nothing here is on a capture path, and nothing on a capture path ever waits on this
/// (design §8). The hooks are one-way notifications; the reconciliation scan runs off
/// this actor entirely (see `reconcile`).
///
/// Everything CloudKit is behind `engine`, so this whole type — the only part with
/// decisions in it — is exercised by `SyncCoordinatorTests` against a fake with zero
/// server traffic.
actor SyncCoordinator: SyncHooks {
    private let bookkeeping: SyncBookkeepingStore
    private let scanner: SyncTreeScanner
    private let engine: any CloudEngineControl
    private let log: Logger
    /// Repo idiom (memory: inject clocks, never assert on live `Date()`): tests hand in
    /// an advancing fake so `status()`'s timestamps are assertable.
    private let now: @Sendable () -> Date
    /// M4 T12: when this device last asked the engine to push ANY save or delete —
    /// the coordinator's own activity, not a server confirmation.
    private var lastPushAt: Date?
    /// M4 T12: when this device last asked the engine to fetch (launch or foreground).
    private var lastFetchAt: Date?
    /// #90: which CloudKit environment this binary talks to — the gate's other
    /// input, alongside whatever tag `bookkeeping` was last stamped with.
    private let environment: CloudKitEnvironment

    init(bookkeeping: SyncBookkeepingStore, scanner: SyncTreeScanner, engine: any CloudEngineControl,
         log: Logger = Logger(subsystem: "org.pianohouseproject.raconte", category: "sync"),
         now: @escaping @Sendable () -> Date = { Date() },
         environment: CloudKitEnvironment = .production) {
        self.bookkeeping = bookkeeping
        self.scanner = scanner
        self.engine = engine
        self.log = log
        self.now = now
        self.environment = environment
    }

    /// Boot: resume the engine from its last state, then reconcile the tree against the
    /// upload ledger and enqueue whatever is missing or stale.
    ///
    /// The reconciliation is not an optimization — it is both halves of "belt and
    /// braces" (design §3). It is the **initial upload path**: on first enable the
    /// ledger is empty, so it enqueues the entire existing archive, which is the only
    /// way anything recorded before sync existed ever reaches CloudKit. And it is the
    /// crash backstop: a hook that never fired because the app died between "file
    /// written" and "change enqueued" is caught here on the next launch.
    ///
    /// M4 T12 (design §3, "fetch on launch, foreground, and silent push"): a fetch kick
    /// at the end of launch. `CKSyncEngine` also syncs on its own schedule once started
    /// — this is for the moment the app KNOWS it just came up and the engine doesn't yet.
    /// `foregrounded()` below is the same idea for scene-active transitions; silent push
    /// is not wired (no APNs receipt path exists in this app).
    func launch() async {
        await applyEnvironmentGate()
        let state = await bookkeeping.engineState()
        await engine.start(stateData: state)
        await reconcile()
        await fetchNow()
        await retryParked()
    }

    /// #90: before the engine resumes from `engine-state.bin`, make sure every
    /// byte of bookkeeping was written by the environment this binary talks to.
    /// Wipe-then-tag ordering matters: `wipe()` removes the tag file too, so the
    /// tag write must follow it. A failed wipe must NOT be followed by the tag
    /// write — writing the tag over incompletely-wiped (possibly still
    /// wrong-environment) bookkeeping would make the next launch see tag ==
    /// detected and proceed, permanently certifying the stranded state; there is
    /// no downstream self-heal for that (the NOT_FOUND self-heal covers a
    /// different failure — a record CloudKit no longer has — not stale local
    /// bookkeeping from the wrong environment). So on a failed wipe we return
    /// without writing the tag, and the gate retries from scratch next launch.
    /// A failed TAG write (wipe having succeeded) stays `try?`: at worst the
    /// next launch wipes an already-empty directory again, which is harmless.
    ///
    /// Benign race: `live()`'s composition-time rehydration Task
    /// (`rehydrateParkedRevisions`/`rehydrateParkedMarkerStreams`) enumerates
    /// `sync/staging/` concurrently with this wipe. Every interleaving is
    /// benign — read-before-wipe applies whatever was parked before this method
    /// clears it, and any staging file re-created after (by the forced refetch
    /// this wipe triggers) is repopulated by that refetch anyway; read-after-wipe
    /// simply finds nothing and no-ops.
    private func applyEnvironmentGate() async {
        let tag = await bookkeeping.environmentTag()
        let exists = await bookkeeping.hasBookkeeping()
        switch EnvironmentGate.decide(tag: tag, detected: environment, bookkeepingExists: exists) {
        case .proceed:
            return
        case .writeTag:
            try? await bookkeeping.saveEnvironmentTag(environment)
            log.notice("sync: environment tag written (\(self.environment.rawValue, privacy: .public))")
        case .wipeAndWriteTag:
            do {
                try await bookkeeping.wipe()
            } catch {
                log.error("""
                    sync: bookkeeping wipe failed — tag NOT written, gate retries next launch: \
                    \(String(describing: error), privacy: .public)
                    """)
                return
            }
            try? await bookkeeping.saveEnvironmentTag(environment)
            log.notice("""
                sync: environment tag \(tag?.rawValue ?? "absent", privacy: .public) vs \
                \(self.environment.rawValue, privacy: .public) — bookkeeping wiped, full resync
                """)
        }
    }

    /// M4 T12: the foreground half of design §3's fetch triggers — call when the app's
    /// scene becomes active (see `RaconteApp`'s `scenePhase` wiring).
    func foregrounded() async {
        await fetchNow()
        await retryParked()
    }

    private func fetchNow() async {
        await engine.fetchNow()
        lastFetchAt = now()
    }

    /// #85 part 3: refetches every currently-parked record name. Stamps an attempt on
    /// EACH name first, before the refetch runs — so a batch that fails outright (the
    /// engine's `refetch` catch) still leaves a rising `attempts` count in `parked.json`,
    /// not just a per-name success path. A name the server says it no longer has is
    /// unparked with a `.notice`: the terminal case, never silent (memory: inbound sync
    /// must land or park — and a park that can never be retried again is the same silent
    /// loss with extra steps).
    func retryParked() async {
        let parked = await bookkeeping.parkedRecords()
        guard !parked.isEmpty else { return }
        let names = Array(parked.keys)
        for name in names {
            await bookkeeping.noteRetryAttempt(name)
        }
        let outcome = await engine.refetch(recordNames: names)
        for name in outcome.goneFromServer {
            log.notice("sync: \(name, privacy: .public) is gone from the server — unparked")
            await bookkeeping.unpark(name)
        }
    }

    /// M4 T12: a snapshot for the Debug screen. Timestamps and their own recency are
    /// this coordinator's own bookkeeping; account state / pending counts / last error
    /// come from the engine (`EngineSnapshot`'s doc comment explains why those three are
    /// best-effort where the timestamps are not).
    func status() async -> SyncStatus {
        let snapshot = await engine.snapshot()
        return SyncStatus(accountState: snapshot.accountState,
                          lastPushAt: lastPushAt,
                          lastFetchAt: lastFetchAt,
                          pendingSaveCount: snapshot.pendingSaveCount,
                          pendingDeleteCount: snapshot.pendingDeleteCount,
                          lastError: snapshot.lastError)
    }

    /// The hook entry point for the six local write chokepoints (design §3). Enqueues
    /// exactly the one record whose content changed; the engine batches and schedules.
    func noteLocalChange(_ name: SyncRecordName) async {
        await engine.enqueueSaves([name])
        lastPushAt = now()
    }

    /// The delete half of the hook (#80, B2): the record is gone, not merely changed, so
    /// it routes to `enqueueDeletes`, never `enqueueSaves` — see `SyncHooks
    /// .noteLocalDelete`'s doc comment for why a delete cannot be expressed as a save
    /// whose content degraded to nothing.
    func noteLocalDelete(_ name: SyncRecordName) async {
        await engine.enqueueDeletes([name])
        lastPushAt = now()
        // The record is gone locally, so this device's memory of the server's copy
        // describes something that no longer exists here (gate finding, Minor 3).
        // Retiring it cannot cost an upload: `SyncPlanner.reconcile` iterates the DISK
        // scan, which no longer contains this artifact, so a cleared ledger entry
        // re-enqueues nothing. Leaving it was benign but it is stale bookkeeping that
        // grows forever, and a resurrected record would otherwise be pushed against a
        // change tag from before its deletion.
        await retireBookkeeping(for: name)
    }

    /// M4 T11 (design §5, "the delete wins"): a local entry's now-gone CHILD records
    /// — never the Entry record itself, which stays on `noteLocalDelete` above and
    /// gets an actual CK delete. These never do: the Entry's own delete cascades them
    /// server-side, so the ONLY local work left is withdrawing any not-yet-sent save
    /// for one of them and retiring the same per-name bookkeeping `noteLocalDelete`
    /// retires for its own name.
    func noteLocalDeleteFamily(_ names: [SyncRecordName]) async {
        guard !names.isEmpty else { return }
        await engine.dropPendingSaves(names)
        for name in names {
            await retireBookkeeping(for: name)
        }
    }

    /// Shared by `noteLocalDelete`/`noteLocalDeleteFamily`: drops what this device
    /// remembers about `name`'s SERVER copy — see `noteLocalDelete`'s doc comment for
    /// why this cannot cost a spurious upload.
    private func retireBookkeeping(for name: SyncRecordName) async {
        do {
            try await bookkeeping.deleteSystemFields(for: name.rawValue)
            try await bookkeeping.clearUpload(for: name.rawValue)
        } catch {
            log.error("""
                sync: could not retire bookkeeping for deleted \(name.rawValue, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: Reconciliation

    private func reconcile() async {
        // Off the actor deliberately: `scan()` hashes every final m4a in the archive,
        // which is IO-bound and can run for seconds on a real corpus. Holding the
        // coordinator's own executor for that would make every `noteLocalChange` from a
        // store hook wait behind it — the one way this type could end up delaying a
        // capture write, which design §8 forbids.
        let scanner = self.scanner
        let scan = await Task.detached(priority: .utility) { scanner.scan() }.value
        let ledger = await bookkeeping.ledger()
        let names = SyncPlanner.reconcile(scan: scan.artifacts, ledger: ledger)
        guard !names.isEmpty else { return }
        await engine.enqueueSaves(names)
        lastPushAt = now()
    }
}

/// M4 T12: the Debug screen's status snapshot (design §8's "status line: last push, last
/// fetch, pending counts, last error"). Exactly the brief's five fields, nothing more —
/// user-facing surfacing is later polish (design §8), this is debug-only.
struct SyncStatus: Equatable, Sendable {
    var accountState: String
    var lastPushAt: Date?
    var lastFetchAt: Date?
    var pendingSaveCount: Int
    var pendingDeleteCount: Int
    var lastError: String?
}

extension SyncCoordinator {
    /// Live composition root — and the single place a real `CKSyncEngine` is ever
    /// constructed.
    ///
    /// Returns **nil**, meaning "this build does not sync", in three cases that must
    /// never reach CloudKit's servers:
    ///
    /// 1. **Hosted by XCTest.** `RaconteTests` runs with the real app as its test host
    ///    (`project.yml`'s `TEST_HOST`), so every unit-test run launches `ContentView`
    ///    and would otherwise boot a live sync engine against the owner's own iCloud
    ///    account — from CI as well.
    /// 2. **The UI-test harness.** `RACONTE_UITEST_ID` keys a throwaway container tree;
    ///    syncing a synthetic 440 Hz sine to the real archive is exactly the wrong
    ///    outcome. Same substitution the harness already makes for the capture
    ///    coordinator's `SecondarySinkFactory`.
    /// 3. **An Xcode preview.** `#Preview { ContentView() }` builds this same composition
    ///    root; a preview render has no business opening a sync session.
    ///
    /// All three are environment checks rather than `#if DEBUG`, because a Debug build
    /// the owner actually runs *should* sync — the thing to exclude is the test runner,
    /// not the configuration.
    ///
    /// And a fourth, which is not about environment at all: **a binary signed without
    /// the iCloud entitlement never syncs.** `CKContainer(identifier:)` raises an
    /// Objective-C exception for an identifier the binary does not claim, and an ObjC
    /// exception cannot be caught in Swift — so that path is a hard crash, not a
    /// degradation. It is reachable: any macOS build made with the
    /// `Raconte-nocloud.entitlements` override (the recipe CI uses, and the one a
    /// hurried owner-smoke build might copy) produces exactly such a binary.
    /// Takes the library's own stores rather than building its own, and that is not
    /// tidiness: `JournalStore` is an actor precisely because `journals.json` is
    /// read-modify-written whole, so a second instance over the same file would be a
    /// second, uncoordinated writer — an ingest and a rename could interleave and lose
    /// one of them. One store, one queue.
    @MainActor static func live(library: LibraryScreenModel) -> SyncCoordinator? {
        guard shouldSync(hostedByTestRunner: isHostedByTestRunner,
                         hasCloudKitEntitlement: hasCloudKitEntitlement) else { return nil }

        let containerRoot = AppContainer.root()
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let scanner = SyncTreeScanner(containerRoot: containerRoot, deviceID: DeviceIdentity.stable())
        let exchange = SyncRecordExchange(
            journalStore: library.journalStore,
            coverStore: library.journalCoverStore,
            bookkeeping: bookkeeping,
            deviceID: DeviceIdentity.stable(),
            // T7: where `captures/` and `sync/staging/` live, so entry ingest can
            // actually assemble and commit. Without this, a real build would silently
            // never run the new-entry ingest path at all — see that parameter's doc
            // comment on `SyncRecordExchange`.
            containerRoot: containerRoot,
            // M4 T8: the library's own single shared instance, never a fresh one built
            // here — see that parameter's doc comment on `SyncRecordExchange` for why a
            // second instance would be an uncoordinated second writer over `entry.json`.
            entryMetadataStore: library.entryMetadataStore,
            // M4 T9: the library's own single shared instance, never a fresh one built
            // here — identical reasoning to `entryMetadataStore` immediately above: a
            // second instance would be an uncoordinated second writer over the same
            // `transcript/` files a local draft close or revert can also be writing.
            transcriptRevisionStore: library.revisionStore,
            // Image-capture plan Task 5: the library's own single shared instance,
            // never a fresh one built here — identical reasoning to the two stores
            // above: a second instance would be an uncoordinated second writer over
            // the same `images/` directory a local add or remove can also be writing.
            // Without this, inbound Image records would park forever instead of
            // landing (they would never be dropped — see `SyncRecordExchange
            // .ingestImage`'s no-store branch — but they would never appear either).
            imageStore: library.imageStore,
            // Ingest writes straight to the stores, which the screen model has already
            // read into published state — without this it would keep showing the old
            // journal names until the next launch.
            localStoreDidChange: { [weak library] in await library?.rescan() },
            // The load-bearing not-empty-locally guard for #80's inbound deletion (B2,
            // R3): the ONE legitimate way to ask this off-MainActor, and the reason it is
            // a method on `LibraryScreenModel` rather than reimplemented here — see that
            // method's doc comment for why rescan-then-check has to be one call, not two.
            journalIsEmptyAfterRescan: { [weak library] journalID in
                await library?.isJournalEmptyAfterRescan(journalID) ?? false
            })
        // The engine writes its own state blob, because it is constructed before the
        // coordinator that would otherwise own that write.
        let engine = CloudKitEngineControl(exchange: exchange, persistState: { [bookkeeping] data in
            try? await bookkeeping.saveEngineState(data)
        })
        let coordinator = SyncCoordinator(bookkeeping: bookkeeping, scanner: scanner, engine: engine,
                                          environment: CloudKitEnvironment.detectFromBundle())
        // Wired last, and in this order, because each half needs the other: the stores
        // notify the coordinator, and the coordinator's exchange writes through the
        // stores. See `JournalStore.attach(syncHooks:)`. `exchange.attach(engine:)`
        // belongs in the same wave for the same reason: `exchange` is built before
        // `engine` exists (the engine's own init takes `exchange`), so the reference the
        // not-empty-locally guard needs to re-push a refused deletion can only be handed
        // over after the fact.
        Task { [journalStore = library.journalStore, coverStore = library.journalCoverStore,
                entryMetadataStore = library.entryMetadataStore,
                revisionStore = library.revisionStore] in
            await exchange.attach(engine: engine)
            await journalStore.attach(syncHooks: coordinator)
            await coverStore.attach(journalStore: journalStore)
            // M4 T6: the post-update hook `EntryMetadataStore.update` fires for a
            // finalized entry (design §3, "`EntryMetadataStore.update` → enqueue
            // Entry") — same wiring, same reason as the two lines above.
            await entryMetadataStore.attach(syncHooks: coordinator)
            // M4 T9: `TranscriptRevisionStore.append` → enqueue Revision (design §3),
            // fires once per minted revision — same wiring, same reason.
            await revisionStore.attach(syncHooks: coordinator)
            // M4 (marker-correction push hook, T10 review's unwired chokepoint): the
            // mark-voices screen's `VoiceMarkingStore` conformance writes through
            // `MarkerCorrectionWriter` directly (a stateless enum, no store of its own),
            // so `library` itself needs the hook — see `LibraryScreenModel.attach
            // (syncHooks:)`'s doc comment.
            await library.attach(syncHooks: coordinator)
            // M4 T9 fix round: a revision fetched for a then-trashed capture parked
            // rather than vanished (`SyncRecordExchange.ingestRevision`'s
            // `.trashedCapture` catch) — CKSyncEngine will never redeliver a record it
            // has already handed over, so this is its only retry path. Run once here,
            // at composition time (the same "crash backstop, run at launch" philosophy
            // `reconcile()` already follows), so a capture restored since the last
            // session picks its parked revisions back up.
            await exchange.rehydrateParkedRevisions()
            // M4 T10: the identical crash-backstop philosophy, for marker streams
            // parked while their capture was trashed (or not yet committed) — see
            // `SyncRecordExchange.rehydrateParkedMarkerStreams`'s doc comment.
            await exchange.rehydrateParkedMarkerStreams()
            // Image-capture plan Task 5: the identical crash-backstop philosophy, for
            // images parked while their capture was trashed, not yet committed, or
            // committed by a launch that had no `ImageStore` wired — see
            // `SyncRecordExchange.rehydrateParkedImages`'s doc comment for why that
            // third case makes this sweep look in `captures/` as well as
            // `sync/staging/`.
            await exchange.rehydrateParkedImages()
        }
        return coordinator
    }

    /// The whole gate as a pure function, so the policy is unit-tested even though
    /// neither of its two inputs can be (both read the running process). Repo idiom:
    /// decisions in a testable core, environment reads in the thin shell.
    static func shouldSync(hostedByTestRunner: Bool, hasCloudKitEntitlement: Bool) -> Bool {
        !hostedByTestRunner && hasCloudKitEntitlement
    }

    /// Internal, not private, so `SyncCoordinatorTests` can assert the refusal directly
    /// — it runs inside exactly the environment this is meant to catch.
    static var isHostedByTestRunner: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["RACONTE_UITEST_ID"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Does the running binary's code signature actually claim the CloudKit container?
    ///
    /// **macOS reads it; iOS assumes true, deliberately.** `SecTaskCopyValueForEntitlement`
    /// is public API on macOS but ships on iOS with no public header — it is SPI there,
    /// and this app is bound for TestFlight and the App Store, where reaching for that
    /// symbol is a rejection risk not worth taking for a guard. The exposure the guard
    /// exists to close is macOS-shaped anyway: the entitlement-stripped build recipe is
    /// the macOS test/CI one. Every iOS build is signed with a provisioning profile that
    /// carries the capability, and the iOS simulator case is already covered by the
    /// `RACONTE_UITEST_ID` check above.
    ///
    /// Only the *false* answer is verifiable in this suite (`SyncCoordinatorTests` runs
    /// in a host built with the override), and even that is not asserted — a developer
    /// running the suite against a properly signed build would get a true answer and a
    /// spurious failure. The true answer is device-verifiable only, at Gate A. What IS
    /// pinned is `shouldSync`, which is where the decision lives.
    static var hasCloudKitEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.icloud-container-identifiers" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        // Present but empty claims nothing — treat it as absent rather than trusting the
        // key's mere existence.
        return ((value as? [String]) ?? []).contains(SyncCloudIdentifiers.containerIdentifier)
        #else
        return true
        #endif
    }
}
