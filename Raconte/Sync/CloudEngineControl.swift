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

    /// M4 T11 (design §5, "the delete wins"): removes not-yet-SENT save changes for
    /// `names` from the engine's pending queue. Never used for the Entry record's own
    /// removal — that routes through `enqueueDeletes`, the real CK delete whose
    /// server-side cascade takes every child record with it. This is for the child
    /// records themselves (audio/liveLog/revisions/marker streams): once their parent
    /// is gone, a save that was queued but never went out must simply be withdrawn,
    /// never sent to attach itself to nothing.
    func dropPendingSaves(_ names: [SyncRecordName]) async

    /// A launch/foreground/push kick. The engine also syncs on its own schedule; this
    /// is for the moments the app knows about and the engine doesn't.
    func fetchNow() async

    /// Debug-surface snapshot (M4 T12): live pending-change counts plus the last
    /// account/error state the engine's delegate callbacks observed. Never a live
    /// CloudKit query — nothing here can delay or wait on anything (design §8) — and
    /// never awaited by anything but the Debug screen.
    func snapshot() async -> EngineSnapshot
}

/// What `CloudEngineControl.snapshot()` hands back. `accountState`/`lastError` are
/// best-effort — the last thing the engine's delegate observed, not a live poll — since
/// `CKSyncEngine` has no synchronous "ask it now" API for either. Pending counts ARE
/// live: they read `CKSyncEngine.State.pendingRecordZoneChanges` directly.
struct EngineSnapshot: Equatable, Sendable {
    var accountState: String
    var pendingSaveCount: Int
    var pendingDeleteCount: Int
    var lastError: String?
}

/// How an engine hands its opaque state blob back for persistence. The engine is
/// constructed *before* the coordinator (it is one of the coordinator's init
/// parameters), so it cannot call back into the coordinator without a retain cycle or a
/// two-phase init; it writes straight to `SyncBookkeepingStore` through this closure
/// instead. `CKSyncEngine` emits `.stateUpdate` frequently and expects the blob to be
/// durable before the next launch.
typealias SyncEngineStatePersistence = @Sendable (Data) async -> Void

/// What an engine control does with changes it is handed before it can act on them.
///
/// The race is real and quiet: `SyncCoordinator.launch()` is fired from a `.task`, and
/// the coordinator is an actor, so a local-change hook (Tasks 5+) can interleave at any
/// of `launch()`'s suspension points — reading the engine state, or the whole
/// reconciliation scan — and arrive while `start()` has not yet produced a
/// `CKSyncEngine`. Dropping those names silently would make "the hooks are wired to an
/// engine that never started" indistinguishable from working: nothing uploads, nothing
/// logs, and the next launch's reconciliation quietly covers for it.
///
/// So they are buffered and replayed. **One ordered list, not a saves list and a deletes
/// list**, because order between the two carries meaning for the same record — a save
/// followed by a delete must not replay as a delete followed by a save.
///
/// Pure and separate from the actor precisely so this is unit-testable: everything
/// inside `CloudKitEngineControl` needs CloudKit's servers to exercise, and this does
/// not (`PendingEngineChangesTests`).
struct PendingEngineChanges: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        case save(SyncRecordName)
        case delete(SyncRecordName)
    }

    private(set) var changes: [Change] = []

    var isEmpty: Bool { changes.isEmpty }

    mutating func bufferSaves(_ names: [SyncRecordName]) {
        changes.append(contentsOf: names.map(Change.save))
    }

    /// M4 T11 fix round (review Important): strips any already-buffered SAVE for the
    /// same names before appending the deletes. Without this, a save buffered moments
    /// before its record's deletion (both still pre-engine-start) would replay
    /// alongside the delete in arrival order once the engine finally starts — the
    /// buffered-before-start mirror of `dropPendingSaves` needing this same "the
    /// delete wins" guarantee, not just the post-start path.
    mutating func bufferDeletes(_ names: [SyncRecordName]) {
        removeSaves(names)
        changes.append(contentsOf: names.map(Change.delete))
    }

    /// M4 T11: the buffered-before-start mirror of `dropPendingSaves` — a save
    /// buffered here (the engine hasn't produced a `CKSyncEngine` yet) whose capture
    /// was deleted before the engine even started must never replay. Deletes are left
    /// untouched; only `.save` entries naming one of `names` are removed.
    mutating func removeSaves(_ names: [SyncRecordName]) {
        let toRemove = Set(names)
        changes.removeAll { change in
            if case .save(let name) = change { return toRemove.contains(name) }
            return false
        }
    }

    /// Hands back everything buffered, in arrival order, and empties the buffer — so a
    /// second drain replays nothing. Draining is the only way changes leave.
    mutating func drain() -> [Change] {
        defer { changes = [] }
        return changes
    }
}

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
        recordID(name, zoneID: zoneID)
    }

    /// Explicit-zone overload: the record builders take a zone rather than reaching for
    /// the global one, so a test can build records in a throwaway zone and still assert
    /// the exact `recordName` production would mint.
    static func recordID(_ name: SyncRecordName, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: name.rawValue, zoneID: zoneID)
    }

    static func name(of recordID: CKRecord.ID) -> SyncRecordName? {
        SyncRecordName(rawValue: recordID.recordName)
    }
}

