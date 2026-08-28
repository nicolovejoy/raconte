# Write-Once serverRecordChanged Short-Circuit (build 10) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Break the permanent `serverRecordChanged` resend loop for write-once child
records (AudioAsset / LiveLog / Revision / Image) by settling a conflict whose server
copy is byte-identical (sha256 match) instead of re-pushing forever.

**Architecture:** A pure decision table (`WriteOnceConflictGate`, modeled on
`EnvironmentGate` / `SaveFailureDisposition`) decides settle-vs-divergent from two
sha256s. `SyncRecordExchange.resolvePushConflicts` gains a write-once branch that
computes the local digest from the same files the `*RecordToPush` builders read, and
now returns a `PushConflictResolution` (resend + settled) instead of a bare resend
list. `CloudEngineControl.handleFailedSaves` removes settled names from the engine's
pending saves (`state.remove` — without it the name retries forever across launches).

**Tech Stack:** Swift 6 strict concurrency, XCTest, CKSyncEngine (no server in tests —
real `CKRecord`s + real temp filesystem, the established `SyncRevisionTests` pattern).

**Spec:** `docs/2026-08-26-sync-investigation-state.md`, section
"RESOLVED 2026-08-27" (root cause + agreed fix direction).

## Global Constraints

- Test command (macOS, sandbox REQUIRED — never `CODE_SIGNING_ALLOWED=NO`):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test
```

  Scope a single suite by appending `-only-testing:RaconteTests/<ClassName>`.
- After creating any new `.swift` file: `xcodegen generate` (the xcodeproj is generated;
  new files are picked up only on regen).
- Branch: `fix/sync-write-once-conflict` off `main`. End state: an open PR — merges are
  Nico's (`gh pr create --body-file`, never a heredoc body; no close-keywords for
  issues that must stay open).
- Log style: `log.notice` for expected dispositions, `log.error` for divergence;
  always `privacy: .public` for record names (matches every neighbor call).
- Doc comments in this codebase are load-bearing and verbose; match the surrounding
  density in `SyncIngest.swift` / `CloudEngineControl.swift`.

## Design rulings (settled here, do not relitigate mid-task)

1. **Match → settle:** archive the server copy's system fields, write the upload
   ledger with the LOCAL digest, and remove the pending save. No re-push, no asset
   download.
2. **Divergence (sha mismatch, server copy missing its sha256, or local artifact
   unreadable) → log loudly and remove the pending save WITHOUT writing the ledger.**
   No ledger entry means the next launch's `SyncPlanner.reconcile` re-enqueues the
   name — so a divergent record stays visible (one loud error per launch) instead of
   hot-looping on every send batch. A write-once record must never overwrite a
   differing server copy blind.
3. **Mutable types (Journal / Entry / MarkerStream) keep the existing behavior
   verbatim:** `acceptRemote` (LWW merge + archive tag) then resend.

---

### Task 1: `WriteOnceConflictGate` pure decision table

**Files:**
- Create: `Raconte/Sync/WriteOnceConflictGate.swift`
- Test: `RaconteTests/WriteOnceConflictGateTests.swift`

**Interfaces:**
- Consumes: `SyncRecordName` (`Raconte/Sync/SyncRecordName.swift`),
  `UploadedDigest` (`Raconte/Sync/SyncBookkeeping.swift`: `struct UploadedDigest:
  Codable, Equatable, Sendable { var sha256: String; var bytes: Int }`).
- Produces: `WriteOnceConflictGate.isWriteOnce(_:) -> Bool` and
  `WriteOnceConflictGate.decide(serverSHA256: String?, local: UploadedDigest?)
  -> Disposition` with `enum Disposition: Equatable { case
  settleAsUploaded(UploadedDigest); case divergent(reason: String) }`. Tasks 2–3
  rely on these exact names.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Raconte

/// Decision table for a `serverRecordChanged` rejection of a WRITE-ONCE record
/// (sync investigation RESOLVED section): the server copy's `sha256` field is
/// available without downloading its asset, so a byte-identical copy can be settled
/// as already-uploaded; anything else is a divergence write-once records must not
/// paper over.
final class WriteOnceConflictGateTests: XCTestCase {

    private let digest = UploadedDigest(sha256: "abc123", bytes: 42)

    func testMatchingSHASettlesWithTheLocalDigest() {
        XCTAssertEqual(WriteOnceConflictGate.decide(serverSHA256: "abc123", local: digest),
                       .settleAsUploaded(digest))
    }

    func testMismatchedSHAIsDivergent() {
        guard case .divergent = WriteOnceConflictGate.decide(serverSHA256: "def456",
                                                             local: digest) else {
            return XCTFail("a differing server sha must never settle")
        }
    }

    func testServerCopyWithoutSHAIsDivergent() {
        guard case .divergent = WriteOnceConflictGate.decide(serverSHA256: nil,
                                                             local: digest) else {
            return XCTFail("a server copy missing its sha256 field must never settle")
        }
    }

    func testEmptyServerSHAIsDivergent() {
        guard case .divergent = WriteOnceConflictGate.decide(serverSHA256: "",
                                                             local: digest) else {
            return XCTFail("an empty sha256 must never settle")
        }
    }

    func testUnreadableLocalArtifactIsDivergent() {
        guard case .divergent = WriteOnceConflictGate.decide(serverSHA256: "abc123",
                                                             local: nil) else {
            return XCTFail("no local digest must never settle — nothing to credit the ledger with")
        }
    }

    func testWriteOnceMembershipCoversAllSevenNameShapes() {
        XCTAssertTrue(WriteOnceConflictGate.isWriteOnce(.audio(captureID: "C")))
        XCTAssertTrue(WriteOnceConflictGate.isWriteOnce(.liveLog(captureID: "C")))
        XCTAssertTrue(WriteOnceConflictGate.isWriteOnce(.revision(id: "R")))
        XCTAssertTrue(WriteOnceConflictGate.isWriteOnce(.image(captureID: "C", imageID: "I")))
        XCTAssertFalse(WriteOnceConflictGate.isWriteOnce(.journal(id: "J")))
        XCTAssertFalse(WriteOnceConflictGate.isWriteOnce(.entry(captureID: "C")))
        XCTAssertFalse(WriteOnceConflictGate.isWriteOnce(.markerStream(captureID: "C", deviceID: "D")))
    }
}
```

