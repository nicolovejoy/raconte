# #94 — Stuck Pending Changes + verifyFinal Dead End: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the 20 dev-era entries (and anything like them) sync: a pending change whose record can't be built is removed from the engine's state instead of retrying forever, and a capture whose raw segments are gone but whose `.m4a` exists gets verified and stamped so it becomes push-eligible.

**Architecture:** Three independent fixes, each behind an existing seam. (1) The `nextRecordZoneChangeBatch` record provider gets an explicit `state.remove` on every nil return, extracted as a testable static helper. (2) `FinalizerWorker.finalize` gains a probe-and-stamp branch for the "m4a present, raw gone, `verifiedAt` nil" state. (3) `CaptureScreenModel.bootstrap` fires `FinalizeArtifactPush.push` for launch-healed captures so a heal syncs this launch, not next.

**Tech Stack:** Swift 6 strict concurrency, XCTest, CloudKit CKSyncEngine. Xcode project is generated — run `xcodegen generate` only if `project.yml` changes (it does not in this plan; new test code lives in existing test files, new production code in existing files).

**Spec:** GitHub issue #94 (`gh issue view 94 --json title,body`). Root causes confirmed there; this plan implements its two specified fixes plus its "secondary finding".

## Global Constraints

- Branch: `fix/94-stuck-pending-and-verify-final` (already checked out in this worktree).
- Unit-test baseline: 1791 green. Every task ends with the full unit suite green.
- Test command (macOS, MUST use the nocloud entitlements override — never `CODE_SIGNING_ALLOWED=NO`):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test
```

  For a fast single-class red/green cycle append `-only-testing:RaconteTests/<ClassName>`.
- If `Raconte.xcodeproj` is missing in the worktree, run `xcodegen generate` first.
- Commit messages end with:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01PTApZNMf8P9BVdGt2nEsGF
```