/// What a local write chokepoint tells the sync layer (design §3). One method, one
/// direction, no answer: a store that has just written a file says which record changed
/// and returns immediately. Nothing on a capture path may ever wait on sync (design §8),
/// and nothing here gives a store a way to.
///
/// Optional at every injection site — `nil` in unit tests, in the UI-test harness, and in
/// any build where `SyncCoordinator.live()` refused to construct an engine. A store with
/// no hook behaves exactly as it did before M4.
protocol SyncHooks: Sendable {
    func noteLocalChange(_ name: SyncRecordName) async

    /// A local DELETE (#80): the record is gone, not merely changed. Declared here as
    /// its own verb — a delete cannot be expressed as "call `noteLocalChange` and let
    /// the exchange notice the artifact vanished", because `recordToPush` degrading to
    /// nil is CloudKit's "drop this pending change" answer, not "tell the server to
    /// remove what it has".
    ///
    /// Default no-op in the extension below, kept even though `SyncCoordinator` (B2) now
    /// gives this verb a real body: test fakes such as `RecordingSyncHooks` predate
    /// journal deletion and must keep compiling unchanged without overriding it.
    func noteLocalDelete(_ name: SyncRecordName) async

    /// M4 T11: a local entry's now-gone CHILD records — audio/liveLog/revisions/
    /// marker streams, NEVER the Entry record itself (that still routes through
    /// `noteLocalDelete`, the real CK delete whose server-side cascade takes every
    /// child with it). Retires each name's ledger + system-fields bookkeeping and
    /// asks the engine to drop any not-yet-sent SAVE for it — design §5, "the delete
    /// wins": a revision minted moments before its capture was purged must never be
    /// pushed to attach itself to an Entry that no longer exists.
    ///
    /// Default no-op, same reasoning as `noteLocalDelete`'s: existing test fakes
    /// predate this verb and must keep compiling unchanged without overriding it.
    func noteLocalDeleteFamily(_ names: [SyncRecordName]) async
}

extension SyncHooks {
    func noteLocalDelete(_ name: SyncRecordName) async {}
    func noteLocalDeleteFamily(_ names: [SyncRecordName]) async {}
}

/// The CloudKit-side seam, and the mirror of `CloudEngineControl`.
///
/// `CloudEngineControl` is how the app talks *down* to CloudKit and deliberately carries
/// no CloudKit types. This is how CloudKit talks *up* to the app, and unavoidably does
/// carry them — a fetched change IS a `CKRecord`. Keeping the two directions in separate
/// protocols is what stops `SyncCoordinator` (the launch/enqueue decisions, driven in
/// tests by `FakeCloudEngine`) from ever having to import CloudKit.
///
/// Both conformers are testable without a server: `CKRecord`, `CKRecord.ID` and `CKAsset`
/// are all constructible offline. Only `CKSyncEngine` needs an account, which is why the
/// engine sits behind `CloudEngineControl` and this does not.
protocol CloudRecordExchange: Sendable {
    /// Build the record to push for `name`, or nil when there is nothing to push (the
    /// artifact is gone, or its kind is not built yet). Nil is `CKSyncEngine`'s documented
    /// "drop this one" answer.
    func recordToPush(for name: SyncRecordName, zoneID: CKRecordZone.ID) async -> CKRecord?

    /// A record arrived from the server — a fetched change, or the server's copy handed
    /// back on a save conflict. Merges it into local state.
    func acceptRemote(_ record: CKRecord) async

