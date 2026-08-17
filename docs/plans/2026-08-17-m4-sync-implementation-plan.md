# M4 Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every device holds the full archive (audio included); delete-and-reinstall reconstructs it from iCloud.

**Architecture:** CKSyncEngine → CloudKit private DB, one custom zone, record-per-artifact mapping onto the existing file store. Pure testable cores (record builders, merge rules, reconciliation planner) with a thin actor shell; CloudKit itself is device-verified, never CI-verified.

**Tech Stack:** Swift 6 strict concurrency, CloudKit/CKSyncEngine (iOS 26 / macOS 26), existing AtomicFile/store primitives.

**Spec:** `docs/plans/2026-08-17-m4-sync-design.md` — read it first; every task argues from it. The persistence inventory it summarizes was verified against code 2026-08-16.

## Global Constraints

- Branch `m4/sync` in its own worktree (subagent worktrees branch from main — that is the correct base here).
- **After creating any new file: `xcodegen generate`**, or `-only-testing` reports "Executed 0 tests" and exits 0 — a silent pass.
- Never pipe `xcodebuild` through `head`. iOS compile checks need `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`.
- TDD with RED evidence: every new behavior's test must be shown failing for the right reason before the implementation lands (compile-error red is NOT acceptable evidence). Every task names at least one mutation check; the implementer runs it and reports the failing output verbatim.
- Vacuous-fixture rule: every fixture must exercise the non-degenerate path; cardinality ≥ 2 where a rule quantifies. Source-scanning tests must strip `//` comments.
- Commit messages/PR bodies: never place a close-verb before an issue number unless auto-close is intended.
- No CloudKit calls in unit tests. `CKRecord`/`CKRecord.ID` may be *constructed* in tests (no account needed); anything that talks to a server lives behind the `CloudEngineControl` seam and is exercised only in device smokes.
- Capture-directory hazard: production sync code must never create files under `captures/<id>/` except through the ingest paths Tasks 7–10 define. Any stray file under `transcript/` flips `holdsIrreplaceableArtifacts`.
- All new persistent writes go through `AtomicFile.replace` / `createExclusively` or `O_APPEND`, matching the store's conventions.

## Locked decisions (apply to every task)