- [ ] **Step 2: `xcodegen generate`, run, verify FAIL** — expected: compile error,
  `WriteOnceConflictGate` not defined.

Run: the Global Constraints test command + `-only-testing:RaconteTests/WriteOnceConflictGateTests`

- [ ] **Step 3: Minimal implementation**

```swift
/// Decision table for a `serverRecordChanged` rejection of a WRITE-ONCE record
/// (AudioAsset / LiveLog / Revision / Image — the four child builders that take no
/// `base:`). Root cause and agreed fix: docs/2026-08-26-sync-investigation-state.md,
/// RESOLVED section. Pure — same testable-table shape as `EnvironmentGate` and
/// `SaveFailureDisposition`.
///
/// The server copy handed back with a push rejection never has its asset downloaded
/// (`fileURL` nil), but its `sha256` FIELD is present, which is what makes this
/// decision possible without any network round trip.
enum WriteOnceConflictGate {

    enum Disposition: Equatable {
        /// The server already holds these exact bytes: credit the upload ledger with
        /// the LOCAL digest and retire the pending save — the upload is, in every
        /// observable sense, done.
        case settleAsUploaded(UploadedDigest)
        /// Anything else. A write-once record with a genuinely differing server copy
        /// is a state the design says cannot legitimately exist — surface it loudly,
        /// never overwrite blind.
        case divergent(reason: String)
    }

    /// The four record kinds whose builders mint fresh records with no `base:` —
    /// content is immutable after creation, so "the server moved" can only mean
    /// "the server already has it" or real trouble.
    static func isWriteOnce(_ name: SyncRecordName) -> Bool {
        switch name {
        case .audio, .liveLog, .revision, .image: return true
        case .journal, .entry, .markerStream: return false
        }
    }

    static func decide(serverSHA256: String?, local: UploadedDigest?) -> Disposition {
        guard let local else {
            return .divergent(reason: "local artifact unreadable — nothing to compare")
        }
        guard let serverSHA256, !serverSHA256.isEmpty else {
            return .divergent(reason: "server copy carries no sha256")
        }
        guard serverSHA256 == local.sha256 else {
            return .divergent(reason: "sha256 mismatch — server \(serverSHA256), local \(local.sha256)")
        }
        return .settleAsUploaded(local)
    }
}
```