    /// A record this device pushed actually landed. Archives its system fields (so the
    /// next push carries the server's change tag) and records the upload digest (so the
    /// next launch's reconciliation does not re-enqueue it).
    func noteSaved(_ record: CKRecord) async

    /// A save this device attempted did not land — for any reason, conflict included.
    /// Discards whatever was remembered about that build, so a later confirmation for the
    /// same record name can never be credited to content the server never accepted.
    func noteSaveFailed(for name: SyncRecordName) async

    /// A save came back `CKError.unknownItem`: the server has no record with this ID,
    /// yet the push was an UPDATE built on this device's archived system fields
    /// (`sync/system-fields/<name>.bin`). Those fields describe a record that exists
    /// in some other CloudKit environment — every record first synced under dev
    /// carried dev change tags into the first production push and NOT_FOUND-ed forever.
    ///
    /// Drops the archived system fields and the upload-ledger entry so the next
    /// `recordToPush` builds a fresh CREATE. Returns `true` when there WAS archived
    /// state to drop — the caller's cue to re-enqueue at once. `false` means there was
    /// none, so the failure is not stale metadata but a dangling `CKRecord.Reference`
    /// (a child sent before its Entry landed); re-enqueueing that fails identically
    /// forever, and the next reconciliation scan retries it once the parent is up.
    ///
    /// Deliberate bias: if the server copy is missing because another device DELETED
    /// it, this recreates it. Local audio is ground truth and is never dropped on a
    /// server's say-so; the deletion, once fetched, still wins through
    /// `acceptRemoteEntryDeletion`/`acceptRemoteJournalDeletion` (design §5).
    func resolveUnknownItem(for name: SyncRecordName) async -> Bool

    /// Server copies handed back by failed saves. Merges each one and returns the records
    /// that must be re-enqueued for save — the merged content is produced by the next
    /// `recordToPush`, which by then reads merged local state plus the freshly archived
    /// server system fields.
    func resolvePushConflicts(_ serverRecords: [CKRecord]) async -> [SyncRecordName]

    /// An inbound deletion for a JOURNAL record (#80, B2). Takes a bare journal id, not
    /// a `SyncRecordName`, so a deletion for any other kind is structurally unable to
    /// reach the wrong handler.
    func acceptRemoteJournalDeletion(id: String) async

    /// An inbound deletion for an ENTRY record (M4 T11, design §5). Routes through
    /// `StagedRemover` exclusively — never `RecoveryExecutor`, never a raw
    /// `FileManager.removeItem` on `captures/` itself. Audio/Revision/LiveLog/
    /// MarkerStream deletions never reach this method, or any other:
    /// `CloudKitEngineControl.handleEvent`'s `fetchedRecordZoneChanges` switch keeps
    /// ignoring those, because they cascade from the SAME Entry deletion this method
    /// already handles — the whole capture directory (everything they would each
    /// individually name) goes with one staged rename.
    func acceptRemoteEntryDeletion(captureID: String) async
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
    private let exchange: any CloudRecordExchange
    private let persistState: SyncEngineStatePersistence
    private let log: Logger
    private var engine: CKSyncEngine?
    /// Changes that arrived before `start()` produced an engine — see
    /// `PendingEngineChanges`. Drained once, at the end of `start()`.
    private var pending = PendingEngineChanges()
    /// M4 T12: the last account state this device's delegate callback observed. Starts
    /// "unknown" — nothing queries `CKContainer.accountStatus()` synchronously; this
    /// only ever moves on an actual `.accountChange` event.
    private var accountState = "unknown"
    /// M4 T12: the most recent error surfaced through ANY delegate path (fetch, a
    /// non-conflict save failure, a zone-save failure, a delete failure). Overwritten by
    /// whichever happens next — this is "what would the owner want to see first on the
    /// Debug screen", not a history.
    private var lastError: String?

    init(containerIdentifier: String = SyncCloudIdentifiers.containerIdentifier,
         zoneID: CKRecordZone.ID = SyncCloudIdentifiers.zoneID,
         exchange: any CloudRecordExchange,
         persistState: @escaping SyncEngineStatePersistence,
         log: Logger = Logger(subsystem: "org.pianohouseproject.raconte", category: "sync")) {
        self.containerIdentifier = containerIdentifier
        self.zoneID = zoneID
        self.exchange = exchange
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

        // Replay anything a hook handed over while the engine was still booting, in
        // arrival order. Nothing is lost to the race and nothing is enqueued twice: the
        // buffer empties as it drains.
        let replayed = pending.drain()
        if !replayed.isEmpty {
            log.notice("sync: replaying \(replayed.count, privacy: .public) change(s) buffered before start")
            for change in replayed {
                switch change {
                case .save(let name): apply(.saveRecord(SyncCloudIdentifiers.recordID(name)), to: engine)
                case .delete(let name): apply(.deleteRecord(SyncCloudIdentifiers.recordID(name)), to: engine)
                }
            }
        }
    }