- Data-safety bias (project principle): audio is ground truth. Nothing in this plan may delete or rewrite an `.m4a`, and a failed probe must leave every byte in place.
- Do NOT merge the PR at the end — open it and stop (merges are Nico's).

---

### Task 1: Record provider removes the pending change on every nil return

The codebase's core assumption is false: `RecordZoneChangeBatch.init(pendingChanges:recordProvider:)` is a value initializer with no reference to the engine's `State` — returning nil drops the record from *this batch only*. The change stays in `pendingRecordZoneChanges`, is persisted into `engine-state.bin`, and retries on every launch forever. Apple's own sample calls `syncEngine.state.remove(pendingRecordZoneChanges:)` inside the provider before returning nil. This repo's only `state.remove` call today is `dropPendingSaves`.

Safety argument (why removal is correct): the upload ledger is written only after a record lands, so anything removed here that later becomes buildable is re-enqueued by the next launch's `SyncPlanner.reconcile()` scan. Removal converts "retry forever, unbuildable" into "wait for eligibility, then reconcile re-enqueues" — the semantics the old comment *claimed* nil already had.

**Files:**
- Modify: `Raconte/Sync/CloudEngineControl.swift:594-617` (`nextRecordZoneChangeBatch`), plus the false doc comments at `:601-606` (batch-builder comment) and `:544-546` (`handleFailedSaves` doc referencing "the batch builder's nil").
- Test: `RaconteTests/BatchRecordProviderTests.swift` (new file — new test files in `RaconteTests/` are picked up by the generated project automatically; no `project.yml` change).

**Interfaces:**
- Consumes: `protocol CloudRecordExchange` (`CloudEngineControl.swift:207` — read the full protocol to write the fake; unimplemented members may `fatalError` or no-op), `SyncCloudIdentifiers.name(of:)` / `.recordID(_:zoneID:)`, `SyncRecordName`.
- Produces: `CloudKitEngineControl.provideRecord(for:exchange:zoneID:removePendingSave:) async -> CKRecord?` — internal static; Task 1 only, no later task consumes it, but the production closure in `nextRecordZoneChangeBatch` must route through it so the tested code is the shipped code.

- [ ] **Step 1: Write the failing tests**

Create `RaconteTests/BatchRecordProviderTests.swift`:

```swift
import XCTest
import CloudKit
@testable import Raconte

/// #94 cause 1: a nil from the batch's recordProvider does NOT remove the pending
/// change — `RecordZoneChangeBatch.init` is a value init with no State access, so
/// the provider itself must call `state.remove` before answering nil, or the name
/// retries forever across launches via `engine-state.bin`.
///
/// `CloudKitEngineControl` cannot be unit-tested with a live `CKSyncEngine`
/// (`PendingEngineChangesTests` precedent), so the provider body is the static
/// `CloudKitEngineControl.provideRecord`, driven here with a fake exchange and a
/// recording remove closure; `nextRecordZoneChangeBatch` routes through it.
final class BatchRecordProviderTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "RaconteZone")

    /// Minimal fake: answers `recordToPush` from a closure; every other member is
    /// an unreachable-in-these-tests no-op.
    private final class FakeExchange: CloudRecordExchange, @unchecked Sendable {
        var record: (@Sendable (SyncRecordName) -> CKRecord?) = { _ in nil }
        func recordToPush(for name: SyncRecordName, zoneID: CKRecordZone.ID) async -> CKRecord? {
            record(name)
        }
        // ... conform to the remaining CloudRecordExchange members with no-op
        // bodies (return empty/false/() as the signature demands). Read the
        // protocol at CloudEngineControl.swift:207 and implement ALL of them.
    }

    private final class RemoveRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _removed: [CKRecord.ID] = []
        var removed: [CKRecord.ID] { lock.withLock { _removed } }
        func callAsFunction(_ id: CKRecord.ID) { lock.withLock { _removed.append(id) } }
    }

    func testABuildableRecordIsReturnedAndNothingIsRemoved() async {
        let name = SyncRecordName.journal(id: "01J00000000000000000000001")
        let recordID = SyncCloudIdentifiers.recordID(name, zoneID: zoneID)
        let exchange = FakeExchange()
        exchange.record = { _ in CKRecord(recordType: "Journal", recordID: recordID) }
        let remover = RemoveRecorder()

        let record = await CloudKitEngineControl.provideRecord(
            for: recordID, exchange: exchange, zoneID: zoneID,
            removePendingSave: { remover($0) })

        XCTAssertNotNil(record)
        XCTAssertEqual(remover.removed, [], "a buildable record must not touch pending state")
    }

    func testAnUnbuildableRecordIsRemovedFromPendingAndAnsweredNil() async {
        let name = SyncRecordName.entry(captureID: "01J00000000000000000000002")
        let recordID = SyncCloudIdentifiers.recordID(name, zoneID: zoneID)
        let exchange = FakeExchange()   // recordToPush answers nil
        let remover = RemoveRecorder()

        let record = await CloudKitEngineControl.provideRecord(
            for: recordID, exchange: exchange, zoneID: zoneID,
            removePendingSave: { remover($0) })

        XCTAssertNil(record)
        XCTAssertEqual(remover.removed, [recordID],
                       "nil alone removes nothing — the provider must remove the pending save itself")
    }

    func testAnUnparseableRecordNameIsRemovedFromPendingAndAnsweredNil() async {
        let recordID = CKRecord.ID(recordName: "not-a-raconte-name", zoneID: zoneID)
        let exchange = FakeExchange()
        let remover = RemoveRecorder()

        let record = await CloudKitEngineControl.provideRecord(
            for: recordID, exchange: exchange, zoneID: zoneID,
            removePendingSave: { remover($0) })

        XCTAssertNil(record)
        XCTAssertEqual(remover.removed, [recordID])
    }
}
```

Adjust the two `SyncRecordName` case spellings to the enum's real ones (grep `enum SyncRecordName`) — the tests above use `.journal(id:)` / `.entry(captureID:)` as seen elsewhere in the suite.

- [ ] **Step 2: Run to verify they fail**

Run the test command with `-only-testing:RaconteTests/BatchRecordProviderTests`.
Expected: compile failure — `provideRecord` does not exist. That is the correct RED for a new seam.

- [ ] **Step 3: Implement**

In `CloudEngineControl.swift`, add the static helper and route the closure through it:

```swift
    /// The body of `nextRecordZoneChangeBatch`'s recordProvider, extracted so the
    /// nil-means-remove contract is unit-testable (`BatchRecordProviderTests`).
    ///
    /// #94: `RecordZoneChangeBatch.init(pendingChanges:recordProvider:)` is a value
    /// initializer with no access to the engine's `State` — a nil return skips the
    /// record for THIS batch only and removes nothing. Anything unbuildable must be
    /// removed here explicitly or it is retried on every send and every launch
    /// (persisted via `engine-state.bin`), which is exactly how the dev-era entries
    /// got stuck. Removal is safe: the upload ledger is written only after a record
    /// lands, so the next reconciliation scan re-enqueues anything that has become
    /// buildable since.
    static func provideRecord(for recordID: CKRecord.ID,
                              exchange: any CloudRecordExchange,
                              zoneID: CKRecordZone.ID,
                              removePendingSave: @Sendable (CKRecord.ID) async -> Void)
        async -> CKRecord? {
        guard let name = SyncCloudIdentifiers.name(of: recordID) else {
            await removePendingSave(recordID)
            return nil
        }
        guard let record = await exchange.recordToPush(for: name, zoneID: zoneID) else {
            await removePendingSave(recordID)
            return nil
        }
        return record
    }
```

Rewrite `nextRecordZoneChangeBatch`'s closure (and its false comment at :601-606):

```swift
        // #94: a nil from this provider does NOT remove the pending change — the
        // batch init is a value init with no State access (the old comment here
        // claimed otherwise). `provideRecord` removes the pending save explicitly
        // before answering nil, so an unbuildable name stops retrying; the next
        // reconciliation scan re-enqueues it once it is buildable.
        let log = self.log
        let exchange = self.exchange
        let zoneID = self.zoneID
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            let record = await Self.provideRecord(
                for: recordID, exchange: exchange, zoneID: zoneID,
                removePendingSave: { id in
                    log.notice("""
                        sync: \(id.recordName, privacy: .public) not buildable — \
                        pending change removed; reconcile re-enqueues when eligible
                        """)
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                })
            return record
        }
```

(Keep or drop the `let record` binding as the compiler prefers; the load-bearing part is routing through `provideRecord` with a real `state.remove`.)

Also fix the second false claim: in `handleFailedSaves`' doc comment (`:544-546`), replace "are safe to leave for the same reason the batch builder's nil is: no ledger entry was written, so the next reconciliation scan re-enqueues them" with wording that stands on its own, e.g. "are safe to leave: no ledger entry was written, so the next reconciliation scan re-enqueues them." Then `grep -n "drop this one" Raconte/Sync/` — no other site may still assert the old semantics.

- [ ] **Step 4: Run the new class, then the full unit suite**

Expected: 3 new tests pass; suite is 1791 + 3 = 1794 green.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Sync/CloudEngineControl.swift RaconteTests/BatchRecordProviderTests.swift
git commit -m "fix(sync): remove a pending change the provider cannot build — nil alone never removed it (#94 cause 1)"
```

---

### Task 2: `.verifyFinal` verifies the existing m4a and stamps `verifiedAt`

Today `FinalizerWorker.finalize` on a capture whose `segments/` is gone reads zero segments, hits the empty-prefix guard, and returns `.skipped` **without stamping** — while `RecoveryPlanner` re-emits `.verifyFinal` for the same capture every launch. A capture that crashed between `promote()` and the `.complete` manifest write (m4a present, raw deleted, `verifiedAt` nil) is therefore permanently unverifiable and permanently push-ineligible (`FinalizeArtifactPush.isFinalized` reads `final.verifiedAt != nil`). Playback is fine (`PlayableSourceSelector` prefers the m4a), which is why this was invisible.

Fix: in the empty-prefix branch, when a promoted `.m4a` exists and `verifiedAt` is nil, verify the m4a directly (`encoder.verify` — decode probe) and on a pass stamp `final.verifiedAt`/`final.durationFrames` and write the manifest at `.complete`. The raw-vs-decoded duration cross-check is impossible without raw segments; `decodable && nonSilent` is the whole probe, and `durationFrames` comes from the decode itself.

**Files:**
- Modify: `Raconte/Capture/FinalizerWorker.swift:100-111` (the empty-prefix guard).
- Test: `RaconteTests/FinalizerTests.swift` (existing `FakeAudioEncoder` + helpers).

**Interfaces:**
- Consumes: `AudioEncoder.verify(m4aURL:) -> VerifyResult` (`decodable`, `decodedFrameCount`, `nonSilent`), `SegmentLayout.finalRecordingURL(captureDirectory:)`, `Manifest.final: FinalRef` (`verifiedAt: Date?`, `durationFrames: Int?` — confirm the exact field types in `Manifest`), existing `writeManifest(_:dir:state:)`.
- Produces: no new API — `FinalizeStatus.completed` now also covers "verified in place"; Task 3 relies on `FinalizeArtifactPush.isFinalized` reading true after this heals a capture.

- [ ] **Step 1: Write the failing tests**

Add to `FinalizerTests.swift` a helper that lays down the dead-end state, plus three tests:

```swift
    /// #94 cause 2: manifest present with `final.verifiedAt == nil`, a promoted
    /// `final/recording.m4a` on disk, and NO `segments/` directory at all — the
    /// crash-between-promote-and-complete state the 20 dev-era captures are in.
    private func layDownPromotedButUnstampedCapture(id: String, state: CaptureState = .finalizing) throws {
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: dir), withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02, 0x03]).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: dir))
        let manifestFmt = AudioFormatDescriptor(sampleRate: Self.sampleRate, channels: 1,
                                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let manifest = Manifest(captureID: id, createdAt: Date(timeIntervalSince1970: 0),
                                state: state, stateSeq: 7,
                                stateUpdatedAt: Date(timeIntervalSince1970: 0),
                                format: manifestFmt, segmentCount: 3,
                                lastKnownFrameOffset: 2500)
        let data = try CaptureCoding.encoder().encode(manifest)
        try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir), writing: data)
    }

    // MARK: #94 — verifyFinal with raw segments gone

    func testPromotedButUnstampedCaptureIsVerifiedInPlaceAndStamped() async throws {
        let id = "01J000000000000000000094"
        try layDownPromotedButUnstampedCapture(id: id)
        let encoder = FakeAudioEncoder()
        encoder.verifyOverride = VerifyResult(decodable: true, decodedFrameCount: 2500, nonSilent: true)
        let worker = makeWorker(encoder: encoder)
        await worker.enqueue(id)

        let outcomes = await worker.drain()

        XCTAssertEqual(outcomes.first?.status, .completed)
        XCTAssertEqual(encoder.calls, [], "nothing to encode — the existing m4a is verified in place")
        let manifest = try readManifest(id)
        XCTAssertNotNil(manifest.final.verifiedAt, "the stamp is the whole fix — push eligibility reads it")
        XCTAssertEqual(manifest.final.durationFrames, 2500)
        XCTAssertEqual(manifest.state, .complete)
    }

    func testFailedProbeStampsNothingKeepsTheM4aAndFlagsAttention() async throws {
        let id = "01J000000000000000000095"
        try layDownPromotedButUnstampedCapture(id: id)
        let encoder = FakeAudioEncoder()
        encoder.verifyOverride = VerifyResult(decodable: false, decodedFrameCount: 0, nonSilent: false)
        let worker = makeWorker(encoder: encoder)
        await worker.enqueue(id)

        let outcomes = await worker.drain()

        XCTAssertEqual(outcomes.first?.status, .needsAttention)
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        XCTAssertTrue(exists(SegmentLayout.finalRecordingURL(captureDirectory: dir)),
                      "audio is ground truth — a failed probe must not touch the m4a")
        let manifest = try readManifest(id)
        XCTAssertNil(manifest.final.verifiedAt)
        XCTAssertEqual(manifest.needsAttention, true)
    }

    func testCaptureWithNeitherSegmentsNorM4aStaysSkipped() async throws {
        let id = "01J000000000000000000096"
        try layDownPromotedButUnstampedCapture(id: id)
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        try FileManager.default.removeItem(at: SegmentLayout.finalRecordingURL(captureDirectory: dir))
        let worker = makeWorker(encoder: FakeAudioEncoder())
        await worker.enqueue(id)

        let outcomes = await worker.drain()

        XCTAssertEqual(outcomes.first?.status, .skipped)
        XCTAssertNil(try readManifest(id).final.verifiedAt)
    }