- [ ] **Step 4: Run, verify PASS** (same command).

- [ ] **Step 5: Commit**

```bash
git add Raconte/Sync/WriteOnceConflictGate.swift RaconteTests/WriteOnceConflictGateTests.swift
git commit -m "feat(sync): WriteOnceConflictGate — pure settle-vs-divergent table for serverRecordChanged on write-once records"
```

---

### Task 2: `localWriteOnceDigest(for:)` on `SyncRecordExchange`

**Files:**
- Modify: `Raconte/Sync/SyncIngest.swift` (add one method to the
  `SyncRecordExchange` actor, near the `*RecordToPush` builders it mirrors)
- Test: `RaconteTests/SyncPushConflictTests.swift` (create — Task 3 extends it)

**Interfaces:**
- Consumes: `SegmentLayout.finalRecordingURL(captureDirectory:)`,
  `SegmentLayout.liveTranscriptURL(captureDirectory:)`,
  `SegmentLayout.captureDirectory(capturesRoot:captureID:)`,
  `TranscriptRevisionStore.locateRevision(capturesRoot:revisionID:)`,
  `SegmentLayout.canonicalTranscriptURL(captureDirectory:revision:)`,
  `SegmentLayout.imageSidecarURL(captureDirectory:imageID:)`,
  `ImageStore.decodeSidecar(_:)`,
  `SegmentLayout.imageOriginalURL(captureDirectory:imageID:ext:)`,
  `SyncTreeScanner.rawDigest(_:)` — all already used by the sibling
  `*RecordToPush` methods in the same file; copy their exact call shapes.
- Produces: `func localWriteOnceDigest(for name: SyncRecordName) async ->
  UploadedDigest?` (internal, on `SyncRecordExchange`). Task 3 calls it.

- [ ] **Step 1: Write the failing tests**