    func enqueueSaves(_ names: [SyncRecordName]) async {
        guard !names.isEmpty else { return }
        guard let engine else {
            pending.bufferSaves(names)
            return
        }
        engine.state.add(pendingRecordZoneChanges: names.map {
            .saveRecord(SyncCloudIdentifiers.recordID($0))
        })
    }

    func enqueueDeletes(_ names: [SyncRecordName]) async {
        guard !names.isEmpty else { return }
        guard let engine else {
            pending.bufferDeletes(names)
            return
        }
        engine.state.add(pendingRecordZoneChanges: names.map {
            .deleteRecord(SyncCloudIdentifiers.recordID($0))
        })
    }

    /// M4 T11: `CKSyncEngine.State.remove(pendingRecordZoneChanges:)` is the documented
    /// inverse of `add` — a change removed here simply never goes out, exactly like one
    /// that was never enqueued in the first place. Deliberately only ever asked to
    /// remove SAVE changes (see the protocol doc comment); a delete for the same name
    /// is left untouched, since a delete is exactly what a purged child's own record
    /// (were one ever pushed for it) would need.
    func dropPendingSaves(_ names: [SyncRecordName]) async {
        guard !names.isEmpty else { return }
        guard let engine else {
            pending.removeSaves(names)
            return
        }
        engine.state.remove(pendingRecordZoneChanges: names.map {
            .saveRecord(SyncCloudIdentifiers.recordID($0))
        })
    }

    private func apply(_ change: CKSyncEngine.PendingRecordZoneChange, to engine: CKSyncEngine) {
        engine.state.add(pendingRecordZoneChanges: [change])
    }

