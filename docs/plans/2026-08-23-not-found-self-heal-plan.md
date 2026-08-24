# NOT_FOUND Self-Heal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A record whose push fails `CKError.unknownItem` (server NOT_FOUND) heals itself on the next push instead of failing identically forever, and a child record never ships a `CKRecord.Reference` to an Entry the server cannot hold.

**Architecture:** `CloudKitEngineControl` (the `CKSyncEngine` delegate) is deliberately a thin, untestable wrapper — every decision worth testing lives behind the `CloudRecordExchange` seam in `SyncRecordExchange`, or in a pure type. So the fix is three pieces: (1) a new exchange verb `resolveUnknownItem(for:)` that drops the archived system fields + ledger entry and reports whether there was anything to drop; (2) a pure `SaveFailureDisposition` table the delegate switches on, which also re-enqueues immediately (the conflict path already does — no relaunch needed); (3) a child-record guard in the builders so Audio/LiveLog/Revision/MarkerStream refuse to build while their Entry can neither be found on the server nor built now. Then bump `CFBundleVersion` for iOS TestFlight build 2.

**Tech Stack:** Swift 6 strict concurrency, CloudKit / CKSyncEngine, XCTest (macOS host, no server traffic).

**Spec:** No separate spec. Authority is the root-cause analysis in `CLAUDE.md` § "Session 2026-08-23" (CRITICAL BUG bullet) plus the rulings listed under Global Constraints below. The M4 sync design (`docs/plans/archive/`, §4 conflict mechanics, §5 delete-wins, §8 nothing waits on sync) binds where this plan touches it.

## Global Constraints