```

Adjust `Manifest` init parameters / `FinalRef` field names to the real ones (read `Manifest`'s definition first); the *assertions* are the contract. If `manifest.needsAttention` is `Bool?`, compare against `true` as written.

- [ ] **Step 2: Run to verify the new tests fail**

`-only-testing:RaconteTests/FinalizerTests`. Expected: the first two FAIL (`.skipped` instead of `.completed`/`.needsAttention`, `verifiedAt` nil); the third may already pass — that is fine, it is the regression pin.

- [ ] **Step 3: Implement**

In `FinalizerWorker.finalize`, replace the empty-prefix guard body (`:101-111`) with:

```swift
        // Nothing contiguous to encode.
        guard !prefix.isEmpty else {
            // #94: raw segments gone but a promoted `.m4a` exists and was never
            // stamped — the crash-between-promote-and-`.complete` state. Re-deriving
            // from raw is impossible forever, so verify the m4a itself (decode
            // probe) and stamp. Without this, recovery re-plans `.verifyFinal`
            // every launch and this returns `.skipped` every time, leaving the
            // capture permanently push-ineligible while playing fine locally.
            let m4aURL = SegmentLayout.finalRecordingURL(captureDirectory: dir)
            if !hadGap, manifest.final.verifiedAt == nil,
               FileManager.default.fileExists(atPath: m4aURL.path) {
                if let verified = try? await encoder.verify(m4aURL: m4aURL),
                   verified.decodable, verified.nonSilent {
                    manifest.final.verifiedAt = now()
                    manifest.final.durationFrames = verified.decodedFrameCount
                    writeManifest(manifest, dir: dir, state: .complete)
                    return FinalizeOutcome(captureID: captureID, status: .completed,
                                           encodedFrameCount: 0,
                                           finalizeAttempts: manifest.finalizeAttempts ?? 0,
                                           hadGap: false)
                }
                // Probe failed with no raw to fall back on: keep every byte,
                // surface it. NOT the failEncode path — that would delete a
                // `.part` and burn retry budget on a state retries cannot change.
                manifest.needsAttention = true
                writeManifest(manifest, dir: dir, state: manifest.state)
                return FinalizeOutcome(captureID: captureID, status: .needsAttention,
                                       encodedFrameCount: 0,
                                       finalizeAttempts: manifest.finalizeAttempts ?? 0,
                                       hadGap: false)
            }
            if hadGap {
                manifest.needsAttention = true
                writeManifest(manifest, dir: dir, state: .captured)
            }
            return FinalizeOutcome(captureID: captureID,
                                   status: hadGap ? .needsAttention : .skipped,
                                   encodedFrameCount: 0,
                                   finalizeAttempts: manifest.finalizeAttempts ?? 0,
                                   hadGap: hadGap)
        }