    func fetchNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
        } catch {
            log.error("sync: fetch failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    /// M4 T12: pending counts come straight from `CKSyncEngine.State` (or, before the
    /// engine exists, the pre-start buffer) — live, not remembered — since that state IS
    /// the authoritative "what still has to go out."
    func snapshot() async -> EngineSnapshot {
        var saveCount = 0
        var deleteCount = 0
        if let engine {
            for change in engine.state.pendingRecordZoneChanges {
                switch change {
                case .saveRecord: saveCount += 1
                case .deleteRecord: deleteCount += 1
                @unknown default: break
                }
            }
        } else {
            for change in pending.changes {
                switch change {
                case .save: saveCount += 1
                case .delete: deleteCount += 1
                }
            }
        }
        return EngineSnapshot(accountState: accountState, pendingSaveCount: saveCount,
                              pendingDeleteCount: deleteCount, lastError: lastError)
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
            // M4 T12: recorded for the Debug screen only — nothing here changes any
            // sync DECISION, which stays entirely `CKSyncEngine`'s to make. The raw
            // `String(describing:)` (rather than switching over the enum's cases by
            // name) is deliberate: this is a debug label, not a decision input, and it
            // stays correct across any future case CloudKit adds to `ChangeType`.
            accountState = String(describing: change.changeType)
        case .fetchedRecordZoneChanges(let fetched):
            for modification in fetched.modifications {
                await exchange.acceptRemote(modification.record)
            }
            for deletion in fetched.deletions {
                guard let name = SyncCloudIdentifiers.name(of: deletion.recordID) else {
                    log.notice("sync: a deleted record's name does not parse — ignored")
                    continue
                }
                switch name {
                case .journal(let id):
                    await exchange.acceptRemoteJournalDeletion(id: id)
                case .entry(let captureID):
                    await exchange.acceptRemoteEntryDeletion(captureID: captureID)
                case .audio, .revision, .liveLog, .markerStream:
                    // These cascade from the SAME Entry deletion `.entry` above already
                    // handles (design §5: children carry `.deleteSelf`, so purging the
                    // Entry takes them with it server-side) — whatever order their own
                    // deletion events arrive in, ignoring them individually is safe: the
                    // whole capture directory is already gone (or never existed here)
                    // the instant the Entry-level staged removal runs.
                    log.debug("""
                        sync: \(name.rawValue, privacy: .public) deletion ignored (cascades \
                        with its Entry)
                        """)
                }
            }
        case .fetchedDatabaseChanges:
            // Zone-level changes. Nothing to do while this app has exactly one zone that
            // it creates itself on every start.
            break
        case .sentRecordZoneChanges(let sent):
            // Where the upload ledger is written: a record that actually landed gets its
            // sha256/bytes recorded, which is what stops the next launch's reconciliation
            // from re-enqueueing it, plus its system fields archived so the next push
            // carries the server's change tag.
            for record in sent.savedRecords {
                await exchange.noteSaved(record)
            }
            await handleFailedSaves(sent.failedRecordSaves, syncEngine: syncEngine)
            // Deletions get no ledger entry — `SyncPlanner` never re-derives a delete
            // (it iterates the disk scan, and a deleted artifact is not in it), so there
            // is nothing to record and nothing that retries. That makes the log the ONLY
            // evidence a delete ever left this device, which is what the owner's smoke
            // ("delete here, watch it vanish there") has to be debugged from when it
            // doesn't (gate finding, Minor 1).
            for recordID in sent.deletedRecordIDs {
                log.notice("sync: deleted \(recordID.recordName, privacy: .public) on the server")
            }
            for failure in sent.failedRecordDeletes {
                log.error("""
                    sync: delete failed \(failure.key.recordName, privacy: .public): \
                    \(failure.value.localizedDescription, privacy: .public) — not retried
                    """)
                lastError = failure.value.localizedDescription
            }
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                log.error("""
                    sync: zone save failed \(failure.zone.zoneID.zoneName, privacy: .public): \
                    \(failure.error.localizedDescription, privacy: .public)
                    """)
                lastError = failure.error.localizedDescription
            }
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break
        @unknown default:
            log.debug("sync: unhandled engine event")
        }
    }

    /// A save that came back `.serverRecordChanged` is the push half of design §4's
    /// per-field LWW. The server's copy is merged into local state through the same ingest
    /// path a fetched change takes — same rules, one implementation — and the record is
    /// re-enqueued. The merged CONTENT is not assembled here: the next
    /// `nextRecordZoneChangeBatch` rebuilds it from the now-merged store plus the freshly
    /// archived server system fields, so there is exactly one path from local state to a
    /// pushed record.
    ///
    /// Any other failure is logged and dropped. Dropping is safe for the same reason the
    /// batch builder's nil is: no ledger entry was written, so the next launch's
    /// reconciliation scan re-enqueues it.
    private func handleFailedSaves(_ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
                                   syncEngine: CKSyncEngine) async {
        var conflicts: [CKRecord] = []
        for failure in failures {
            // Every failure, conflict or not, retires what the exchange remembered about
            // that build — the content it describes was not accepted, so no later
            // confirmation may be credited to it.
            if let name = SyncCloudIdentifiers.name(of: failure.record.recordID) {
                await exchange.noteSaveFailed(for: name)
            }
            if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                conflicts.append(server)
            } else {
                log.error("""
                    sync: save failed \(failure.record.recordID.recordName, privacy: .public): \
                    \(failure.error.localizedDescription, privacy: .public)
                    """)
                lastError = failure.error.localizedDescription
            }
        }
        guard !conflicts.isEmpty else { return }
        let toResave = await exchange.resolvePushConflicts(conflicts)
        syncEngine.state.add(pendingRecordZoneChanges: toResave.map {
            .saveRecord(SyncCloudIdentifiers.recordID($0, zoneID: zoneID))
        })
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !pending.isEmpty else { return nil }

        // A change whose record cannot be built resolves to nil, which is CKSyncEngine's
        // documented "drop this one" answer — deliberately chosen over returning nil for
        // the whole batch, which would leave the same unfulfillable changes pending and
        // re-asked forever. Dropping is safe because the upload ledger is only written
        // after a record actually lands, so the next launch's reconciliation scan
        // re-enqueues everything dropped here.
        let log = self.log
        let exchange = self.exchange
        let zoneID = self.zoneID
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            guard let name = SyncCloudIdentifiers.name(of: recordID) else {
                log.error("sync: pending change for an unparseable record name — dropped")
                return nil
            }
            return await exchange.recordToPush(for: name, zoneID: zoneID)
        }
    }
}