- Tests never talk to CloudKit servers. `CKRecord`, `CKRecord.ID`, `CKAsset`, `CKRecord.Reference` are constructed offline; `CKSyncEngine` is never instantiated in a test.
- Test command (macOS host, ad-hoc signed against the nocloud entitlements — NEVER `CODE_SIGNING_ALLOWED=NO`, which unsandboxes app-hosted tests onto the owner's real data). If `Raconte.xcodeproj` is absent, run `xcodegen generate` first:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements \
  -only-testing:RaconteTests/<TestClass> test
```

- Run the test command in the FOREGROUND with an explicit `timeout` of 600000 ms. Never background an `xcodebuild` run.
- Every test asserts a behavior that a plausible one-line mutation of the production code would break; the task report names the mutation tried and the assertion that caught it.
- `.unknownItem` → re-enqueue ONLY when archived system fields existed for that name. A record with no archived state that NOT_FOUNDs is a dangling reference (child before parent); re-enqueueing it loops forever. Leave it to reconciliation.
- `.batchRequestFailed` siblings are re-enqueued as-is; their archived state is NEVER cleared.
- `.zoneNotFound` is deliberately NOT handled in this plan (the zone is re-saved on every `start()`); it stays in the `.drop` bucket with a comment saying so.
- Resurrection is the documented bias: a record the server deleted that this device still holds gets re-CREATED by this path; the deletion still wins once fetched (design §5). Say so in the doc comment; pin it with a test.
- Doc comments match the surrounding density and voice (terse, "why", no "this line does X"). No comment says where a change came from or that it is correct.
- Commit per task, on the worktree branch, never on `main`.

---

### Task 1: `resolveUnknownItem(for:)` on the exchange

**Files:**
- Modify: `Raconte/Sync/CloudEngineControl.swift:222-231` (the `CloudRecordExchange` protocol, after `noteSaveFailed`)
- Modify: `Raconte/Sync/SyncIngest.swift:1123-1128` (after `noteSaveFailed`; `forgetServerState(for:)` is at `:2387`)
- Create: `RaconteTests/SyncUnknownItemTests.swift`

**Interfaces:**
- Consumes: `SyncBookkeepingStore.systemFields(for:)`, `SyncRecordExchange.forgetServerState(for:)` (private, existing — drops system fields + ledger entry), `SyncPlanner.reconcile(scan:ledger:)`, `SyncTreeScanner`.
- Produces: `func resolveUnknownItem(for name: SyncRecordName) async -> Bool` on `CloudRecordExchange` (Task 2 calls it).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import CloudKit
@testable import Raconte

/// The self-heal for a push that came back `CKError.unknownItem` (server NOT_FOUND).
/// Seen for real 2026-08-23: records first synced under the dev CloudKit environment
/// carried dev change tags into the first production push and failed identically
/// forever. No server, no engine — the exchange and bookkeeping run on a throwaway
/// container root.
final class SyncUnknownItemTests: XCTestCase {

    private var containerRoot: URL!
    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let deviceID = "AAAAAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncUnknownItem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private struct Fixture {
        let store: JournalStore
        let bookkeeping: SyncBookkeepingStore
        let scanner: SyncTreeScanner
        let exchange: SyncRecordExchange
    }

    private func fixture() -> Fixture {
        let store = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: store)
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let scanner = SyncTreeScanner(containerRoot: containerRoot, deviceID: deviceID)
        let exchange = SyncRecordExchange(journalStore: store, coverStore: covers,
                                          bookkeeping: bookkeeping, deviceID: deviceID,
                                          containerRoot: containerRoot)
        return Fixture(store: store, bookkeeping: bookkeeping, scanner: scanner, exchange: exchange)
    }

    /// Pushes `name` once through the real exchange so its system fields are archived
    /// and its upload is ledgered — the exact state a record synced under the dev
    /// environment is in when the app first talks to production.
    private func pushOnce(_ name: SyncRecordName, through exchange: SyncRecordExchange) async throws {
        let record = try XCTUnwrap(await exchange.recordToPush(for: name, zoneID: zoneID))
        await exchange.noteSaved(record)
    }

    /// The bug: stale archived state makes every push an UPDATE against an ID the
    /// server never had. After resolving, the record must read as never-uploaded — no
    /// system fields (next build is a CREATE), no ledger entry (reconciliation would
    /// re-enqueue it) — and the answer must be `true`, the caller's cue to re-enqueue
    /// at once rather than wait for a relaunch.
    func testStaleServerStateIsDroppedAndTheRecordReadsAsNeverUploaded() async throws {
        let f = fixture()
        let created = try await f.store.create(name: "Synced under dev")
        let name = SyncRecordName.journal(id: created.id)
        try await pushOnce(name, through: f.exchange)
        let fieldsBefore = await f.bookkeeping.systemFields(for: name.rawValue)
        XCTAssertNotNil(fieldsBefore, "fixture sanity: archived system fields exist")

        let hadServerState = await f.exchange.resolveUnknownItem(for: name)

        let fieldsAfter = await f.bookkeeping.systemFields(for: name.rawValue)
        let ledgerAfter = await f.bookkeeping.ledger()
        let plan = SyncPlanner.reconcile(scan: f.scanner.scan().artifacts, ledger: ledgerAfter)
        XCTAssertTrue(hadServerState, "there was stale state to drop, so the caller re-enqueues now")
        XCTAssertNil(fieldsAfter, "next push must be a create, not an update against a dev change tag")
        XCTAssertNil(ledgerAfter[name.rawValue], "reads as never-uploaded")
        XCTAssertTrue(plan.contains(name), "and reconciliation agrees: it would re-enqueue this journal")
        let rebuilt = await f.exchange.recordToPush(for: name, zoneID: zoneID)
        XCTAssertNotNil(rebuilt, "the local copy is still pushed — nothing local is dropped on a server's say-so")
    }

    /// A NOT_FOUND with nothing archived is not stale metadata — it is a child whose
    /// Entry has not landed (dangling `CKRecord.Reference`). Re-enqueueing it would fail
    /// the same way forever, so the answer must be `false`, and nothing local moves.
    func testARecordWithNoArchivedStateReportsFalseAndIsLeftToReconciliation() async throws {
        let f = fixture()
        let created = try await f.store.create(name: "Never pushed")
        let name = SyncRecordName.journal(id: created.id)

        let hadServerState = await f.exchange.resolveUnknownItem(for: name)

        let fields = await f.bookkeeping.systemFields(for: name.rawValue)
        let ledger = await f.bookkeeping.ledger()
        let survivor = try await f.store.journal(id: created.id)
        XCTAssertFalse(hadServerState)
        XCTAssertNil(fields)
        XCTAssertNil(ledger[name.rawValue])
        XCTAssertNotNil(survivor, "resolving is bookkeeping only — never touches the journal itself")
    }

    /// Batches fail atomically, so the poisoned record's siblings arrive in the same
    /// failure list. Only the name asked about may lose its archived state.
    func testResolvingOneNameLeavesEverySiblingsArchivedStateIntact() async throws {
        let f = fixture()
        let poisoned = try await f.store.create(name: "Poisoned")
        let sibling = try await f.store.create(name: "Healthy sibling")
        let poisonedName = SyncRecordName.journal(id: poisoned.id)
        let siblingName = SyncRecordName.journal(id: sibling.id)
        try await pushOnce(poisonedName, through: f.exchange)
        try await pushOnce(siblingName, through: f.exchange)

        _ = await f.exchange.resolveUnknownItem(for: poisonedName)

        let siblingFields = await f.bookkeeping.systemFields(for: siblingName.rawValue)
        let ledger = await f.bookkeeping.ledger()
        XCTAssertNotNil(siblingFields, "the sibling's change tag is valid and must be kept")
        XCTAssertNotNil(ledger[siblingName.rawValue])
        XCTAssertNil(ledger[poisonedName.rawValue])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the Global Constraints test command with `-only-testing:RaconteTests/SyncUnknownItemTests`.
Expected: compile error — `resolveUnknownItem` is not a member of `SyncRecordExchange`.

- [ ] **Step 3: Add the protocol requirement**

In `Raconte/Sync/CloudEngineControl.swift`, directly after `func noteSaveFailed(for name: SyncRecordName) async` (line 225), add:

```swift
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
```

- [ ] **Step 4: Implement it on the exchange**

In `Raconte/Sync/SyncIngest.swift`, directly after `noteSaveFailed(for:)` (ends line 1128), add:

```swift
    func resolveUnknownItem(for name: SyncRecordName) async -> Bool {
        let hadServerState = await bookkeeping.systemFields(for: name.rawValue) != nil
        await forgetServerState(for: name)
        if hadServerState {
            log.notice("""
                sync: \(name.rawValue, privacy: .public) unknown to the server — archived \
                system fields dropped, next push is a create
                """)
        } else {
            log.notice("""
                sync: \(name.rawValue, privacy: .public) unknown to the server with nothing \
                archived — a reference to a record not yet there; left to reconciliation
                """)
        }
        return hadServerState
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Same command. Expected: 3/3 pass.

- [ ] **Step 6: Mutation check (report it, do not keep it)**

Change `let hadServerState = ... != nil` to `let hadServerState = true` — `testARecordWithNoArchivedStateReportsFalse…` must fail. Change `await forgetServerState(for: name)` to a no-op — `testStaleServerStateIsDropped…` must fail on `fieldsAfter`. Revert both; record which assertion caught each in the task report.

- [ ] **Step 7: Commit**

```bash
git add Raconte/Sync/CloudEngineControl.swift Raconte/Sync/SyncIngest.swift RaconteTests/SyncUnknownItemTests.swift
git commit -m "fix(sync): resolveUnknownItem drops stale server state so a NOT_FOUND push heals into a create"
```

---

### Task 2: `SaveFailureDisposition` + wire `handleFailedSaves` to re-enqueue

**Files:**
- Create: `Raconte/Sync/SaveFailureDisposition.swift`
- Create: `RaconteTests/SaveFailureDispositionTests.swift`
- Modify: `Raconte/Sync/CloudEngineControl.swift:511-547` (`handleFailedSaves` and its doc comment)

**Interfaces:**
- Consumes: `CloudRecordExchange.resolveUnknownItem(for:) async -> Bool` (Task 1), `resolvePushConflicts`, `noteSaveFailed`, `SyncCloudIdentifiers.recordID(_:zoneID:)`.
- Produces: `SaveFailureDisposition.decide(code:hasServerRecord:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import CloudKit
@testable import Raconte

/// The routing table `CloudKitEngineControl.handleFailedSaves` switches on. The delegate
/// method itself takes `CKSyncEngine` failure types nothing outside CloudKit can build,
/// so the decision is pulled out here where a plain `CKError.Code` drives it.
final class SaveFailureDispositionTests: XCTestCase {

    func testAConflictWithAServerCopyMerges() {
        XCTAssertEqual(SaveFailureDisposition.decide(code: .serverRecordChanged, hasServerRecord: true),
                       .mergeConflict)
    }

    /// The pre-existing rule: a conflict that hands back no server copy has nothing to
    /// merge and was always dropped to the next reconciliation.
    func testAConflictWithoutAServerCopyDrops() {
        XCTAssertEqual(SaveFailureDisposition.decide(code: .serverRecordChanged, hasServerRecord: false),
                       .drop)
    }

    func testUnknownItemRecreates() {
        XCTAssertEqual(SaveFailureDisposition.decide(code: .unknownItem, hasServerRecord: false),
                       .recreate)
    }

    /// A sibling taken down by another record's failure in the same atomic batch did
    /// nothing wrong: it goes out again untouched.
    func testBatchRequestFailedRetries() {
        XCTAssertEqual(SaveFailureDisposition.decide(code: .batchRequestFailed, hasServerRecord: false),
                       .retry)
    }

    /// Everything else — including `.zoneNotFound`, deliberately left out of this plan
    /// because the zone is re-saved on every engine start — is logged and dropped.
    func testEverythingElseDrops() {
        for code in [CKError.Code.zoneNotFound, .quotaExceeded, .networkFailure, .internalError] {
            XCTAssertEqual(SaveFailureDisposition.decide(code: code, hasServerRecord: false), .drop,
                           "\(code)")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

`-only-testing:RaconteTests/SaveFailureDispositionTests`. Expected: compile error, `SaveFailureDisposition` undefined.

- [ ] **Step 3: Create the pure type**

`Raconte/Sync/SaveFailureDisposition.swift`:

```swift
import CloudKit

/// What `CloudKitEngineControl.handleFailedSaves` does with one failed record save.
/// Decided from the `CKError.Code` alone so the table is unit-testable — the delegate
/// method takes `CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave`, which
/// nothing outside CloudKit can construct.
enum SaveFailureDisposition: Equatable, Sendable {
    /// `.serverRecordChanged` with the server's copy attached: design §4's per-field
    /// LWW merge through `CloudRecordExchange.resolvePushConflicts`, then re-enqueue.
    case mergeConflict
    /// `.unknownItem`: the server holds no record with this ID. Drop this device's
    /// archived server state (`CloudRecordExchange.resolveUnknownItem`) so the next
    /// push is a CREATE; re-enqueue only if there was state to drop.
    case recreate
    /// `.batchRequestFailed`: this record was fine — a sibling in the same atomic batch
    /// failed and took it down with it. Re-enqueue as-is, archived state untouched.
    case retry
    /// Anything else: log, surface as `lastError`, leave to the next reconciliation
    /// scan. `.zoneNotFound` sits here on purpose — the zone is re-saved on every
    /// `start()`, so a missing zone heals on the next launch without special handling.
    case drop

    static func decide(code: CKError.Code, hasServerRecord: Bool) -> SaveFailureDisposition {
        switch code {
        case .serverRecordChanged where hasServerRecord: return .mergeConflict
        case .unknownItem: return .recreate
        case .batchRequestFailed: return .retry
        default: return .drop
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command. Expected: 5/5 pass.

- [ ] **Step 5: Rewrite `handleFailedSaves`**

Replace `Raconte/Sync/CloudEngineControl.swift` lines 511-547 (the doc comment and the whole method) with:

```swift
    /// One `SaveFailureDisposition` per failed save, then ONE re-enqueue of everything
    /// that should go out again. Re-enqueueing here — not waiting for the next launch's
    /// reconciliation scan — is what makes a heal visible without a relaunch; the
    /// content is never assembled here, the next `nextRecordZoneChangeBatch` rebuilds it
    /// from local state plus whatever system fields are (still) archived, so there is
    /// exactly one path from local state to a pushed record.
    ///
    /// A `.drop`, and a `.recreate` that found nothing archived, are safe to leave for
    /// the same reason the batch builder's nil is: no ledger entry was written, so the
    /// next reconciliation scan re-enqueues them.
    private func handleFailedSaves(_ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
                                   syncEngine: CKSyncEngine) async {
        var conflicts: [CKRecord] = []
        var toResend: [SyncRecordName] = []
        for failure in failures {
            let recordName = failure.record.recordID.recordName
            let name = SyncCloudIdentifiers.name(of: failure.record.recordID)
            // Every failure, whatever its disposition, retires what the exchange
            // remembered about that build — the content it describes was not accepted,
            // so no later confirmation may be credited to it.
            if let name {
                await exchange.noteSaveFailed(for: name)
            }
            switch SaveFailureDisposition.decide(code: failure.error.code,
                                                 hasServerRecord: failure.error.serverRecord != nil) {
            case .mergeConflict:
                if let server = failure.error.serverRecord {
                    conflicts.append(server)
                }
            case .recreate:
                guard let name else { break }
                if await exchange.resolveUnknownItem(for: name) {
                    toResend.append(name)
                } else {
                    lastError = failure.error.localizedDescription
                }
            case .retry:
                guard let name else { break }
                log.notice("sync: \(recordName, privacy: .public) fell with its batch — re-enqueued")
                toResend.append(name)
            case .drop:
                log.error("""
                    sync: save failed \(recordName, privacy: .public): \
                    \(failure.error.localizedDescription, privacy: .public)
                    """)
                lastError = failure.error.localizedDescription
            }
        }
        if !conflicts.isEmpty {
            toResend += await exchange.resolvePushConflicts(conflicts)
        }
        guard !toResend.isEmpty else { return }
        syncEngine.state.add(pendingRecordZoneChanges: toResend.map {
            .saveRecord(SyncCloudIdentifiers.recordID($0, zoneID: zoneID))
        })
    }
```

- [ ] **Step 6: Build the app target and run the sync suites that exercise the exchange**

Run the test command with `-only-testing:RaconteTests/SyncUnknownItemTests -only-testing:RaconteTests/SaveFailureDispositionTests -only-testing:RaconteTests/SyncJournalIngestTests -only-testing:RaconteTests/SyncCoordinatorTests` (multiple `-only-testing:` flags are allowed). Expected: everything passes; the app target compiles under Swift 6 strict concurrency (the `await` inside the `switch` on an actor is fine — `handleFailedSaves` is already `async` on the actor).

- [ ] **Step 7: Mutation check (report it, do not keep it)**

In `decide`, swap the `.unknownItem` and `.batchRequestFailed` return values — `testUnknownItemRecreates` and `testBatchRequestFailedRetries` must both fail. Revert; record in the report.

- [ ] **Step 8: Commit**

```bash
git add Raconte/Sync/SaveFailureDisposition.swift RaconteTests/SaveFailureDispositionTests.swift Raconte/Sync/CloudEngineControl.swift
git commit -m "fix(sync): route failed saves by disposition; NOT_FOUND recreates and batch casualties retry without a relaunch"
```

---

### Task 3: Children refuse to build while their Entry cannot be pushed

**Files:**
- Modify: `Raconte/Sync/SyncIngest.swift` — `revisionRecordToPush` (`:810-837`), `audioRecordToPush` (`:955-990`), `liveLogRecordToPush` (`:998-1024`), `markerStreamRecordToPush` (`:1048-1083`); new private helper next to `loadFinalizedManifest` (`:854-861`)
- Create: `RaconteTests/SyncChildHoldbackTests.swift`

**Interfaces:**
- Consumes: `loadFinalizedManifest(capturesRoot:captureID:)`, `EntryMetadataStore.decode(_:)`, `SyncBookkeepingStore.systemFields(for:)`, `SegmentLayout.entryMetadataURL(captureDirectory:)`.
- Produces: private `entryCanBePushed(capturesRoot:captureID:) async -> Bool`. Nothing later depends on it.

Background for the implementer: each child record carries `CKRecord.Reference(recordID: <Entry>, action: .deleteSelf)`. CloudKit rejects a save whose reference targets a record it does not hold. Today the Entry and its children are built independently in the same batch; if the Entry's build returns nil (transient `entry.json` read/decode failure) the children still ship and NOT_FOUND. With Task 1's rule a child with no archived state is NOT re-enqueued, so this is no longer an infinite loop — but it is still a wasted failed push per launch, and this guard stops it at the source.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import CloudKit
@testable import Raconte

/// A child record (AudioAsset/LiveLog/MarkerStream/Revision) references its Entry with
/// `.deleteSelf`; CloudKit rejects the save if the Entry is not on the server. The
/// children must therefore hold back whenever the Entry can neither be found there
/// (archived system fields) nor built right now. Fixtures mirror `SyncEntryRecordTests`.
final class SyncChildHoldbackTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private let deviceID = "device-low"
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RaconteSyncChildHoldback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }
    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }
    private var entryURL: URL { SegmentLayout.entryMetadataURL(captureDirectory: captureDirectory) }

    private func format() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4)
    }

    private func writeVerifiedManifest() throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete,
                                stateSeq: 1, stateUpdatedAt: when, format: format(),
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
    }

    private func writeFinalM4a() throws {
        let url = SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("m4a-bytes".utf8).write(to: url)
    }

    private func writeLiveLog() throws {
        let dir = SegmentLayout.transcriptDirectory(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: SegmentLayout.liveTranscriptURL(captureDirectory: captureDirectory))
    }

    private func writeMarkerLog() throws {
        let url = SegmentLayout.markerLogURL(captureDirectory: captureDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: url)
    }

    /// The codebase's "exists but unreadable" technique: a directory at the file's path.
    private func makeEntryMetadataUnreadable() throws {
        try? FileManager.default.removeItem(at: entryURL)
        try FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
    }

    private func exchange() -> (SyncRecordExchange, SyncBookkeepingStore) {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        let bookkeeping = SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
        let ex = SyncRecordExchange(journalStore: journalStore, coverStore: covers,
                                    bookkeeping: bookkeeping, deviceID: deviceID,
                                    containerRoot: containerRoot)
        return (ex, bookkeeping)
    }

    private func children() -> [SyncRecordName] {
        [.audio(captureID: captureID), .liveLog(captureID: captureID),
         .markerStream(captureID: captureID, deviceID: deviceID)]
    }

    /// The defect: Entry build fails (unreadable entry.json), children still built and
    /// shipped a reference to nothing.
    func testChildrenHoldBackWhenTheEntryCannotBeBuiltAndHasNeverLanded() async throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        try writeLiveLog()
        try writeMarkerLog()
        try makeEntryMetadataUnreadable()
        let (ex, _) = exchange()

        let entry = await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID)
        XCTAssertNil(entry, "fixture sanity: the Entry itself refuses")
        for child in children() {
            let record = await ex.recordToPush(for: child, zoneID: zoneID)
            XCTAssertNil(record, "\(child.rawValue) must not ship a reference to an Entry that is not on the server")
        }
    }

    /// Once the Entry has landed (system fields archived), a later transient failure to
    /// rebuild it must NOT hold the children back — the reference target exists.
    func testChildrenStillPushWhenTheEntryAlreadyLandedEvenIfItCannotBeRebuiltNow() async throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        try writeLiveLog()
        try writeMarkerLog()
        try EntryMetadataStore.write(EntryMetadata(journalID: ULID.make()), url: entryURL)
        let (ex, bookkeeping) = exchange()
        let landed = try XCTUnwrap(await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID))
        await ex.noteSaved(landed)
        let archived = await bookkeeping.systemFields(for: SyncRecordName.entry(captureID: captureID).rawValue)
        XCTAssertNotNil(archived, "fixture sanity: the Entry is on the server")
        try makeEntryMetadataUnreadable()

        for child in children() {
            let record = await ex.recordToPush(for: child, zoneID: zoneID)
            XCTAssertNotNil(record, "\(child.rawValue) references an Entry the server already holds")
        }
    }

    /// An ABSENT entry.json is the ordinary untouched-entry case: the Entry builds from
    /// `.defaults`, so the children go out with it.
    func testChildrenPushAlongsideAnEntryWithNoMetadataFile() async throws {
        try writeVerifiedManifest()
        try writeFinalM4a()
        try writeLiveLog()
        try writeMarkerLog()
        let (ex, _) = exchange()

        let entry = await ex.recordToPush(for: .entry(captureID: captureID), zoneID: zoneID)
        XCTAssertNotNil(entry)
        for child in children() {
            let record = await ex.recordToPush(for: child, zoneID: zoneID)
            XCTAssertNotNil(record, "\(child.rawValue)")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify the first one fails**

`-only-testing:RaconteTests/SyncChildHoldbackTests`. Expected: `testChildrenHoldBackWhenTheEntryCannotBeBuilt…` fails on all three children (they currently build); the other two pass.

- [ ] **Step 3: Add the predicate**

In `Raconte/Sync/SyncIngest.swift`, directly after `loadFinalizedManifest` (ends line 861), add:

```swift
    /// Whether a CHILD record (AudioAsset/LiveLog/Revision/MarkerStream) may go out for
    /// `captureID` right now. Each carries a `CKRecord.Reference` to its Entry, and
    /// CloudKit rejects a save whose reference targets a record it does not hold — so
    /// a child is safe only when the Entry has already landed (archived system fields)
    /// or would build alongside it: a finalized manifest and an entry.json that is
    /// absent (`.defaults`) or decodable, the same three-answer rule
    /// `entryRecordToPush` applies. Holding back costs nothing — no ledger entry is
    /// written, so the next reconciliation scan re-enqueues the child.
    private func entryCanBePushed(capturesRoot: URL, captureID: String) async -> Bool {
        let entryName = SyncRecordName.entry(captureID: captureID)
        if await bookkeeping.systemFields(for: entryName.rawValue) != nil {
            return true
        }
        guard loadFinalizedManifest(capturesRoot: capturesRoot, captureID: captureID) != nil else {
            return false
        }
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        let entryURL = SegmentLayout.entryMetadataURL(captureDirectory: directory)
        guard FileManager.default.fileExists(atPath: entryURL.path) else { return true }
        guard let data = try? Data(contentsOf: entryURL) else { return false }
        return (try? EntryMetadataStore.decode(data)) != nil
    }
```

- [ ] **Step 4: Guard the four child builders**

Insert the guard in each, immediately after the builder's own eligibility check and before any bytes are read:

`audioRecordToPush` — after the `durationFrames` guard (line 972), before `let directory`:

```swift
        guard await entryCanBePushed(capturesRoot: capturesRoot, captureID: captureID) else {
            log.notice("sync: audio \(captureID, privacy: .public) held back — its Entry cannot be pushed yet")
            return nil
        }
```

`liveLogRecordToPush` — after the `isFinalized` guard (line 1008):

```swift
        guard await entryCanBePushed(capturesRoot: capturesRoot, captureID: captureID) else {
            log.notice("sync: live log \(captureID, privacy: .public) held back — its Entry cannot be pushed yet")
            return nil
        }
```

`markerStreamRecordToPush` — after the `isFinalized` guard (line 1065):

```swift
        guard await entryCanBePushed(capturesRoot: capturesRoot, captureID: captureID) else {
            log.notice("sync: marker stream \(captureID, privacy: .public) held back — its Entry cannot be pushed yet")
            return nil
        }
```

`revisionRecordToPush` — after the `located` guard (line 821), using `located.captureID`:

```swift
        guard await entryCanBePushed(capturesRoot: capturesRoot, captureID: located.captureID) else {
            log.notice("sync: revision \(id, privacy: .public) held back — its Entry cannot be pushed yet")
            return nil
        }
```

- [ ] **Step 5: Run the new tests plus every builder suite**

`-only-testing:RaconteTests/SyncChildHoldbackTests -only-testing:RaconteTests/SyncEntryRecordTests -only-testing:RaconteTests/SyncRevisionTests -only-testing:RaconteTests/SyncMarkerStreamTests -only-testing:RaconteTests/SyncEntryIngestTests`. Expected: all pass. If a revision or marker-stream fixture now fails because its capture has no verified manifest, that fixture was pushing a child for an unfinalized capture — it was already refused by the `isFinalized`/`loadFinalizedManifest` gates, so the failure would be a real regression to investigate, not a fixture to loosen.

- [ ] **Step 6: Mutation check (report it, do not keep it)**

Make `entryCanBePushed` return `true` unconditionally — `testChildrenHoldBackWhenTheEntryCannotBeBuilt…` must fail. Make it skip the `systemFields` check — `testChildrenStillPushWhenTheEntryAlreadyLanded…` must fail. Revert; record in the report.

- [ ] **Step 7: Commit**

```bash
git add Raconte/Sync/SyncIngest.swift RaconteTests/SyncChildHoldbackTests.swift
git commit -m "fix(sync): child records hold back until their Entry is on the server or builds with them"
```

---

### Task 4: Bump `CFBundleVersion` for iOS TestFlight build 2 and run the whole unit suite

**Files:**
- Modify: `Raconte/Info.plist:21-22`

- [ ] **Step 1: Bump the build number**

Change the `<string>` directly under `<key>CFBundleVersion</key>` from `1` to `2`. Leave `CFBundleShortVersionString` at `1.0`.

- [ ] **Step 2: Run the full unit suite (foreground, 600000 ms timeout)**

Global Constraints test command WITHOUT any `-only-testing:` flag. Expected: every `RaconteTests` test passes; note the total count in the report. (`RaconteUITests` is not part of this scheme's `test` action for macOS and must not be run here.)

- [ ] **Step 3: Commit**

```bash
git add Raconte/Info.plist
git commit -m "chore: CFBundleVersion 2 for iOS TestFlight build 2 (NOT_FOUND self-heal)"
```