```

Note `writeManifest(manifest, dir: dir, state: manifest.state)` on the probe-fail path deliberately preserves the on-disk state rather than inventing one. If `manifest.state` is non-optional on `Manifest` this compiles as-is; adjust to the real property if it differs.

- [ ] **Step 4: Run FinalizerTests, then the full unit suite**

Expected: all three new tests pass; nothing else moved (the branch is unreachable for captures with raw segments). Suite: 1794 + 3 = 1797 green.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Capture/FinalizerWorker.swift RaconteTests/FinalizerTests.swift
git commit -m "fix(capture): verifyFinal probes the existing m4a and stamps verifiedAt when raw segments are gone (#94 cause 2)"
```

---

### Task 3: Launch recovery pushes what it healed, same launch

`CaptureScreenModel.bootstrap` runs the finalizer over the recovery queue but never calls `FinalizeArtifactPush.push`, so a capture healed at launch (including everything Task 2 heals) is not enqueued for sync until the *next* launch's reconcile. `finishCurrentCapture` already does this push for in-session captures (`CaptureScreenModel.swift:673-675`); bootstrap gets the same loop.

**Files:**
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift:296-346` (`bootstrap()`).
- Test: `RaconteTests/CaptureScreenModelTests.swift`.

**Interfaces:**
- Consumes: `FinalizeArtifactPush.push(capturesRoot:captureID:syncHooks:)` (nil-hooks no-op, gated internally on `isFinalized`), `CaptureScreenModel.attach(syncHooks:)` (`CaptureScreenModel.swift:81`), the `RecordingSyncHooks` fake (`SyncEntryRecordTests.swift` — if it is `private` there, move/copy it to a shared test helper rather than widening production API), Task 2's stamp behavior, `layDownPromotedButUnstampedCapture`-style fixture (repeated below — do not import from FinalizerTests).
- Produces: nothing new — wiring only.

- [ ] **Step 1: Write the failing test**

Add to `CaptureScreenModelTests.swift` (reusing that file's `root`, `ModelFakeSession`, `ModelFakeRecorder`, `FakeAudioEncoder` patterns — read a neighboring test first):

```swift
    /// #94 secondary finding: a capture healed by LAUNCH recovery must be enqueued
    /// for sync in the same launch — before this fix, `bootstrap` ran the finalizer
    /// but never called `FinalizeArtifactPush.push`, so the heal waited a full
    /// relaunch to sync. End-to-end through the real pipeline: planner emits
    /// `.verifyFinal`, the finalizer stamps off the existing m4a (Task 2), and
    /// bootstrap pushes the now-eligible names into the recorded hooks.
    func testBootstrapPushesACaptureHealedByLaunchRecovery() async throws {
        let id = "01J000000000000000000097"
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: id)
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: dir), withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02, 0x03]).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: dir))
        let manifestFmt = AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let manifest = Manifest(captureID: id, createdAt: Date(timeIntervalSince1970: 0),
                                state: .finalizing, stateSeq: 7,
                                stateUpdatedAt: Date(timeIntervalSince1970: 0),
                                format: manifestFmt, segmentCount: 3,
                                lastKnownFrameOffset: 2500)
        try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir),
                               writing: CaptureCoding.encoder().encode(manifest))

        let encoder = FakeAudioEncoder()
        encoder.verifyOverride = VerifyResult(decodable: true, decodedFrameCount: 2500, nonSilent: true)
        let hooks = RecordingSyncHooks()
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { ModelFakeRecorder() },
            encoder: encoder)
        model.attach(syncHooks: hooks)

        await model.bootstrap()

        let names = await hooks.names
        XCTAssertTrue(names.contains(.entry(captureID: id)),
                      "a launch-healed capture must sync this launch, not the next one")
        XCTAssertTrue(names.contains(.audio(captureID: id)))
    }