Model setup on `RaconteTests/SyncRevisionTests.swift` (temp `containerRoot` per test,
`exchange()` factory, `stamp(_:)`, verified-manifest fixture — copy those helpers in,
adjusted to this file's names; the fixture code below is complete).

```swift
import XCTest
import CloudKit
@testable import Raconte

/// Build-10 fix (docs/2026-08-26-sync-investigation-state.md RESOLVED section): the
/// `serverRecordChanged` short-circuit for write-once records. Two layers, same split
/// the sibling sync test files use: `localWriteOnceDigest` (this task — the local
/// half of the comparison), then `resolvePushConflicts` end to end (Task 3).
final class SyncPushConflictTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZoneTest", ownerName: CKCurrentUserDefaultName)
    private let captureID = ULID.make()
    private var containerRoot: URL!

    override func setUpWithError() throws {
        containerRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("RacontePushConflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
    }

    private func stamp(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
    }

    private var capturesRoot: URL { AppContainer.capturesRoot(containerRoot: containerRoot) }

    private var captureDirectory: URL {
        SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
    }

    private func makeBookkeeping() -> SyncBookkeepingStore {
        SyncBookkeepingStore(root: AppContainer.syncRoot(containerRoot: containerRoot))
    }

    private func exchange(transcriptRevisionStore: TranscriptRevisionStore? = nil,
                          bookkeeping: SyncBookkeepingStore? = nil) -> SyncRecordExchange {
        let journalStore = JournalStore(containerRoot: containerRoot)
        let covers = JournalCoverStore(containerRoot: containerRoot, journalStore: journalStore)
        return SyncRecordExchange(
            journalStore: journalStore, coverStore: covers,
            bookkeeping: bookkeeping ?? makeBookkeeping(),
            deviceID: "device-test", containerRoot: containerRoot,
            entryMetadataStore: nil,
            transcriptRevisionStore: transcriptRevisionStore,
            localStoreDidChange: nil)
    }

    /// Verified-manifest + on-disk final m4a fixture — the file state every
    /// write-once push presumes.
    private func writeFinalizedCapture(m4aBytes: Data) throws {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let when = stamp(0)
        let manifest = Manifest(captureID: captureID, createdAt: when, state: .complete, stateSeq: 1,
                                stateUpdatedAt: when,
                                format: AudioFormatDescriptor(sampleRate: 48_000, channels: 1,
                                                              commonFormat: .pcmFormatFloat32,
                                                              interleaved: false, bytesPerFrame: 4),
                                final: FinalRef(verifiedAt: when, durationFrames: 480_000))
        try CaptureCoding.encoder().encode(manifest)
            .write(to: SegmentLayout.manifestURL(captureDirectory: captureDirectory))
        try m4aBytes.write(to: SegmentLayout.finalRecordingURL(captureDirectory: captureDirectory))
    }

    // MARK: localWriteOnceDigest

    func testAudioDigestHashesTheFinalM4A() async throws {
        let bytes = Data("final-m4a-bytes".utf8)
        try writeFinalizedCapture(m4aBytes: bytes)
        let digest = await exchange().localWriteOnceDigest(for: .audio(captureID: captureID))
        XCTAssertEqual(digest, SyncTreeScanner.rawDigest(bytes))
    }

    func testRevisionDigestHashesTheCanonicalFile() async throws {
        try writeFinalizedCapture(m4aBytes: Data("m4a".utf8))
        let store = TranscriptRevisionStore(capturesRoot: capturesRoot)
        let minted = TranscriptRevision(id: "R0", source: .machineLive, createdAt: stamp(0),
                                        spans: [TranscriptSpan(text: "hello", anchor: .none)],
                                        parentID: nil)
        _ = try await store.append(minted, captureID: captureID)
        let digest = await exchange(transcriptRevisionStore: store)
            .localWriteOnceDigest(for: .revision(id: "R0"))
        let expected = SyncTreeScanner.rawDigest(try CaptureCoding.encoder().encode(minted))
        XCTAssertEqual(digest, expected)
    }

    func testMissingArtifactAnswersNil() async throws {
        let digest = await exchange().localWriteOnceDigest(for: .audio(captureID: captureID))
        XCTAssertNil(digest, "no capture directory at all — nothing to hash, never a crash")
    }

    func testMutableNameAnswersNil() async throws {
        let digest = await exchange().localWriteOnceDigest(for: .journal(id: "J"))
        XCTAssertNil(digest, "mutable types have no single-artifact digest; refuse rather than invent one")
    }
}
```

Adjust the `TranscriptRevision` initializer / `store.append` call to the exact shapes
in `RaconteTests/SyncRevisionTests.swift` if they differ (that file is the source of
truth for the fixture idiom; do not invent new fixture helpers where one exists there).

- [ ] **Step 2: `xcodegen generate`, run `-only-testing:RaconteTests/SyncPushConflictTests`, verify FAIL** — `localWriteOnceDigest` undefined.

- [ ] **Step 3: Implement on `SyncRecordExchange`** (in `SyncIngest.swift`, adjacent
to `revisionRecordToPush`):

```swift
/// The LOCAL half of the write-once conflict comparison
/// (`WriteOnceConflictGate.decide`): the digest of the exact bytes this device
/// would push for `name`, read from the same files the corresponding
/// `*RecordToPush` builder reads — one location rule, never a second copy of it.
/// `nil` for anything unreadable/absent, and for every mutable type (those resolve
/// conflicts by merge, not digest).
func localWriteOnceDigest(for name: SyncRecordName) async -> UploadedDigest? {
    guard let containerRoot else { return nil }
    let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
    switch name {
    case .audio(let captureID):
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        guard let bytes = try? Data(contentsOf: SegmentLayout.finalRecordingURL(captureDirectory: directory),
                                    options: .mappedIfSafe) else { return nil }
        return SyncTreeScanner.rawDigest(bytes)
    case .liveLog(let captureID):
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        guard let bytes = try? Data(contentsOf: SegmentLayout.liveTranscriptURL(captureDirectory: directory),
                                    options: .mappedIfSafe) else { return nil }
        return SyncTreeScanner.rawDigest(bytes)
    case .revision(let id):
        guard let located = TranscriptRevisionStore.locateRevision(capturesRoot: capturesRoot,
                                                                    revisionID: id) else { return nil }
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot,
                                                        captureID: located.captureID)
        let fileURL = SegmentLayout.canonicalTranscriptURL(captureDirectory: directory,
                                                            revision: located.fileNumber)
        guard let bytes = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return SyncTreeScanner.rawDigest(bytes)
    case .image(let captureID, let imageID):
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        let sidecarURL = SegmentLayout.imageSidecarURL(captureDirectory: directory, imageID: imageID)
        guard let sidecarData = try? Data(contentsOf: sidecarURL),
              let sidecar = try? ImageStore.decodeSidecar(sidecarData) else { return nil }
        let fileURL = SegmentLayout.imageOriginalURL(captureDirectory: directory, imageID: imageID,
                                                      ext: sidecar.originalExtension)
        guard let bytes = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return SyncTreeScanner.rawDigest(bytes)
    case .journal, .entry, .markerStream:
        return nil
    }
}
```

(If `SyncTreeScanner.rawDigest` turns out not to exist under that exact name, use
whatever `audioRecordToPush` calls on its `bytes` — the two must share one formula.)

- [ ] **Step 4: Run, verify PASS.**

- [ ] **Step 5: Commit**

```bash
git add Raconte/Sync/SyncIngest.swift RaconteTests/SyncPushConflictTests.swift
git commit -m "feat(sync): localWriteOnceDigest — hash the exact would-push bytes for the conflict comparison"
```

---

### Task 3: `resolvePushConflicts` returns `PushConflictResolution`

**Files:**
- Modify: `Raconte/Sync/CloudEngineControl.swift` (protocol `CloudRecordExchange`,
  ~line 259; add the new struct beside the protocol)
- Modify: `Raconte/Sync/SyncIngest.swift` (`resolvePushConflicts`, ~line 3159)
- Modify: `RaconteTests/BatchRecordProviderTests.swift:29` (mock conformance)
- Test: `RaconteTests/SyncPushConflictTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1's `WriteOnceConflictGate`, Task 2's `localWriteOnceDigest(for:)`,
  existing `acceptRemote(_:)`, `archiveSystemFields(of:for:)` (private, same actor),
  `bookkeeping.recordUpload(_:for:)`, `SyncChildAssetField.sha256`,
  `SyncCloudIdentifiers.name(of:)`, `name.rawValue`.
- Produces: `struct PushConflictResolution: Equatable, Sendable { var resend:
  [SyncRecordName] = []; var settled: [SyncRecordName] = [] }` and the changed
  protocol requirement `func resolvePushConflicts(_ serverRecords: [CKRecord]) async
  -> PushConflictResolution`. Task 4 consumes both.

- [ ] **Step 1: Write the failing tests** (append to `SyncPushConflictTests`):

```swift
    // MARK: resolvePushConflicts — the short-circuit end to end

    /// A conflict server copy is exactly what CloudKit hands back on a rejected push:
    /// same sha256 FIELD, but its asset never downloaded. Strip the asset to match.
    private func serverRevisionCopy(sha256: String, bodyURL: URL) -> CKRecord {
        let entryID = SyncCloudIdentifiers.recordID(.entry(captureID: captureID), zoneID: zoneID)
        let record = SyncRecordBuilders.revisionRecord(revisionID: "R0", fileURL: bodyURL,
                                                       sha256: sha256, bytes: 1,
                                                       entryID: entryID, zoneID: zoneID)
        record[SyncRevisionField.body] = nil   // push-error serverRecord has no asset
        return record
    }

    func testByteIdenticalServerCopySettlesWritesLedgerAndArchivesTag() async throws {
        try writeFinalizedCapture(m4aBytes: Data("m4a".utf8))
        let store = TranscriptRevisionStore(capturesRoot: capturesRoot)
        let minted = TranscriptRevision(id: "R0", source: .machineLive, createdAt: stamp(0),
                                        spans: [TranscriptSpan(text: "hello", anchor: .none)],
                                        parentID: nil)
        _ = try await store.append(minted, captureID: captureID)
        let localSHA = SyncTreeScanner.rawDigest(try CaptureCoding.encoder().encode(minted)).sha256
        let bookkeeping = makeBookkeeping()
        let ex = exchange(transcriptRevisionStore: store, bookkeeping: bookkeeping)

        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("stub-body")
        try Data("x".utf8).write(to: bodyURL)
        let resolution = await ex.resolvePushConflicts([serverRevisionCopy(sha256: localSHA,
                                                                           bodyURL: bodyURL)])

        XCTAssertEqual(resolution.settled, [.revision(id: "R0")])
        XCTAssertTrue(resolution.resend.isEmpty, "a settled record must not be re-enqueued")
        let name = SyncRecordName.revision(id: "R0").rawValue
        XCTAssertEqual(await bookkeeping.ledger()[name]?.sha256, localSHA,
                       "the ledger credit is what stops reconcile re-enqueueing it forever")
        XCTAssertNotNil(await bookkeeping.systemFields(for: name),
                        "the server change tag must be archived for any future legitimate update")
    }

    func testDivergentServerCopyIsSettledWithoutALedgerEntry() async throws {
        try writeFinalizedCapture(m4aBytes: Data("m4a".utf8))
        let store = TranscriptRevisionStore(capturesRoot: capturesRoot)
        let minted = TranscriptRevision(id: "R0", source: .machineLive, createdAt: stamp(0),
                                        spans: [TranscriptSpan(text: "hello", anchor: .none)],
                                        parentID: nil)
        _ = try await store.append(minted, captureID: captureID)
        let bookkeeping = makeBookkeeping()
        let ex = exchange(transcriptRevisionStore: store, bookkeeping: bookkeeping)

        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("stub-body-2")
        try Data("x".utf8).write(to: bodyURL)
        let resolution = await ex.resolvePushConflicts([serverRevisionCopy(sha256: "not-the-local-sha",
                                                                           bodyURL: bodyURL)])

        XCTAssertEqual(resolution.settled, [.revision(id: "R0")],
                       "divergence retires the pending save too — loud once per launch, never a hot loop")
        XCTAssertTrue(resolution.resend.isEmpty)
        XCTAssertNil(await bookkeeping.ledger()[SyncRecordName.revision(id: "R0").rawValue],
                     "no ledger credit — reconcile must keep resurfacing a divergent record")
    }

    func testMutableTypeStillResends() async throws {
        let journal = Journal(id: "J-1", name: "Server name", createdAt: stamp(0),
                              voiceLabels: [:], modified: ["name": stamp(10)])
        let record = SyncRecordBuilders.journalRecord(journal: journal, coverFileURL: nil,
                                                      deviceID: "device-other", zoneID: zoneID)
        let resolution = await exchange().resolvePushConflicts([record])
        XCTAssertEqual(resolution.resend, [.journal(id: "J-1")],
                       "mutable types keep the merge-then-resend path verbatim")
        XCTAssertTrue(resolution.settled.isEmpty)
    }
```

(If the `Journal` initializer's argument list differs, mirror the fixture at
`RaconteTests/SyncJournalIngestTests.swift:83` exactly.)

- [ ] **Step 2: Run, verify FAIL** — `resolvePushConflicts` still returns `[SyncRecordName]`.

- [ ] **Step 3: Implement.**

In `CloudEngineControl.swift`, beside `protocol CloudRecordExchange`:

```swift
/// `resolvePushConflicts`' two-way answer: `resend` goes back into the engine's
/// pending saves (mutable types, after their LWW merge); `settled` is REMOVED from
/// pending — either credited to the upload ledger (byte-identical write-once copy)
/// or deliberately parked for reconciliation (divergent write-once copy, no ledger
/// entry). Without the removal the engine retries the name forever across launches.
struct PushConflictResolution: Equatable, Sendable {
    var resend: [SyncRecordName] = []
    var settled: [SyncRecordName] = []
}
```

Change the protocol requirement to `-> PushConflictResolution`.

In `SyncIngest.swift`, replace the body of `resolvePushConflicts` (keep its existing
doc comment's one-path-to-push reasoning for the mutable branch, extend it for the
write-once branch):

```swift
func resolvePushConflicts(_ serverRecords: [CKRecord]) async -> PushConflictResolution {
    var resolution = PushConflictResolution()
    for record in serverRecords {
        guard let name = SyncCloudIdentifiers.name(of: record.recordID) else { continue }
        guard WriteOnceConflictGate.isWriteOnce(name) else {
            await acceptRemote(record)
            resolution.resend.append(name)
            continue
        }
        let serverSHA = record[SyncChildAssetField.sha256] as? String
        switch WriteOnceConflictGate.decide(serverSHA256: serverSHA,
                                            local: await localWriteOnceDigest(for: name)) {
        case .settleAsUploaded(let digest):
            await archiveSystemFields(of: record, for: name)
            do {
                try await bookkeeping.recordUpload(digest, for: name.rawValue)
            } catch {
                log.error("""
                    sync: \(name.rawValue, privacy: .public) settled but the ledger write failed: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
            log.notice("""
                sync: \(name.rawValue, privacy: .public) already on the server byte-identical — \
                settled as uploaded, pending save retired
                """)
            resolution.settled.append(name)
        case .divergent(let reason):
            log.error("""
                sync: \(name.rawValue, privacy: .public) write-once record DIVERGES from the \
                server copy (\(reason, privacy: .public)) — refusing to overwrite; pending save \
                retired, left to reconciliation
                """)
            resolution.settled.append(name)
        }
    }
    return resolution
}
```

Update the mock in `RaconteTests/BatchRecordProviderTests.swift:29`:

```swift
func resolvePushConflicts(_ serverRecords: [CKRecord]) async -> PushConflictResolution { .init() }
```

- [ ] **Step 4: Run `SyncPushConflictTests` — PASS. Then compile the whole test
  target; Task 4's call site in `handleFailedSaves` will now be the only compile
  error left. Fix it in the same commit with the minimal edit from Task 4 Step 1
  ONLY IF the compiler forces it; otherwise leave Task 4 clean.** (In practice the
  protocol change breaks `handleFailedSaves` immediately — do Task 4's code edit
  now, but keep its verification steps as written there.)

- [ ] **Step 5: Commit**

```bash
git add Raconte/Sync/CloudEngineControl.swift Raconte/Sync/SyncIngest.swift RaconteTests/BatchRecordProviderTests.swift RaconteTests/SyncPushConflictTests.swift
git commit -m "feat(sync): serverRecordChanged short-circuit — settle byte-identical write-once records instead of re-pushing forever"
```

---

### Task 4: Engine wiring — retire settled pending saves

**Files:**
- Modify: `Raconte/Sync/CloudEngineControl.swift` (`handleFailedSaves`, the
  `toResend += await exchange.resolvePushConflicts(conflicts)` site, ~line 613)

**Interfaces:**
- Consumes: Task 3's `PushConflictResolution`;
  `syncEngine.state.remove(pendingRecordZoneChanges:)`;
  `SyncCloudIdentifiers.recordID(_:zoneID:)`.
- Produces: nothing new — terminal wiring.

- [ ] **Step 1: Replace the conflict hand-off at the end of `handleFailedSaves`:**

```swift
var settled: [SyncRecordName] = []
if !conflicts.isEmpty {
    let resolution = await exchange.resolvePushConflicts(conflicts)
    toResend += resolution.resend
    settled = resolution.settled
}
// The remove is the half that ends the loop: a settled name left pending is
// retried on every future send, launch after launch (the exact defect this
// fixes). `state.remove` is idempotent for names not pending.
if !settled.isEmpty {
    syncEngine.state.remove(pendingRecordZoneChanges: settled.map {
        .saveRecord(SyncCloudIdentifiers.recordID($0, zoneID: zoneID))
    })
}
guard !toResend.isEmpty else { return }
syncEngine.state.add(pendingRecordZoneChanges: toResend.map {
    .saveRecord(SyncCloudIdentifiers.recordID($0, zoneID: zoneID))
})
```

Also update `handleFailedSaves`' doc comment: the `.mergeConflict` sentence should now
say write-once conflicts settle or park via `WriteOnceConflictGate` while mutable
types merge-and-resend.

- [ ] **Step 2: Run the FULL unit suite** (Global Constraints command, no
  `-only-testing`). Expected: everything green — reconcile the count against the
  suite's pass on `main` before this branch.

- [ ] **Step 3: iOS compile check:**

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 4: Commit**

```bash
git add Raconte/Sync/CloudEngineControl.swift
git commit -m "feat(sync): retire settled write-once conflicts from pending saves (state.remove) — ends the serverRecordChanged loop"
```

---

### Task 5: Build 10 bump + docs + PR

**Files:**
- Modify: `project.yml:52` (`CFBundleVersion: "9"` → `"10"`)
- Modify: `Raconte/Info.plist` (the `CFBundleVersion` value under the key at line 21 —
  the companion edit build 9 needed as a separate fixup commit; do both together this time)
- Modify: `docs/2026-08-26-sync-investigation-state.md` (RESOLVED section — append
  one short paragraph: fix implemented on this branch, the settle/divergent rules,
  device verification pending)

- [ ] **Step 1: Make the three edits.** Keep the doc addition to ~5 lines, plain and terse.

- [ ] **Step 2: `xcodegen generate`, then confirm the generated project carries 10**
  (`grep -n 'CFBundleVersion' project.yml Raconte/Info.plist`).

- [ ] **Step 3: Commit**

```bash
git add project.yml Raconte/Info.plist docs/2026-08-26-sync-investigation-state.md
git commit -m "chore: bump CFBundleVersion to 10 for the write-once-conflict-fix TestFlight build"
```

- [ ] **Step 4: Open the PR** (never merge — that is Nico's): write the body to a
  temp file, then

```bash
git push -u origin fix/sync-write-once-conflict
gh pr create --title "fix(sync): settle byte-identical write-once serverRecordChanged conflicts (build 10)" --body-file <tempfile>
```

  PR body: the loop in two sentences, the settle/divergent rules, test coverage, and
  the device-verification plan (below) — no "Close #N" keywords (no open issue tracks
  this fix; the investigation doc does).

**Device verification (manual, Nico, post-merge — include verbatim in the PR body):**
TestFlight build 10 on iPhone and iPad. Open the app, let a sync cycle run, then check
Sidebar → About → sync status: iPhone "Pending saves" must go 10 → 0 and iPad
106 → 0, with `settled as uploaded` lines (not `DIVERGES`) in a log capture if taken.
Any `DIVERGES` line is a finding, not a failure of the build — capture and report it.