- Zone `RaconteZone`, container `iCloud.org.pianohouseproject.raconte`, private DB.
- Record names are prefixed and parseable (amends the design doc's bare-ULID column; semantics unchanged):
  - Journal `j.<journalULID>` · Entry `e.<captureID>` · AudioAsset `a.<captureID>.0`
  - Revision `r.<revisionULID>` · LiveLog `l.<captureID>` · MarkerStream `m.<captureID>.<deviceID>`
- Children (AudioAsset, Revision, LiveLog, MarkerStream) carry a field `entryRef = CKRecord.Reference(recordID: entry, action: .deleteSelf)` so an Entry delete cascades server-side. (`CKRecord.parent` does NOT cascade; the reference action does.)
- A capture is **sync-eligible** only when its manifest reads cleanly and reports a verified final m4a (`final.verifiedAt` present) and the directory sits under `captures/` (never `trash-pending/`). Trashed-but-not-purged entries ARE eligible (trash is a synced field).
- LWW tie-break everywhere: equal stamps → lexicographically greater deviceID wins.
- The `sync/` directory is disposable cache: unreadable engine state or ledger → start fresh and re-reconcile; never an error surfaced to the user.
- Marker total order (Task 10): sort key `(at ?? .distantPast, deviceID, seq)`; merged log renumbers `seq` by position and remaps same-stream `retractsSeq`; cross-stream retracts are dropped.

## File structure (created across tasks)

```
Raconte/Sync/
  SyncRecordName.swift          pure: names + parsing              (T3)
  SyncBookkeeping.swift         actor: sync/ dir stores            (T2)
  SyncTreeScanner.swift         IO: tree → [SyncArtifactState]     (T3)
  SyncPlanner.swift             pure: reconcile scan vs ledger     (T3)
  SyncRecordBuilders.swift      pure: artifact → CKRecord          (T5,T6,T9,T10)
  SyncIngest.swift              pure merges + ingest orchestration (T5,T7,T8,T9,T10,T11)
  MarkerStreamMerge.swift       pure: streams → one virtual log    (T10)
  CloudEngineControl.swift      seam protocol + CKSyncEngine impl  (T4)
  SyncCoordinator.swift         actor: engine delegate, hooks      (T4+)
RaconteTests/Sync*/…            mirrors the above
```

---

### Task 1: Additive format stamps (`modified` maps, marker `at`)

**Files:**
- Modify: `Raconte/Library/EntryMetadata.swift` (add `modified: [String: Date]?`, encode-when-non-nil, lenient decode)
- Modify: `Raconte/Library/EntryMetadataStore.swift` (`update` stamps changed fields at write time, injectable clock — follow the store's existing clock pattern)
- Modify: `Raconte/Library/Journal.swift` + `JournalStore.swift` (same additive `modified` map per journal; stamped in `create`/`rename`/`setVoiceLabels`)
- Modify: `Raconte/Capture/StructureMarker.swift` (optional `at: Date`, lenient decode), `MarkerLog.swift` + `MarkerCorrectionWriter.swift` (stamp `at` on every new append)
- Test: extend `RaconteTests` neighbors of each file (follow existing test-file naming)

**Interfaces:**
- Produces: `EntryMetadata.modified: [String: Date]?` where keys are exactly the sidecar field names `journalID`, `originalDate`, `trashedAt`, `multiVoice`, `detectedDate`, `detectionRan`; `Journal.modified: [String: Date]?` with keys `name`, `voiceLabels`, `cover`; `StructureMarker.at: Date?`.
- Consumes: existing `AtomicFile`, existing store clocks.

Requirements, all TDD red-first:
- [ ] An untouched `EntryMetadata` still encodes as exactly `{}` (byte-pin, this property is load-bearing for carry-over and for journals.json byte-identity — assert against the literal bytes).
- [ ] `update` that changes `originalDate` stamps ONLY `originalDate` in `modified` (cardinality: a second update changing `journalID` leaves the `originalDate` stamp untouched — this is the per-field LWW substrate).
- [ ] Old sidecar/marker fixtures (without the new keys) decode unchanged; new records decode in an OLD-shaped decoder (simulate by decoding into a struct without the field — document as the forward-compat pin).
- [ ] Marker appends (capture tap AND correction) carry `at` from the injected clock; frozen-clock trap: advance the clock between appends in tests (memory: frozen-clock-two-mints-coin-flip-order).
- [ ] Mutation check: remove the stamping line in `EntryMetadataStore.update` → the only-stamps-changed-field test must fail; report output.
- [ ] Commit: `feat: additive sync stamps — entry/journal modified maps, marker at (M4 T1)`

### Task 2: Sync bookkeeping store (`sync/` directory)

**Files:**
- Create: `Raconte/Sync/SyncBookkeeping.swift`
- Modify: `Raconte/Library/AppContainer.swift` (add `syncRoot` beside `journalsURL`; keep the "sibling of captures/, never inside it" doc-comment pattern)
- Test: `RaconteTests/SyncBookkeepingTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct UploadedDigest: Codable, Equatable, Sendable { var sha256: String; var bytes: Int }
  actor SyncBookkeepingStore {
    init(root: URL)                                        // AppContainer.syncRoot
    func engineState() -> Data?                            // unreadable == absent (disposable)
    func saveEngineState(_ data: Data) throws
    func systemFields(for recordName: String) -> Data?
    func saveSystemFields(_ data: Data, for recordName: String) throws
    func deleteSystemFields(for recordName: String) throws
    func ledger() -> [String: UploadedDigest]              // recordName → digest
    func recordUpload(_ digest: UploadedDigest, for recordName: String) throws
    func clearUpload(for recordName: String) throws
    func wipe() throws                                     // delete sync/ wholesale
  }
  ```
- Layout: `sync/engine-state.bin`, `sync/system-fields/<recordName>.bin`, `sync/ledger.json` (one atomic file; recordNames are filesystem-safe by construction — pin with a test over every `SyncRecordName` shape once T3 lands; here pin the dot-containing example `a.<ulid>.0`).
- [ ] Reads are three-outcome-collapsed deliberately: absent and unreadable both → nil/empty, because the whole directory is a disposable cache — write the doc comment AND a test feeding garbage bytes.
- [ ] Everything through `AtomicFile.replace`; `wipe()` then `ledger()` returns empty.
- [ ] Mutation check: make `ledger()` return `[:]` unconditionally → round-trip test fails.
- [ ] Commit: `feat: sync bookkeeping store under sync/ (M4 T2)`

### Task 3: Record names, tree scan, reconciliation planner (pure core)

**Files:**
- Create: `Raconte/Sync/SyncRecordName.swift`, `Raconte/Sync/SyncTreeScanner.swift`, `Raconte/Sync/SyncPlanner.swift`
- Test: `RaconteTests/SyncRecordNameTests.swift`, `SyncTreeScannerTests.swift`, `SyncPlannerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum SyncRecordName {   // build + parse, both total
    case journal(id: String), entry(captureID: String), audio(captureID: String)
    case revision(id: String), liveLog(captureID: String)
    case markerStream(captureID: String, deviceID: String)
    var rawValue: String                       // the prefixed forms in Locked decisions
    init?(rawValue: String)
  }
  struct SyncArtifactState: Equatable, Sendable {
    var name: SyncRecordName
    var sha256: String        // digest of the artifact's source bytes (see below)
    var bytes: Int
  }
  struct SyncTreeScanner {    // IO, init with AppContainer roots + DeviceIdentity.stable
    func scan() -> [SyncArtifactState]   // sync-eligible captures only + journals
  }
  enum SyncPlanner {          // pure
    static func reconcile(scan: [SyncArtifactState],
                          ledger: [String: UploadedDigest]) -> [SyncRecordName] // to enqueue
  }
  ```
- Digest definitions (locked): Journal = sha256 of that journal's canonical single-journal JSON encoding (sorted-keys lineEncoder) **including cover.jpg bytes' sha256 as a suffixed line** so a cover change re-enqueues; Entry = sha256 of `entry.json` bytes + `manifest.json` bytes concatenated; AudioAsset/LiveLog/Revision = sha256 of the file bytes; MarkerStream = sha256 of own `markers.jsonl` bytes (own-device stream only — foreign `markers-*.jsonl` files are NEVER scanned for upload).
- [ ] Round-trip test over every case incl. the ambiguous-looking `a.<ulid>.0` and `m.<ulid>.<ulid>`; `init?` rejects garbage and bare ULIDs.
- [ ] Scanner: fixture tree with (a) a finalized capture (eligible), (b) an in-flight capture with no `final.verifiedAt` (excluded), (c) a trashed-but-present capture (INCLUDED), (d) a capture inside `trash-pending/` (excluded), (e) unreadable manifest (excluded, and reported via a `skipped: [String]` diagnostic array on the scan result — extend the return type to a small struct if cleaner). Cardinality ≥2 eligible captures so ordering bugs surface.
- [ ] Planner: enqueues exactly (new artifacts) ∪ (digest-changed artifacts); ledger entries with no surviving artifact produce NOTHING here (deletes are Task 11's explicit path, not inferred from absence — a scan raced against an in-flight stage must never delete; write this as a named test).
- [ ] Mutation check: planner compares only `bytes`, not `sha256` → same-size-different-content test fails.
- [ ] Commit: `feat: sync record names, eligibility scan, reconciliation planner (M4 T3)`

### Task 4: Entitlements + engine seam + SyncCoordinator skeleton

**Files:**
- Modify: `project.yml` (entitlements: `com.apple.developer.icloud-container-identifiers` = [`iCloud.org.pianohouseproject.raconte`], `com.apple.developer.icloud-services` = [CloudKit], `aps-environment` = development, iOS `UIBackgroundModes` += `remote-notification`), then `xcodegen generate`; verify `Raconte.entitlements` output.
- Create: `Raconte/Sync/CloudEngineControl.swift`, `Raconte/Sync/SyncCoordinator.swift`
- Modify: composition root (where stores are built — find via `SecondarySinkFactory` wiring) to construct `SyncCoordinator` when an iCloud account may exist; UI-test harness gets a no-op, same pattern as `SecondarySinkFactory`.
- Test: `RaconteTests/SyncCoordinatorTests.swift` with a `FakeCloudEngine`.

**Interfaces:**
- Produces:
  ```swift
  protocol CloudEngineControl: Sendable {     // the ONLY thing that touches CKSyncEngine
    func start(stateData: Data?) async
    func enqueueSaves(_ names: [SyncRecordName]) async
    func enqueueDeletes(_ names: [SyncRecordName]) async
    func fetchNow() async                      // launch/foreground/push kick
  }
  actor SyncCoordinator {                      // CKSyncEngineDelegate lives in the prod impl
    init(bookkeeping: SyncBookkeepingStore, scanner: SyncTreeScanner,
         engine: CloudEngineControl /* + stores added by later tasks */)
    func launch() async        // load state, start engine, run reconciliation scan, enqueue
    func noteLocalChange(_ name: SyncRecordName) async   // the hook entry point
  }
  ```
- The production `CloudEngineControl` impl wraps `CKSyncEngine` with the real delegate; record population/ingest callbacks are stubbed `fatalError`-free no-ops until Tasks 5+ fill them (log + skip). It is compiled everywhere but constructed only outside UI-test/CI harnesses.
- [ ] Coordinator tests (fake engine): `launch()` with empty ledger enqueues everything the scanner reports; `noteLocalChange` enqueues exactly that name; engine state round-trips through bookkeeping on the fake's state-update callback.
- [ ] Both platforms compile with the new entitlements (`CODE_SIGNING_ALLOWED=NO` for the iOS check). CI must stay green — CloudKit is never constructed under `RACONTE_UITEST_ID` or in unit tests.
- [ ] Mutation check: drop the reconciliation call inside `launch()` → first-enable test fails.
- [ ] Commit: `feat: iCloud entitlements + CKSyncEngine seam + SyncCoordinator skeleton (M4 T4)`

### Task 5: Journal sync end-to-end (record builder, ingest merge, hooks)

**Files:**
- Create: `Raconte/Sync/SyncRecordBuilders.swift`, `Raconte/Sync/SyncIngest.swift`
- Modify: `Raconte/Library/JournalStore.swift` + `JournalCoverStore.swift` (post-save hook: `await syncHooks?.noteLocalChange(.journal(id:))` — inject an optional `SyncHooks` protocol so tests/UI-harness pass nil; define `SyncHooks` in this task, single method `noteLocalChange(_:)`)
- Modify: `SyncCoordinator.swift` + prod engine impl: fill `nextRecordZoneChangeBatch`-style record population for journals, and fetched-change handling → ingest.
- Test: `RaconteTests/SyncJournalRecordTests.swift`, `SyncJournalIngestTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum SyncRecordBuilders {
    static func journalRecord(journal: Journal, coverFileURL: URL?,
                              zoneID: CKRecordZone.ID) -> CKRecord   // fields per design §2
  }
  struct RemoteJournal: Equatable, Sendable {  // decoded from a fetched CKRecord
    var id: String; var name: String; var createdAt: Date
    var voiceLabels: [String: String]; var modified: [String: Date]
    var coverAsset: URL?                       // CKAsset fileURL if present
    init?(record: CKRecord)
  }
  enum JournalMerge {                          // pure, per-field LWW + deviceID tiebreak
    static func merge(local: Journal, remote: RemoteJournal,
                      localDeviceID: String, remoteDeviceID: String?) -> Journal
    // remote with no local counterpart → insert as-is
  }
  ```
- Ingest applies through `JournalStore` (new method `applySyncMerge(_:)` that saves without re-stamping `modified` and without re-triggering the sync hook — document why: a sync-caused save must not echo back as a local change; pin with a test that the hook records nothing during ingest).
- [ ] Builder tests: CKRecord fields match the design table exactly (name each field); `voiceLabels` travels as sorted-keys JSON string; absent cover → no asset field.
- [ ] Merge tests (cardinality ≥2 fields): remote-newer `name` + local-newer `voiceLabels` → both survive from their winners; equal stamps → greater deviceID wins (test BOTH directions); unknown remote journal → inserted; local-only journal → untouched.
- [ ] Push-conflict path: coordinator merges server record fields by the same rule and resaves (fake-engine test with a scripted conflict).
- [ ] Mutation check: make `JournalMerge` whole-record LWW (ignore per-field stamps) → the both-survive test fails.
- [ ] **Owner smoke gate (end of task): phone + mini, dev environment — rename a journal on the phone, see it on the mini; set a cover on the mini, see it on the phone. Exact steps written into the task report.**
- [ ] Commit: `feat: journal sync end-to-end (M4 T5)`

### Task 6: Entry push + finalize artifacts (AudioAsset, LiveLog, manifestSnapshot)

**Files:**
- Modify: `Raconte/Sync/SyncRecordBuilders.swift` (+entry, audio, liveLog builders)
- Modify: `Raconte/Library/EntryMetadataStore.swift` (post-update hook via `SyncHooks`)
- Modify: finalize completion path (`FinalizerWorker` completion / `CaptureScreenModel.recordTranscriptRef` — wherever "m4a verified AND transcript ref recorded" is first true; read the code, pick the single choke point, document why) → `noteLocalChange` for `.entry`, `.audio`, `.liveLog`.
- Test: `RaconteTests/SyncEntryRecordTests.swift`

**Interfaces:**
- Produces:
  ```swift
  static func entryRecord(captureID: String, metadata: EntryMetadata,
                          manifestJSON: Data, capturedAt: Date,
                          zoneID: CKRecordZone.ID) -> CKRecord
  static func audioRecord(captureID: String, m4aURL: URL, sha256: String,
                          bytes: Int, frameCount: Int64, sampleRate: Double,
                          entryID: CKRecord.ID, zoneID: CKRecordZone.ID) -> CKRecord
  static func liveLogRecord(captureID: String, fileURL: URL, sha256: String,
                            entryID: CKRecord.ID, zoneID: CKRecord.ID? = nil,
                            zone: CKRecordZone.ID) -> CKRecord  // fix signature consistency in-code
  ```
- [ ] Entry builder: every synced sidecar field + `modified` stamps travel; `manifestSnapshot` is the verbatim manifest bytes as String; untouched-entry (`{}`) still builds a valid record.
- [ ] Audio/LiveLog builders: `entryRef` uses `.deleteSelf` (assert the reference action — this is the cascade); asset file URLs point at the real files.
- [ ] Eligibility pin: an in-flight capture NEVER reaches `noteLocalChange` (test at the choke point with a fake hook recorder).
- [ ] A capture with no transcript at all (degraded: transcription never ran) still pushes Entry + AudioAsset and skips LiveLog — three-answer honesty, named test.
- [ ] Mutation check: builder drops `trashedAt` → field-coverage test fails.
- [ ] Commit: `feat: entry + finalize artifact push (M4 T6)`

### Task 7: New-entry ingest — assemble-then-commit

**Files:**
- Modify: `Raconte/Sync/SyncIngest.swift`
- Modify: `Raconte/Library/AppContainer.swift` (`syncStagingRoot` under `sync/staging/`)
- Test: `RaconteTests/SyncEntryIngestTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum EntryIngest {
    // Pure decision half:
    struct Incoming { var captureID: String; var manifestJSON: Data
                      var metadata: RemoteEntryFields
                      var audio: (url: URL, sha256: String)?
                      var liveLog: (url: URL, sha256: String)? }
    static func plan(incoming: Incoming, captureExists: Bool) -> IngestAction
    enum IngestAction: Equatable { case assembleNew, applyToExisting, refuse(String) }
  }
  struct RemoteEntryFields: Equatable, Sendable { /* mirror of Entry record fields */
    init?(record: CKRecord) }
  ```
  IO half (on the ingest orchestrator): assemble `sync/staging/<captureID>/` — write `manifest.json` (snapshot verbatim), `entry.json` (from RemoteEntryFields via the normal encoder), `final/recording.m4a` (copied from the CKAsset temp URL after sha256 verify), `transcript/live.jsonl` if present — then `rename(2)` into `captures/<captureID>/`, then poke the library rescan.
- [ ] Commit set pin: assembly refuses (leaves staging, retries later) unless manifest + entry + m4a are ALL present; transcript artifacts are optional riders. Named test per missing piece.
- [ ] sha256 mismatch on any asset → refuse + staging discarded, never a rename (data-integrity pin, both audio and liveLog cases).
- [ ] `captureExists == true` → `.applyToExisting` (Task 8's path); the rename path is never taken (test).
- [ ] Interrupted-assembly recovery: a stale `sync/staging/<id>/` from a crash is discarded and rebuilt (staging is cache; pin that a garbage staging dir cannot reach `captures/`).
- [ ] The staged rename lands a directory whose recovery-scan classification is *settled* — feed the assembled fixture through `DirectorySnapshot`/`RecoveryPlanner` and assert no destructive plan step is produced (THE critical safety test; mutation: corrupt the staged manifest state to `recording` and watch the test catch the difference).
- [ ] Commit: `feat: assemble-then-commit ingest for new entries (M4 T7)`

### Task 8: Entry field merge (both directions) + `.sync` audit cause

**Files:**
- Modify: `Raconte/Sync/SyncIngest.swift` (`EntryFieldMerge`), `Raconte/Library/EntryMetadataStore.swift` (an `applySyncMerge` twin of Task 5's journal one: writes through `update` machinery with `EntryLogCause.sync`, no re-stamp, no hook echo)
- Test: `RaconteTests/SyncEntryMergeTests.swift`

**Interfaces:**
- Produces: `enum EntryFieldMerge { static func merge(local: EntryMetadata, remote: RemoteEntryFields, localDeviceID: String, remoteDeviceID: String?) -> EntryMetadata }` — same LWW semantics as `JournalMerge`, shared tie-break helper extracted (DRY: one `LWWResolve` helper both call; do NOT copy the logic).
- [ ] Field-level survival test (the owner's ruling verbatim): remote sets `originalDate` newer, local sets `journalID` newer → merged carries both winners.
- [ ] `trashedAt` LWW both directions (trash remote/restore local newer, and inverse).
- [ ] `detectionRan` latch: once true anywhere, never merges back to false regardless of stamps (write-once pin).
- [ ] Ingest writes flow through the store: entry-log gains a `.sync`-cause row; hook does not echo (recorder test).
- [ ] Push-conflict path mirrors Task 5's, via the shared merge.
- [ ] Mutation check: tie-break flipped to lesser-deviceID-wins → the two-direction tie tests fail asymmetrically.
- [ ] Commit: `feat: entry per-field LWW merge, sync audit cause (M4 T8)`

### Task 9: Revision sync (push + next-free-n ingest + head rebuild)

**Files:**
- Modify: `Raconte/Sync/SyncRecordBuilders.swift` (+revision builder), `SyncIngest.swift`
- Modify: `Raconte/Transcription/TranscriptRevisionStore.swift` (hook on `append`; new `ingestForeignRevision(captureID:revisionID:body:) async throws` that (a) no-ops if any local canonical file already contains this revision id, (b) writes bytes verbatim at next free `n` via the existing `createExclusively` path incl. `.allocationCollision` retry, (c) refreshes `head.json` through the existing `persistHead` machinery, (d) does NOT fire the sync hook)
- Test: `RaconteTests/SyncRevisionTests.swift`

**Interfaces:**
- Consumes: `TranscriptRevisionStore`'s real decode/id plumbing — read it; never re-implement chain rules (standing branch rule: call the store's shared primitives).
- [ ] Ingest idempotence: same revision delivered twice lands one file (pin by directory listing count, not just absence of error).
- [ ] File-number independence: local chain has `canonical-0..2`; foreign revision lands as `canonical-3` with bytes verbatim (byte-pin) and the chain resolves `current` per newest-human rule — build a two-device fork fixture (two children of one parent, different `createdAt`) and assert every device-order permutation converges to the same `current` (THE chain-is-the-conflict-resolution test; cardinality: both orders).
- [ ] A foreign revision for an unknown capture parks (retained for retry after the Entry lands) rather than erroring — ordering between fetched record types is not guaranteed.
- [ ] Push: `append` hook fires once per minted revision; body asset is the exact file bytes.
- [ ] Mutation check: ingest writes at `n` instead of next-free (overwrite semantics) → `createExclusively` pin fails loudly.
- [ ] Commit: `feat: revision sync — create-once push, next-free-n ingest (M4 T9)`

### Task 10: Marker streams (push own, ingest foreign, read-side merge)

**Files:**
- Create: `Raconte/Sync/MarkerStreamMerge.swift`
- Modify: `Raconte/Sync/SyncRecordBuilders.swift` (+markerStream builder: content = own `markers.jsonl` bytes as String), `SyncIngest.swift` (materialize foreign stream to `transcript/markers-<deviceID>.jsonl` via `AtomicFile.replace` — whole-file replace is safe: single remote writer, monotonic growth)
- Modify: the marker read path — find the single place `markers.jsonl` is read for attribution (inventory: `MarkerLog` reader feeding `TranscriptAttribution`); insert the merge so downstream sees ONE virtual log.
- Test: `RaconteTests/MarkerStreamMergeTests.swift` + an integration test through `TranscriptAttribution`.

**Interfaces:**
- Produces:
  ```swift
  enum MarkerStreamMerge {
    struct Stream: Equatable, Sendable { var deviceID: String; var markers: [StructureMarker] }
    static func merge(_ streams: [Stream]) -> [StructureMarker]
    // total order (at ?? .distantPast, deviceID, seq); output seq renumbered by
    // position; same-stream retractsSeq remapped; cross-stream retracts dropped
  }
  ```
- [ ] Single-stream identity: one stream in → byte-equal marker semantics out (seqs may renumber to the same values; assert full equality) — pre-M4 entries behave exactly as today.
- [ ] Two-stream correction precedence: capture stream has a voice correction at frame F stamped 10:00; foreign stream corrects the same boundary stamped 10:05 → foreign wins after merge (assert through `TranscriptAttribution`, not just ordering — the integration is the point).
- [ ] Equal `at` → greater deviceID wins (both directions).
- [ ] `retractsSeq` remap: a stream retracting its own seq-3 still retracts the right marker after renumbering; a foreign `retractsSeq` naming a local seq is dropped (named test).
- [ ] Unstamped legacy records sort before stamped ones within the total order (fixture mixing both).
- [ ] Foreign-stream file location deliberately trips `holdsIrreplaceableArtifacts` (assert via `DirectorySnapshot`) — it is precious attribution, per design §7.4.
- [ ] Mutation check: merge sorts by `(deviceID, at)` instead of `(at, deviceID)` → precedence test fails.
- [ ] Commit: `feat: marker streams — per-device sync + read-side merge (M4 T10)`

### Task 11: Trash, purge, delete ingest

**Files:**
- Modify: `Raconte/Library/TrashSweeper.swift` + the Delete Now path (find via `deleteEntryPermanently`) → after successful local stage+purge, `engine.enqueueDeletes([.entry(captureID)])` (children cascade server-side; enqueue only the Entry).
- Modify: `Raconte/Sync/SyncCoordinator.swift` (fetched `deletedRecordZoneChanges` for an Entry → route through `StagedRemover.stage` + purge; drop any pending uploads for that capture from the engine's queue and the ledger).
- Test: `RaconteTests/SyncDeleteTests.swift`

- [ ] Sync-in delete uses `StagedRemover` — a source-scan test (comment-stripping helper) asserts the sync sources contain no `removeItem(` and no `RecoveryExecutor` reference; plus a behavioral test: after delete ingest, the capture dir is gone from `captures/` and present-then-purged via the staging root.
- [ ] Delete for an unknown/already-deleted capture is a silent no-op (both layers).
- [ ] Delete-vs-pending-work: a queued revision upload for the deleted capture is dropped, not sent (fake-engine test) — design §5 rule "the delete wins".
- [ ] Local purge on device A + independent sweep on device B: second CK delete is a no-op (fake-engine scripted).
- [ ] Ledger + system-fields entries for the entry's records are cleared on both paths.
- [ ] Mutation check: route sync-in delete through `FileManager.removeItem` → source-scan test fails.
- [ ] Commit: `feat: purge → CloudKit delete; delete ingest via staged removal (M4 T11)`

### Task 12: Debug sync status + docs

**Files:**
- Modify: the Debug screen (find via the build-stamp UI) — status lines: account state, last push at, last fetch at, pending saves/deletes count, last error string. Read from a `SyncCoordinator.status() -> SyncStatus` snapshot (`struct SyncStatus: Equatable, Sendable` with exactly those fields).
- Modify: `docs/overview.md` (M4 section — plain-words model: "each device tells iCloud what it wrote; immutable things upload once; the chain means edits never conflict"), design doc gains an as-built §10 if rulings drifted.
- Test: status snapshot unit test (fake engine drives states; assert transitions).
- [ ] Debug-only visibility is fine for M4 (design §8: user-facing surfacing is later polish).
- [ ] Commit: `feat: sync status on debug screen; M4 docs (M4 T12)`

---

### Gate A (after Task 5) — adversarial review, journals slice

Independent reviewer, probe tests required (memory: gate reviews demand probe tests): re-run the full suite on the committed tree; probe the no-echo rule (ingest must not re-enqueue), the disposable-cache claim (garbage `sync/` contents on launch), and hook coverage (every `JournalStore` mutation path reaches `noteLocalChange` — including `setVoiceLabels`). Owner smoke is part of this gate (Task 5's phone↔mini steps).

### Gate B (after Task 12) — whole-branch adversarial + acceptance

- Full suite re-run by the reviewer on the committed tree; iOS + macOS builds.
- Probes: (1) kill the app between a store write and its `noteLocalChange` — reconciliation scan must recover the upload; (2) ingest a fetched Entry whose capture is mid-finalize locally (both devices recorded offline with... not possible — same captureID can't originate twice; instead: fetched Entry UPDATE racing local `EntryMetadataStore.update` — per-field merge must hold under the actor); (3) the Task 7 recovery-scan safety fixture re-run against the final code; (4) source-scan: no sync code writes into `captures/` outside the ingest paths.
- **Acceptance smoke (owner): delete the app from the mini, reinstall, full archive reconstructs — entries, audio playable, voice rendering, backdates, trash state, journal covers. Then the standing #62-style check: trash an entry on the phone, watch it leave the mini.**
- PR for Nico to merge (auto-mode can't `gh pr merge`); CloudKit schema promoted to production only after this gate, before any TestFlight build.

## Self-review notes (done at write time)

- Spec coverage: design §1→T3 (eligibility) + T6; §2→T3/T5/T6/T9/T10; §3→T2/T3/T4 + hooks in T1/T5/T6/T9/T11; §4→T5/T8/T9/T10; §5→T11; §6→T7/T8/T9/T10; §7→T1/T10; §8→T4 + gates; §9 respected (nothing extra built).
- Known intentional deviation from the skill template: steps are task-level TDD requirements rather than 2-minute micro-steps — this repo's six shipped SDD loops all ran from this shape, and per-task implementers extract their own red/green cycles from the named tests.
- Type-consistency pass: `SyncHooks` defined T5, consumed T6/T9; `LWWResolve` shared T5/T8; `RemoteEntryFields` defined T7, consumed T8; fixed `liveLogRecord` signature note in place (implementer normalizes to match siblings).