```

Match the fixture details (`Manifest` init, `RecordingSyncHooks` location/visibility, exact `SyncRecordName` spellings) to the real code; the assertion — hooks see `.entry` + `.audio` after nothing but `bootstrap()` — is the contract. If `bootstrap` needs the coordinator's recovery to route this capture into `finalizeQueue`, note that `CaptureCoordinator` merges `outcome.verifyQueue` into `finalizeQueue` (`CaptureCoordinator.swift:236`), so `.verifyFinal` captures arrive without extra plumbing.

- [ ] **Step 2: Run to verify it fails**

`-only-testing:RaconteTests/CaptureScreenModelTests`. Expected: FAIL — `hooks.names` is empty (Task 2 stamps the capture, but nothing pushes it).

- [ ] **Step 3: Implement**

In `bootstrap()`, after the `detectSpokenDate` loop and before `library.rescan()` (`CaptureScreenModel.swift:307-308`):

```swift
        for id in recoveredQueue { await detectSpokenDate(for: id) }
        // #94 secondary finding: the launch-recovery mirror of
        // `finishCurrentCapture`'s push loop. Without it a capture healed at
        // launch is not enqueued for sync until the NEXT launch's reconcile.
        // `push` is internally gated on `isFinalized`, so only captures whose
        // `.m4a` really verified fire, and a nil `syncHooks` no-ops exactly as
        // everywhere else. Before `rescan()` so the library's refreshed view and
        // sync eligibility can never disagree within one bootstrap.
        for id in recoveredQueue {
            await FinalizeArtifactPush.push(capturesRoot: capturesRoot, captureID: id, syncHooks: syncHooks)
        }
        await library.rescan()
