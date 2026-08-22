import Foundation
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

    init(bookkeeping: SyncBookkeepingStore, scanner: SyncTreeScanner, engine: any CloudEngineControl) {
        self.bookkeeping = bookkeeping
        self.scanner = scanner
        self.engine = engine
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
    /// No fetch kick: `CKSyncEngine` is configured to sync automatically, so it fetches
    /// on its own once started. `fetchNow()` exists for the moments the app knows about
    /// and the engine doesn't (foreground, silent push) — Task 12 wires those.
    func launch() async {
        let state = await bookkeeping.engineState()
        await engine.start(stateData: state)
        await reconcile()
    }

    /// The hook entry point for the six local write chokepoints (design §3). Enqueues
    /// exactly the one record whose content changed; the engine batches and schedules.
    func noteLocalChange(_ name: SyncRecordName) async {
        await engine.enqueueSaves([name])
    }

    /// The delete half of the hook (#80, B2): the record is gone, not merely changed, so
    /// it routes to `enqueueDeletes`, never `enqueueSaves` — see `SyncHooks
    /// .noteLocalDelete`'s doc comment for why a delete cannot be expressed as a save
    /// whose content degraded to nothing.
    func noteLocalDelete(_ name: SyncRecordName) async {
        await engine.enqueueDeletes([name])
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
    }
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
        let coordinator = SyncCoordinator(bookkeeping: bookkeeping, scanner: scanner, engine: engine)
        // Wired last, and in this order, because each half needs the other: the stores
        // notify the coordinator, and the coordinator's exchange writes through the
        // stores. See `JournalStore.attach(syncHooks:)`. `exchange.attach(engine:)`
        // belongs in the same wave for the same reason: `exchange` is built before
        // `engine` exists (the engine's own init takes `exchange`), so the reference the
        // not-empty-locally guard needs to re-push a refused deletion can only be handed
        // over after the fact.
        Task { [journalStore = library.journalStore, coverStore = library.journalCoverStore] in
            await exchange.attach(engine: engine)
            await journalStore.attach(syncHooks: coordinator)
            await coverStore.attach(journalStore: journalStore)
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
