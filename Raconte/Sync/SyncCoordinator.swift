import Foundation

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
actor SyncCoordinator {
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
    @MainActor static func live() -> SyncCoordinator? {
        guard !isHostedByTestRunner else { return nil }

        let containerRoot = AppContainer.root()
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        // The engine writes its own state blob, because it is constructed before the
        // coordinator that would otherwise own that write.
        let engine = CloudKitEngineControl(persistState: { [bookkeeping] data in
            try? await bookkeeping.saveEngineState(data)
        })
        return SyncCoordinator(
            bookkeeping: bookkeeping,
            scanner: SyncTreeScanner(containerRoot: containerRoot, deviceID: DeviceIdentity.stable()),
            engine: engine)
    }

    /// Internal, not private, so `SyncCoordinatorTests` can assert the refusal directly
    /// — it runs inside exactly the environment this is meant to catch.
    static var isHostedByTestRunner: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["RACONTE_UITEST_ID"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