```

- [ ] **Step 4: Run the class, then the full unit suite**

Expected: new test passes; suite 1797 + 1 = 1798 green. (Existing bootstrap tests have no syncHooks attached, so the added loop no-ops there.)

- [ ] **Step 5: Commit**

```bash
git add Raconte/Capture/UI/CaptureScreenModel.swift RaconteTests/CaptureScreenModelTests.swift
git commit -m "fix(capture): bootstrap pushes launch-healed captures the same launch (#94 secondary)"
```

---

### Task 4: Whole-branch verification and PR

- [ ] **Step 1: Full unit suite** — the exact test command from Global Constraints, no `-only-testing`. Expected: 1798 green, zero failures. Report the real count.
- [ ] **Step 2: iOS compile check**

```bash
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 3: Push the branch and open the PR** (do NOT merge; no close-keywords — write "Addresses #94", never "Fixes #94", because the on-device verification is still pending):

```bash
git push -u origin fix/94-stuck-pending-and-verify-final
gh pr create --title "fix: unstick pending changes the provider cannot build; verifyFinal stamps off the existing m4a (#94)" --body-file <path-to-body-file>
```

PR body: summarize the three fixes (provider `state.remove`, m4a probe-and-stamp, bootstrap push), the safety arguments (ledger-gated re-enqueue; audio never touched), and the test delta (1791 → 1798). End with the standard generated-with footer.
