import Foundation
import CloudKit
import os

/// The one seam between `SyncCoordinator` and CloudKit (M4 §3). Everything above this
/// protocol is pure-ish, testable app code driven in unit tests by a fake; everything
/// below it is `CKSyncEngine`, which owns cursors, change tokens, retry/backoff and the
/// zone subscription — this app never hand-rolls any of those.
///
/// Deliberately narrow: four verbs, no CloudKit types in the signatures. That is what
/// lets `SyncCoordinatorTests` exercise the launch/enqueue logic with zero server
/// traffic, and it is why the only conformer that touches `CKSyncEngine`
/// (`CloudKitEngineControl`) is constructed in exactly one place — the production
/// composition root, which refuses to build it under XCTest or the UI-test harness
/// (`SyncCoordinator.live()`).
protocol CloudEngineControl: Sendable {
    /// Boots the engine, resuming from `stateData` when there is any. Nil means "start
    /// fresh" — the bookkeeping directory is a disposable cache, so an absent or
    /// unreadable state blob is a resync, never a data loss (`SyncBookkeepingStore`).
    func start(stateData: Data?) async

    func enqueueSaves(_ names: [SyncRecordName]) async

    func enqueueDeletes(_ names: [SyncRecordName]) async

    /// A launch/foreground/push kick. The engine also syncs on its own schedule; this
    /// is for the moments the app knows about and the engine doesn't.
    func fetchNow() async
}

/// How an engine hands its opaque state blob back for persistence. The engine is
/// constructed *before* the coordinator (it is one of the coordinator's init
/// parameters), so it cannot call back into the coordinator without a retain cycle or a
/// two-phase init; it writes straight to `SyncBookkeepingStore` through this closure
/// instead. `CKSyncEngine` emits `.stateUpdate` frequently and expects the blob to be
/// durable before the next launch.
typealias SyncEngineStatePersistence = @Sendable (Data) async -> Void

/// The CloudKit coordinates, in one place (design §3, §8).
enum SyncCloudIdentifiers {
    /// Reserved on the portal since 2026-07-31; these are the first entitlements that
    /// actually claim it (`project.yml`).
    static let containerIdentifier = "iCloud.org.pianohouseproject.raconte"
    /// One custom zone in the private database. A custom zone (not the default zone) is
    /// what makes `CKSyncEngine`'s record-zone change tracking available at all.
    static let zoneName = "RaconteZone"

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(_ name: SyncRecordName) -> CKRecord.ID {
        CKRecord.ID(recordName: name.rawValue, zoneID: zoneID)
    }
}

/// The production `CloudEngineControl`: a thin wrapper around `CKSyncEngine` plus its
/// delegate. Thin on purpose — every decision worth testing lives in `SyncCoordinator`,
/// where `FakeCloudEngine` can reach it, because nothing in this type can be unit-tested
/// without talking to CloudKit's servers. Its correctness is established by device smoke
/// (Gate A), not by the suite.
///
/// **Degrades silently, always.** No iCloud account, no network, an unsigned build, a
/// quota error — all of it surfaces as a log line and a dead-but-harmless engine.
/// Capture never waits on any of this (design §8), and nothing here is on a capture
/// path.
actor CloudKitEngineControl: CloudEngineControl, CKSyncEngineDelegate {
    private let containerIdentifier: String
    private let zoneID: CKRecordZone.ID
    private let persistState: SyncEngineStatePersistence
    private let log: Logger
    private var engine: CKSyncEngine?

    init(containerIdentifier: String = SyncCloudIdentifiers.containerIdentifier,
         zoneID: CKRecordZone.ID = SyncCloudIdentifiers.zoneID,
         persistState: @escaping SyncEngineStatePersistence,
         log: Logger = Logger(subsystem: "org.pianohouseproject.raconte", category: "sync")) {
        self.containerIdentifier = containerIdentifier
        self.zoneID = zoneID
        self.persistState = persistState
        self.log = log
    }

    // MARK: CloudEngineControl

    func start(stateData: Data?) async {
        guard engine == nil else { return }

        var serialization: CKSyncEngine.State.Serialization?
        if let stateData {
            // A default-configured coder both ways: the blob is opaque and this app has
            // no business imposing `CaptureCoding`'s date/key strategies on a type whose
            // interior it cannot see. A decode failure is not an error — it is the
            // disposable-cache rule, and costs a resync.
            serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self,
                                                      from: stateData)
            if serialization == nil {
                log.notice("sync: engine state present but undecodable — starting fresh")
            }
        }

        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        var configuration = CKSyncEngine.Configuration(database: database,
                                                       stateSerialization: serialization,
                                                       delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine

        // Every record this app writes lives in one custom zone, so the zone has to
        // exist before the first save lands. Enqueued on every start rather than only on
        // a fresh state: saving a zone that already exists is a server-side no-op, and
        // the alternative — trusting restored state to imply the zone was created —
        // silently never recovers if a previous run died between the two.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        log.info("sync: engine started (resumed: \(serialization != nil, privacy: .public))")
    }

    func enqueueSaves(_ names: [SyncRecordName]) async {
        guard let engine, !names.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: names.map {
            .saveRecord(SyncCloudIdentifiers.recordID($0))
        })
    }

    func enqueueDeletes(_ names: [SyncRecordName]) async {
        guard let engine, !names.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: names.map {
            .deleteRecord(SyncCloudIdentifiers.recordID($0))
        })
    }

    func fetchNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
        } catch {
            log.error("sync: fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            guard let data = try? JSONEncoder().encode(update.stateSerialization) else {
                log.error("sync: could not encode engine state — next launch resyncs")
                return
            }
            await persistState(data)
        case .accountChange(let change):
            // Signing out/in is not an error and never touches `captures/`; the engine
            // itself stops or resumes. Tasks 5+ decide whether anything local reacts.
            log.notice("sync: account change \(String(describing: change.changeType), privacy: .public)")
        case .fetchedRecordZoneChanges, .fetchedDatabaseChanges:
            // Ingest is Tasks 5+ (design §6). Skipping a fetched change here is safe:
            // nothing is written, and the engine will hand it over again after the next
            // token reset if this device ever needs it.
            log.debug("sync: fetched changes ignored (ingest not built yet)")
        case .sentRecordZoneChanges(let sent):
            for failure in sent.failedRecordSaves {
                log.error("""
                    sync: save failed \(failure.record.recordID.recordName, privacy: .public): \
                    \(failure.error.localizedDescription, privacy: .public)
                    """)
            }
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                log.error("""
                    sync: zone save failed \(failure.zone.zoneID.zoneName, privacy: .public): \
                    \(failure.error.localizedDescription, privacy: .public)
                    """)
            }
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break
        @unknown default:
            log.debug("sync: unhandled engine event")
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !pending.isEmpty else { return nil }

        // Record population is Tasks 5+. Until a builder exists, every pending change
        // resolves to nil, which is CKSyncEngine's documented "drop this one" answer —
        // deliberately chosen over returning nil for the whole batch, which would leave
        // the same unfulfillable changes pending and re-asked forever. Dropping is safe
        // because the upload ledger is only written after a record actually lands, so
        // the next launch's reconciliation scan re-enqueues everything dropped here.
        let log = self.log
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            log.debug("sync: no record builder yet for \(recordID.recordName, privacy: .public)")
            return nil
        }
    }
}
