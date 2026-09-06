# Overnight Hardening + Export (2026-09-06) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the owner-approved overnight slate as four independent PRs, each branched
from `main`, each ending at an open PR for the owner to merge in order: sync land-or-park
(#85, #91), the corrupt-entry repair route (#81), small debt (#71, #67 items 2/3/4), and the
open-format archive export with a round-trip verifier.

**Architecture:** PR 1 adds one durable file to the sync bookkeeping store (parked record
names), splits four compound ingest guards so each sub-cause parks instead of drops, adds one
engine verb that refetches named records, and extracts the NOT_FOUND resend decision into a
pure planner. PR 2 adds a `quarantine/` sibling of `captures/` and a Trash-screen section
that moves an unreadable-sidecar capture there. PR 3 is three bounded fixes with pure rules.
PR 4 is a new `Raconte/Export/` module: a walker that lists the archive's files, an exporter
that copies them byte-for-byte into a checksummed package with a derived `transcript.md`,
a verifier that reads the package back, and an About-screen row that runs both.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency,
XcodeGen project, XCTest + XCUITest, CryptoKit SHA256.

**Spec:** Owner rulings in the 2026-09-06 evening session (restated below); issue bodies
#85, #91, #81, #71, #67; `docs/plans/2026-07-29-data-model-and-migration.md` §3 (export
package, adapted to the file-based archive that actually shipped);
`docs/plans/2026-09-06-roadmap-review-and-phases.md` Phase 1 and Phase 2.

Owner rulings, verbatim in substance:
1. Slate: Phase 1 hardening + export. Four PRs, owner merges in order, "Update branch"
   between merges.
2. #2 (gap-honest capture) is HELD — do not touch the realtime tap.
3. Export defaults accepted: per-entry folder with `audio.m4a`, `transcript.md` (current
   revision), `entry.json`, the revision chain, the marker streams; top-level
   `journals.json` and a manifest with a sha256 per file; verifier reads the package back
   and checks every entry, revision and audio file; target is a folder the owner picks
   (macOS save panel / iOS document picker).
4. The M4 acceptance gate (delete the app from a Mac, reinstall, archive reconstructs from
   CloudKit) has NEVER been run. Record it as a named manual follow-up.
5. "Use cheaper models a lot": implementers and per-task reviewers run on Sonnet; only
   the whole-branch reviews run on Opus.
6. #50 was in the approved slate but its own body says it needs a design pass on the
   revision-chain format first. It is DROPPED from this run; #67 item 4 takes its slot.

## Global Constraints

- **Branch per PR, from `main` at or after `f406b276`.** Four branches:
  `feat/sync-land-or-park`, `feat/81-unreadable-entry-repair`, `feat/small-debt-2026-09-06`,
  `feat/archive-export`. Each PR's body uses `Closes #N` only for issues it fully resolves.
  #67 is a consolidated issue: PR 3 COMMENTS on it naming items 2, 3, 4 as done and does
  NOT close it. PR bodies via `--body-file`, never a heredoc. **Merges are the owner's.**
- **Worktrees:** one per PR, under `.worktrees/<branch>` (gitignored), created with
  `git worktree add .worktrees/<branch> -b <branch> main`. Subagent worktrees branch from
  the DEFAULT branch — every branch here starts from `main`, so that is correct. Run
  `xcodegen generate` in every fresh worktree before the first build.
- Xcode project is GENERATED: after adding, renaming or deleting a Swift file, run
  `xcodegen generate`. **A new test file that is not regenerated runs green at the OLD
  count** — check the executed count moved, not the exit code.
- macOS unit-test command (sandbox is NOT optional — never `CODE_SIGNING_ALLOWED=NO`,
  the test host would sweep the owner's real archive):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test
```

  To run one class: append `-only-testing:RaconteTests/<Class>`.
- iOS compile check: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- UI tests (simulator only). **The whole `RaconteUI` suite exceeds the Bash tool's
  10-minute cap**: run FOREGROUND `-only-testing:RaconteUITests/<Class>` invocations,
  one class at a time. Never background a test run.
  `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/<Class> test`
- **Baseline from main's latest code-carrying CI run** (run `34062543801`, the build-15
  bump, 2026-09-06): unit **2082** (1 skipped), UI **62**. Each task states its expected
  delta. Two PRs branched from the same base can both be green and still merge red; the
  owner's "Update branch" between merges is the guard.
- **Straggler grep covers all three targets**: `grep -rn <token> Raconte RaconteTests
  RaconteUITests docs CLAUDE.md` for every deleted or renamed symbol, and drive present-tense
  hits to zero. For prose, grep a single word that cannot wrap.
- Source-scanning tests strip comments before matching (`RaconteTests/SourceScanning.swift`).
- Every test written here must be shown RED first (run it before the production change,
  or `git stash` the production change and run it), and the RED reason must be the right one.
- Prefer `.notice` over `.info` for any log the owner may read back.
- No `Image` in a macOS `Menu` label; `.sheet`/`.fileImporter` only on a screen's outer view.
- Test fixtures need REAL ULIDs (`ULID.make()` or the 26-char constants the existing suites
  use); short fake ids parse to nil and skip the code under test.
- Do not touch `Raconte/Capture/AudioEngineRecorder*`, the PCM tap, or `CaptureMachine`.
- Commit messages end with the session attribution trailer the harness supplies.
- Never read the owner's real container. Every test uses a temp container root.

---

## PR 1 — sync land-or-park: `feat/sync-land-or-park`

Branch from `main`. Closes #85, #91.

Design summary (from the research): the four asset-arrival guards live in
`Raconte/Sync/SyncIngest.swift` — `ingestAudio` 1691-1716, `ingestLiveLog` 1737-1756,
`ingestRevision` 1797-1821, `ingestImage` 2429-2453 — each a compound `guard` that logs one
undifferentiated reason and returns. `CKSyncEngine` never redelivers, so the return is
permanent loss. The existing park machinery (`parkRevision`, `parkImage`, staging
`pending-*.json`) parks CONTENT and cannot help when the asset bytes are what is missing.
Nothing persists a bare record NAME, and the engine has no per-record fetch
(`fetchNow()` is a token-based zone fetch that has already advanced past the record).
So: (1) a durable parked-names file in `SyncBookkeepingStore`; (2) each sub-cause parks;
(3) a new engine verb refetches parked names on launch and foreground and re-runs them
through `acceptRemote`; a clean ingest unparks. For #91, `handleFailedSaves`
(`CloudEngineControl.swift:581-660`) is private on a class the suite never constructs, so
the resend decision is extracted into a pure planner and tested there.

### Task 1: Durable parked record names in the bookkeeping store (#85, part 1)

**Files:**
- Modify: `Raconte/Sync/SyncBookkeeping.swift` (actor `SyncBookkeepingStore`, ~188 lines; `wipe()` at 129, `AtomicFile.replace` helper at 169-173)
- Test: `RaconteTests/SyncBookkeepingTests.swift`

**Interfaces:**
- Consumes: `AtomicFile.replace(at:writing:)`, `CaptureCoding.encoder()/decoder()`.
- Produces (Tasks 2 and 3 rely on these exact names):

```swift
struct ParkedRecord: Codable, Equatable, Sendable {
    var reason: String
    var attempts: Int
    var firstParkedAt: Date
    var lastAttemptAt: Date?
}

extension SyncBookkeepingStore {
    /// `sync/parked.json`. Keys are record names (`SyncRecordName.rawValue`).
    func parkedRecords() -> [String: ParkedRecord]
    /// Idempotent: a second park of the same name keeps `firstParkedAt` and `attempts`,
    /// replaces `reason`.
    func park(_ recordName: String, reason: String)
    func unpark(_ recordName: String)
    /// Increments `attempts`, stamps `lastAttemptAt`. No-op for an unparked name.
    func noteRetryAttempt(_ recordName: String)
}
```

- [ ] **Step 1: Write the failing tests** in `RaconteTests/SyncBookkeepingTests.swift`, following that file's existing temp-container fixture (a `SyncBookkeepingStore(containerRoot:)` on a `temporaryDirectory` root, removed in tearDown). Inject the clock the way the store already takes it if it has a `now:` seam; if it does not, add `now: @escaping @Sendable () -> Date = { Date() }` to its init.

```swift
    func testParkedRecordsStartEmpty() async {
        let store = makeStore()
        let parked = await store.parkedRecords()
        XCTAssertTrue(parked.isEmpty)
    }

    func testParkRoundTripsThroughDiskAndSurvivesANewStoreInstance() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: { t0 })
        await store.park("audio-01ABC", reason: "missing sha256 field")
        let reopened = makeStore(now: { t0 })
        let parked = await reopened.parkedRecords()
        XCTAssertEqual(parked["audio-01ABC"],
                       ParkedRecord(reason: "missing sha256 field", attempts: 0,
                                    firstParkedAt: t0, lastAttemptAt: nil))
    }

    func testParkingTwiceKeepsFirstParkedAtAndAttemptsButReplacesTheReason() async {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: { clock })
        await store.park("audio-01ABC", reason: "first")
        await store.noteRetryAttempt("audio-01ABC")
        clock += 60
        await store.park("audio-01ABC", reason: "second")
        let record = await store.parkedRecords()["audio-01ABC"]
        XCTAssertEqual(record?.reason, "second")
        XCTAssertEqual(record?.attempts, 1)
        XCTAssertEqual(record?.firstParkedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testNoteRetryAttemptIncrementsAndStampsOnlyParkedNames() async {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: { clock })
        await store.park("a", reason: "r")
        clock += 5
        await store.noteRetryAttempt("a")
        await store.noteRetryAttempt("never-parked")
        let parked = await store.parkedRecords()
        XCTAssertEqual(parked["a"]?.attempts, 1)
        XCTAssertEqual(parked["a"]?.lastAttemptAt, clock)
        XCTAssertNil(parked["never-parked"])
    }

    func testUnparkRemovesOnlyThatName() async {
        let store = makeStore()
        await store.park("a", reason: "r")
        await store.park("b", reason: "r")
        await store.unpark("a")
        let parked = await store.parkedRecords()
        XCTAssertEqual(Set(parked.keys), ["b"])
    }

    func testWipeClearsParkedRecords() async {
        let store = makeStore()
        await store.park("a", reason: "r")
        await store.wipe()
        let parked = await store.parkedRecords()
        XCTAssertTrue(parked.isEmpty)
    }
```

Note on `clock`: Swift 6 will reject a captured `var` in a `@Sendable` closure. Use the
file's existing clock idiom if it has one; otherwise a tiny `final class Clock: @unchecked
Sendable { var now: Date }` passed as `{ clock.now }`.

- [ ] **Step 2: Run `-only-testing:RaconteTests/SyncBookkeepingTests` → RED** on "no member `parkedRecords`".

- [ ] **Step 3: Implement** in `SyncBookkeeping.swift`: add `ParkedRecord`; a `parkedURL` = `syncRoot/parked.json`; `parkedRecords()` decodes (absent file → `[:]`, undecodable → `[:]` plus a `.notice` log naming the file — bookkeeping is a disposable cache, and the name list is only a retry hint); the three mutators read-modify-write through `AtomicFile.replace` with `CaptureCoding.encoder()`. `wipe()` already removes the whole `sync/` directory, so it needs no change — the test just pins it.

- [ ] **Step 4: Run the class → GREEN (+6). Commit:**

```bash
git add Raconte/Sync/SyncBookkeeping.swift RaconteTests/SyncBookkeepingTests.swift
git commit -m "feat(sync): durable parked record names in the bookkeeping store (#85)"
```

### Task 2: Split the asset-arrival guards; park each sub-cause; unpark on a clean ingest (#85, part 2)

**Files:**
- Modify: `Raconte/Sync/SyncIngest.swift` — `ingestAudio` 1686-1720, `ingestLiveLog` 1732-1760, `ingestRevision` 1792-1825, `ingestImage` 2424-2455 (line numbers as of `f406b276`; re-locate by function name)
- Modify: `Raconte/Sync/IngestDropReason.swift` (35 lines)
- Test: `RaconteTests/IngestDropReasonTests.swift`, `RaconteTests/SyncEntryIngestTests.swift`, `RaconteTests/SyncImageIngestTests.swift`

**Interfaces:**
- Consumes: Task 1's `park(_:reason:)`, `unpark(_:)` on `bookkeeping`.
- Produces: `IngestDropReason.image(_ record: CKRecord) -> String?`; every asset-arrival refusal in the four ingest functions calls `await bookkeeping.park(record.recordID.recordName, reason:)` with a distinct reason string per sub-cause; every successful persist in those four functions ends with `await bookkeeping.unpark(record.recordID.recordName)`. Reason strings (Task 3's tests grep for them): `"missing file asset"`, `"asset has no local fileURL"`, `"missing sha256 field"`, `"missing entryRef"`, `"entryRef is not an entry name"`, `"asset bytes unreadable"`, `"sha256 mismatch"`.

- [ ] **Step 1: Write the failing tests.**

In `IngestDropReasonTests.swift` (fixture style there: a real builder, then knock a field out):

```swift
    func testAnImageRecordWithoutItsFileAssetNamesThatField() throws {
        let record = try imageRecordFixture()          // build via SyncRecordBuilders.imageRecord(...) over a scratch file, mirroring audioRecord at :37
        record[SyncChildAssetField.file] = nil
        XCTAssertEqual(IngestDropReason.image(record), "missing file asset")
    }

    func testAnImageRecordWithoutItsSHA256NamesThatField() throws {
        let record = try imageRecordFixture()
        record[SyncChildAssetField.sha256] = nil
        XCTAssertEqual(IngestDropReason.image(record), "missing sha256 field")
    }
```

(Check `RemoteImageFields(record:)` at `SyncIngest.swift:208` for the image record's actual field keys and use those; the sha/file keys may be image-specific.)

In `SyncEntryIngestTests.swift`, next to `testASha256MismatchedAudioIsRefusedAtArrivalAndLeavesThePreviouslyPersistedEntryPieceIntact` (:497), using that test's fixture (`writeTempFile`, `audioRecord`, the exchange on a throwaway `containerRoot`, and its `SyncBookkeepingStore`):

```swift
    func testAnAudioRecordMissingItsSHA256IsParkedNotDropped() async throws {
        let record = try audioRecord(captureID: captureID, bytes: Data("abc".utf8))
        record[SyncChildAssetField.sha256] = nil
        await exchange.acceptRemote(record)
        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked[record.recordID.recordName]?.reason, "missing sha256 field")
    }

    func testASha256MismatchedAudioIsParked() async throws {
        let record = try audioRecord(captureID: captureID, bytes: Data("abc".utf8))
        record[SyncChildAssetField.sha256] = String(repeating: "0", count: 64)
        await exchange.acceptRemote(record)
        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked[record.recordID.recordName]?.reason, "sha256 mismatch")
    }

    func testACleanAudioIngestUnparksThatName() async throws {
        let record = try audioRecord(captureID: captureID, bytes: Data("abc".utf8))
        await bookkeeping.park(record.recordID.recordName, reason: "missing sha256 field")
        await exchange.acceptRemote(record)
        let parked = await bookkeeping.parkedRecords()
        XCTAssertNil(parked[record.recordID.recordName])
    }

    func testALiveLogMissingItsFileAssetIsParked() async throws {
        let record = try liveLogRecord(captureID: captureID, bytes: Data("{}\n".utf8))
        record[SyncChildAssetField.file] = nil
        await exchange.acceptRemote(record)
        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked[record.recordID.recordName]?.reason, "missing file asset")
    }

    func testARevisionWithAnUnreadableEntryRefIsParked() async throws {
        // Build via the revision fixture used by SyncRevisionTests; replace entryRef with a
        // reference whose name is not an entry name (e.g. the audio name).
        ...
        XCTAssertEqual(parked[record.recordID.recordName]?.reason, "entryRef is not an entry name")
    }
```

In `SyncImageIngestTests.swift`, one test: an image record with its file asset removed is parked with `"missing file asset"` (reuse that suite's builders).

If the fixture cannot produce a given sub-cause (e.g. `fileURL == nil` — a `CKAsset` built from a URL always has one), do not fake it: leave that branch covered by the reason-table test only and say so in the task report.

- [ ] **Step 2: Run the three classes → RED** (parked is empty; `IngestDropReason.image` undefined).

- [ ] **Step 3: Implement.** In each of the four functions, replace the compound `guard` with sequential guards, one per condition, each: `log.notice("sync: fetched <Family> \(name) parked — <reason>")`, `await bookkeeping.park(name, reason: "<reason>")`, `return`. Same for the unreadable-bytes and sha-mismatch sites. `IngestDropReason.childAsset/.revision` stay as the observability table but must agree with the new strings — update them to return exactly the strings above, and add `image(_:)`. Remove every `?? "guard/reason drift"` fallback that becomes unreachable. After each family's successful persist (the last write in the happy path), `await bookkeeping.unpark(name)`. `bookkeeping` is already reachable from `resolveUnknownItem` (`SyncIngest.swift:1566`) — use the same property.

- [ ] **Step 4: Run `IngestDropReasonTests`, `SyncEntryIngestTests`, `SyncImageIngestTests`, `SyncRevisionTests` → GREEN (+8 or +9). Full unit suite once. Commit:**

```bash
git commit -am "fix(sync): asset-arrival refusals park the record name instead of dropping it (#85)"
```

### Task 3: Refetch parked records on launch and foreground (#85, part 3)

**Files:**
- Modify: `Raconte/Sync/CloudEngineControl.swift` — protocol `CloudEngineControl` (16-293; verbs listed near 24), `CloudKitEngineControl` (the `sentRecordZoneChanges`/`fetchedRecordZoneChanges` event branches near 537; `fetchNow()` 429-437)
- Modify: `Raconte/Sync/SyncCoordinator.swift` — `launch()` 63-69, `foregrounded()` 121-123
- Modify: `RaconteTests/SyncCoordinatorTests.swift` — `FakeCloudEngine` actor at :525
- Test: `RaconteTests/SyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 1's `parkedRecords()`, `noteRetryAttempt(_:)`, `unpark(_:)`.
- Produces:

```swift
// on protocol CloudEngineControl
/// Fetches these records by name from the private database and runs each through the
/// same `acceptRemote` path a zone fetch uses. A name the server no longer has is
/// reported back so the caller can stop asking.
func refetch(recordNames: [String]) async -> RefetchOutcome

struct RefetchOutcome: Equatable, Sendable {
    var delivered: [String]        // names handed to acceptRemote
    var goneFromServer: [String]   // CKError.unknownItem for that name
    var failed: [String]           // any other error; stays parked, retried next time
}

// on SyncCoordinator
/// Called at the end of launch() and from foregrounded(). Reads the parked names,
/// stamps an attempt on each, refetches, and unparks the ones the server says are gone
/// (with a .notice naming them — that is the terminal case, never silent).
func retryParked() async
```

- [ ] **Step 1: Write the failing tests** in `SyncCoordinatorTests.swift`. Extend `FakeCloudEngine` with `var refetchCalls: [[String]] = []`, `var refetchOutcome = RefetchOutcome(delivered: [], goneFromServer: [], failed: [])`, and the verb implementation that appends and returns the outcome. Then:

```swift
    func testLaunchRefetchesParkedNames() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()   // this file's factory
        await bookkeeping.park("audio-01ABC", reason: "sha256 mismatch")
        await coordinator.launch()
        let calls = await engine.refetchCalls
        XCTAssertEqual(calls, [["audio-01ABC"]])
        let parked = await bookkeeping.parkedRecords()
        XCTAssertEqual(parked["audio-01ABC"]?.attempts, 1)
    }

    func testForegroundedRefetchesParkedNames() async throws { /* same shape via foregrounded() */ }

    func testNothingParkedMeansNoRefetchCall() async throws {
        let (coordinator, engine, _) = try await makeCoordinator()
        await coordinator.foregrounded()
        let calls = await engine.refetchCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testANameGoneFromTheServerIsUnparked() async throws {
        let (coordinator, engine, bookkeeping) = try await makeCoordinator()
        await bookkeeping.park("audio-01ABC", reason: "sha256 mismatch")
        await engine.setRefetchOutcome(RefetchOutcome(delivered: [], goneFromServer: ["audio-01ABC"], failed: []))
        await coordinator.retryParked()
        let parked = await bookkeeping.parkedRecords()
        XCTAssertNil(parked["audio-01ABC"])
    }

    func testAFailedRefetchStaysParked() async throws { /* failed: ["audio-01ABC"] → still parked, attempts == 1 */ }
```

- [ ] **Step 2: Run the class → RED** (no `refetch` on the protocol).

- [ ] **Step 3: Implement.** Protocol verb + `RefetchOutcome` in `CloudEngineControl.swift`. `CloudKitEngineControl.refetch`: build `CKRecord.ID`s in the sync zone (the zone ID the engine already uses — find it where `fetchNow` or the record builders name it), call `database.records(for:)` (async, returns `[CKRecord.ID: Result<CKRecord, Error>]`), and for each success call the exact same exchange method the `fetchedRecordZoneChanges` branch calls for a modified record; `.unknownItem` → `goneFromServer`; anything else → `failed`. No CloudKit type crosses the protocol (names in, plain outcome out) — that invariant is documented in the file header and `SyncCoordinatorTests.swift:7-12`. The no-op engine implementation (the one used when sync is unavailable, near :192) returns an empty outcome. `SyncCoordinator.retryParked()` per the contract; `launch()` calls it after `fetchNow()`; `foregrounded()` calls it after `fetchNow()`.

- [ ] **Step 4: Run `SyncCoordinatorTests` → GREEN (+5). Full unit suite. iOS compile check. Commit:**

```bash
git commit -am "feat(sync): refetch parked records on launch and foreground; gone-from-server unparks loudly (#85)"
```

### Task 4: Resend a NOT_FOUND child alongside its recreated Entry (#91)

**Files:**
- Create: `Raconte/Sync/UnknownItemResend.swift`
- Modify: `Raconte/Sync/CloudEngineControl.swift` — `handleFailedSaves` 581-660 (the `.recreate` branch 605-619)
- Modify: `Raconte/Sync/SyncRecordName.swift` (enum at 32-39; no parent accessor today)
- Create: `RaconteTests/UnknownItemResendTests.swift`
- Test: `RaconteTests/SyncRecordNameTests.swift`

**Interfaces:**
- Consumes: `SyncRecordName` cases `.entry(captureID:)`, `.audio(captureID:)`, `.liveLog(captureID:)`, `.markerStream(captureID:deviceID:)`, `.image(captureID:imageID:)`, `.revision(id:)`, `.journal…`; `SyncChildAssetField.entryRef`.
- Produces:

```swift
extension SyncRecordName {
    /// The Entry this child belongs to, for the four cases that carry a captureID.
    /// `.revision` carries only its own id — callers pass the record's entryRef instead.
    var parentEntry: SyncRecordName?
}

enum UnknownItemResend {
    struct Outcome: Equatable, Sendable {
        var name: SyncRecordName
        var hadServerState: Bool        // what resolveUnknownItem returned
        var parent: SyncRecordName?     // name.parentEntry, or the entryRef-derived entry for a revision
    }
    /// Names to resend, parents before children. A child with no archived state is
    /// resent iff its parent Entry is being resent in this same event.
    static func plan(_ outcomes: [Outcome]) -> [SyncRecordName]
}
```

- [ ] **Step 1: Write the failing tests.** `SyncRecordNameTests`: `.audio(captureID: c).parentEntry == .entry(captureID: c)`, same for liveLog/markerStream/image; `.revision(id:).parentEntry == nil`; `.entry` and journal names → nil. `UnknownItemResendTests` (pure, no fixture; mint ids with `ULID.make()`):

```swift
    func testARecordWithServerStateIsResent() {
        let e = SyncRecordName.entry(captureID: c)
        XCTAssertEqual(UnknownItemResend.plan([.init(name: e, hadServerState: true, parent: nil)]), [e])
    }
    func testAChildWithoutServerStateWhoseParentIsResentIsResentAfterIt() {
        let e = SyncRecordName.entry(captureID: c), a = SyncRecordName.audio(captureID: c)
        let plan = UnknownItemResend.plan([
            .init(name: a, hadServerState: false, parent: e),   // child FIRST in the event
            .init(name: e, hadServerState: true, parent: nil),
        ])
        XCTAssertEqual(plan, [e, a])
    }
    func testAChildWithoutServerStateWhoseParentIsNotInTheEventIsLeftForReconcile() { /* plan == [] */ }
    func testARevisionUsesTheEntryRefDerivedParent() { /* .revision(id:) with parent: e, e resent → [e, r] */ }
    func testAParentThatItselfHadNoServerStateDoesNotCarryItsChild() { /* both false → [] */ }
```

- [ ] **Step 2: Run both classes → RED.**

- [ ] **Step 3: Implement.** `plan`: first pass collects names with `hadServerState`; second pass appends children whose `parent` is in that set, in event order; return parents-first (stable: all first-pass names in event order, then second-pass). In `handleFailedSaves`, collect an `Outcome` per `.recreate` failure instead of appending inline (parent for a revision: `failure.record[SyncChildAssetField.entryRef]` → `SyncCloudIdentifiers.name(of: ref.recordID)`; keep the existing `.retry`/conflict appends as they are), then `toResend += UnknownItemResend.plan(outcomes)`. Keep the existing `.notice` for a child left to reconcile, but only when the plan did not pick it up.

- [ ] **Step 4: Run `SyncRecordNameTests`, `UnknownItemResendTests`, `SaveFailureDispositionTests`, `SyncUnknownItemTests`, `SyncChildHoldbackTests` → GREEN (+10). `xcodegen generate` was needed for the two new files — confirm the unit count moved. Full unit suite; iOS compile. Commit:**

```bash
git commit -am "fix(sync): a NOT_FOUND child is resent with its recreated Entry in the same event (#91)"
```

Push, open PR 1 with `--body-file` (`Closes #85`, `Closes #91`). The body states the
residual for #91: a child whose Entry is NOT in the same failure event still waits for the
launch-time reconcile; a debounced reconcile-on-foreground was the issue's other option and
is not built (the scan hashes every m4a — seconds on a real corpus).

**Whole-branch review (Opus):** land-or-park on every refusal in the four functions (grep
`return` inside each guard and confirm a `park` precedes it); no CloudKit type crosses the
engine protocol; `unpark` sits after the LAST write of each happy path, not before.

---

## PR 2 — repair route for an unreadable entry sidecar: `feat/81-unreadable-entry-repair`

Branch from `main`. Closes #81.

Design summary: `.metadataUnreadable` is produced only by `LibraryScanner.metadata(for:)`
(`LibraryScanner.swift:138-145`) and consumed by the corpus-wide veto in
`LibraryScreenModel.emptinessVerdict(forJournal:)` (`:642-643`). The Debug screen is
compiled out of Release builds, so the route goes on the **Trash screen**. Quarantine is a
whole-directory `rename(2)` out of `captures/` into a new `<container>/quarantine/` sibling
that (a) `SyncTreeScanner` never lists (it lists only `capturesRoot`'s children,
`SyncTreeScanner.swift:13,79`), (b) `StagedRemover.purge()` never touches, and (c) sync
never treats as a delete (deletes are explicit via `noteLocalDelete`, never inferred from a
scan — `SyncPlanner.swift:12-16`). The audio is preserved; the owner can recover it by hand.
No silent deletion anywhere.

### Task 5: `quarantine(captureID:)`, `unreadableEntries`, and the model action (#81, core)

**Files:**
- Modify: `Raconte/Library/AppContainer.swift` (add `quarantineDirectoryName`, `quarantineRoot(containerRoot:)`, `quarantineURL(containerRoot:name:)` beside the trash-pending trio at 85-90; add the line to the tree comment at 11-17)
- Modify: `Raconte/Library/StagedRemoval.swift` (`StagedRemover` 23; `stage` 39; `purge` 67)
- Modify: `Raconte/Library/LibraryScreenModel.swift` (`trashed` 73, `allEntries` 77, `emptinessVerdict` 637)
- Test: `RaconteTests/StagedRemovalTests.swift`, `RaconteTests/LibraryScreenModelTests.swift`, `RaconteTests/SyncTreeScannerTests.swift`

**Interfaces:**
- Produces:

```swift
extension StagedRemover {
    /// One-way move of `captures/<captureID>/` to `<container>/quarantine/<ULID>-<captureID>/`.
    /// Same rename(2) as `stage`, different destination; `purge()` never visits quarantine.
    func quarantine(captureID: String) throws -> String   // returns the quarantine directory name
}

extension LibraryScreenModel {
    /// Live and trashed items whose sidecar could not be read. Empty in a healthy archive.
    var unreadableEntries: [EntryListItem] { get }
    /// Quarantines the capture and rescans. Throws what `quarantine` throws.
    func quarantineUnreadable(captureID: String) async throws
}
```

- [ ] **Step 1: Write the failing tests.** `StagedRemovalTests` (mirror `stage`'s tests at :62-:251):

```swift
    func testQuarantineMovesTheWholeCaptureDirectoryOutOfCaptures() throws {
        // plant captures/<id>/final/recording.m4a + a garbage entry.json
        let name = try remover.quarantine(captureID: id)
        XCTAssertFalse(fm.fileExists(atPath: capturesRoot.appendingPathComponent(id).path))
        let moved = AppContainer.quarantineURL(containerRoot: containerRoot, name: name)
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent("final/recording.m4a").path))
        XCTAssertTrue(name.hasSuffix("-\(id)"))
    }
    func testQuarantineOfAMissingCaptureThrowsCaptureDirectoryMissing() throws { ... }
    func testPurgeLeavesQuarantineAlone() throws {
        _ = try remover.quarantine(captureID: id)
        _ = try remover.stage(captureID: otherID)
        _ = remover.purge()
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: AppContainer.quarantineRoot(containerRoot: containerRoot).path).count, 1)
    }
```

`LibraryScreenModelTests`, next to `testDeleteJournalRefusesWhileAnyEntrysSidecarIsUnreadable` (:636) and reusing its unreadable-sidecar planting:

```swift
    func testUnreadableEntriesListsExactlyTheCapturesWithAnUnreadableSidecar() async { /* 1 unreadable + 1 healthy → ids == [unreadable] */ }
    func testQuarantiningTheUnreadableEntryUnblocksJournalDeletion() async throws {
        // plant journal J (empty apart from the unreadable capture filed nowhere), verdict == .blockedHard
        try await model.quarantineUnreadable(captureID: badID)
        XCTAssertTrue(model.unreadableEntries.isEmpty)
        XCTAssertNotEqual(model.emptinessVerdict(forJournal: journalID), .blockedHard)
        // and the audio still exists under quarantine/
    }
```

`SyncTreeScannerTests`: `testAQuarantinedCaptureIsInvisibleToTheScan` — plant a full capture, move it with `StagedRemover.quarantine`, scan → no artifact names that captureID.

- [ ] **Step 2: Run the three classes → RED.**

- [ ] **Step 3: Implement.** `AppContainer`: `quarantineDirectoryName = "quarantine"` + the two URL helpers. `StagedRemover.quarantine`: copy `stage`'s body with the destination swapped; it creates `quarantine/` if absent. Exclude `quarantine/` from nothing — it is the owner's audio and must be backed up (do NOT add the `isExcludedFromBackup` flag `stage` sets at 50-53). `LibraryScreenModel.unreadableEntries`: `(allEntries + trashed).filter { $0.degradations.contains(.metadataUnreadable) }`. `quarantineUnreadable`: `try stagedRemover.quarantine(captureID:)` then `await rescan()`.

- [ ] **Step 4: Run the three classes → GREEN (+6). Full unit suite. Commit:**

```bash
git commit -am "feat(library): quarantine an unreadable-sidecar capture out of captures/, never deleting it (#81)"
```

### Task 6: "Unreadable entries" section on the Trash screen (#81, UI)

**Files:**
- Modify: `Raconte/Library/UI/TrashView.swift` (List `trash.list` 84; empty state `trash.empty` 309; dialogs at 207/246/280 are the pattern)
- Modify: `Raconte/Capture/Debug/UITestSupport.swift` (`UITestEntrySeed.seedIfRequested` :34 — add a seed for `RACONTE_UITEST_SEED_UNREADABLE_ENTRY`)
- Create: `RaconteUITests/TrashRepairUITests.swift`
- Test: `RaconteTests/SourceScanning`-style pin in a new `RaconteTests/TrashViewSourceTests.swift` is NOT needed if the UI test lands; write it only if the UI test cannot be seeded.

**Interfaces:**
- Consumes: Task 5's `unreadableEntries`, `quarantineUnreadable(captureID:)`.
- Produces accessibility identifiers: `trash.unreadable.section`, `trash.unreadable.row` (one per item, label = the capture's `capturedAt` date + " — entry settings unreadable"), `trash.unreadable.quarantine` (button per row), confirmation dialog primary button `trash.unreadable.confirm`.

- [ ] **Step 1: Write the failing UI test.** Seed: in `UITestSupport.swift`, when `RACONTE_UITEST_SEED_UNREADABLE_ENTRY == "1"`, write a complete entry the way `seedIfRequested` does and then overwrite its `entry.json` with the bytes `not json`. Test:

```swift
final class TrashRepairUITests: XCTestCase {
    func testAnUnreadableEntryCanBeQuarantinedFromTrash() {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = UUID().uuidString
        app.launchEnvironment["RACONTE_UITEST_SEED_UNREADABLE_ENTRY"] = "1"
        app.launch()
        openPlace(app, "sidebar.trash")
        let row = app.otherElements["trash.unreadable.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["trash.unreadable.quarantine"].firstMatch.tap()
        app.buttons["trash.unreadable.confirm"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }
}
```

(`waitForNonExistence` exists on Xcode 26's XCUIElement; if not, use the `waitUntil` idiom from `NavigationUITests`.) The row identifier must be on the row's container with `.accessibilityElement(children: .contain)` — a container identifier otherwise overwrites its children's (repo memory).

- [ ] **Step 2: `xcodegen generate`; run `-only-testing:RaconteUITests/TrashRepairUITests` → RED** on the missing row.

- [ ] **Step 3: Implement.** In `TrashView`, above the trashed list (and shown even when `trashed` is empty — the `trash.empty` state must not hide it): `if !model.unreadableEntries.isEmpty { Section { ForEach … } header: { Text("Unreadable entries") } footer: { Text("These entries' settings files could not be read. Quarantine moves the whole entry, audio included, out of the library into the app's quarantine folder. Nothing is deleted.") } }`. Confirmation via `.confirmationDialog` attached to the outer `List`, never to the Section. On confirm: `Task { try? await model.quarantineUnreadable(captureID:) }` with a failure surfaced as an alert row, not swallowed.

- [ ] **Step 4: Run the UI class → GREEN (+1 UI). Run `BulkSelectUITests` too (it drives the Trash screen) to confirm nothing regressed. iOS compile; macOS unit suite. Commit:**

```bash
git commit -am "feat(trash): Unreadable entries section with a quarantine action (#81)"
```

Push, open PR 2 (`Closes #81`). Body: the quarantine folder path
(`~/Library/Application Support/Raconte/quarantine/` on the Mac, the app container on iOS),
what it holds, and that recovery is manual by design.

---

## PR 3 — small debt: `feat/small-debt-2026-09-06`

Branch from `main`. Closes #71. Comments on #67 (items 2, 3, 4) — does NOT close it.

### Task 7: Flag entries dated outside their journal's span (#71)

**Files:**
- Modify: `Raconte/Library/JournalSpan.swift` (`contains` at 33)
- Modify: `Raconte/Library/EntryListItem.swift` (`journal` 108, `effectiveDate` 199)
- Modify: `Raconte/Library/UI/LibraryView.swift` (`LibraryEntryRow` 548; marker HStack 648-693, siblings `library.row.backdatedMarker` 672 and `library.row.degradedMarker` 680)
- Modify: `Raconte/Library/UI/EntryDetailView.swift` (body VStack at 124-132, above `transcriptSection`)
- Test: `RaconteTests/JournalSpanTests.swift`, `RaconteTests/EntryListItemTests.swift`, `RaconteTests/SourceScanning`-based pin in `RaconteTests/EntryListItemTests.swift`

**Interfaces:**

```swift
extension JournalSpan {
    /// Flagged, never blocked (owner ruling 4, 2026-08-18). A nil span makes no claim.
    static func flags(_ span: JournalSpan?, _ date: Date, calendar: Calendar = .gregorianCurrent) -> Bool
}
extension EntryListItem {
    var isDatedOutsideJournalSpan: Bool   // JournalSpan.flags(journal?.span, effectiveDate)
}
```

- [ ] **Step 1: Failing tests.** `JournalSpanTests`: nil span → false; date inside → false; date before start → true; date after an open-ended (`end == nil`) span's start → false; year-precision end covers 31 Dec 23:59:59 (reuse the existing containment fixtures at :59-:145). `EntryListItemTests`: an item with a journal whose span is 1998 and an `effectiveDate` in 2001 → `isDatedOutsideJournalSpan == true`; same item with `journal == nil` → false. Source pin (comments stripped, `SourceScanning`): `LibraryView.swift` contains `"library.outOfSpan"` and `EntryDetailView.swift` contains `"detail.outOfSpan"`.

- [ ] **Step 2: Run → RED.**

- [ ] **Step 3: Implement.** The predicate and the item property. `LibraryEntryRow`: beside `backdatedMarker`, `if item.isDatedOutsideJournalSpan { Image(systemName: "calendar.badge.exclamationmark").accessibilityLabel("Dated outside this journal's range").accessibilityIdentifier("library.outOfSpan") }`. `EntryDetailView`: as the first child of the body VStack, `if item.isDatedOutsideJournalSpan, let journal = item.journal { Text("Dated outside \(journal.name)'s range\(journal.span.map { " (\($0.displayText))" } ?? "").").font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("detail.outOfSpan") }` — use whatever display formatter `JournalSpan` already has (grep `JournalDateLine`/`JournalSpanEditor` for the text form); on macOS keep the 16 pt floor (`.callout` is 12 pt there — use `.body`).

- [ ] **Step 4: Run `JournalSpanTests`, `EntryListItemTests`, `LibraryScreenModelTests` → GREEN (+8). Commit:**

```bash
git commit -am "feat(library): flag entries dated outside their journal's span, never blocked (#71)"
```

### Task 8: A background journals pull must not pop the entry being read (#67 item 2)

**Files:**
- Modify: `Raconte/App/Place.swift` (`PlaceRouting.resolve` 161-169; `AppRouter.select` 206; `detailPath` 191)
- Modify: `Raconte/App/ContentView.swift` (`.onChange(of: services.library.journals)` 129-134)
- Test: `RaconteTests/PlaceRoutingTests.swift` (existing pins at 52, 58, 67)

**Interfaces:**

```swift
extension PlaceRouting {
    struct Reroute: Equatable { var place: Place; var detailPath: [EntryRoute] }   // use the path element type detailPath already holds
    /// Same place → unchanged. Place vanished with nothing pushed → resolve as today
    /// (.capture, path cleared). Place vanished while something is pushed → .allEntries
    /// with the path PRESERVED, so the entry being read stays on screen.
    static func reroute(_ place: Place, journals: [Journal], detailPath: [EntryRoute]) -> Reroute
}
extension AppRouter {
    func apply(_ reroute: PlaceRouting.Reroute)   // sets place and detailPath directly, no select()
}
```

- [ ] **Step 1: Failing tests** in `PlaceRoutingTests`: (a) journal present → reroute returns the same place and path; (b) journal missing, empty path → `.capture`, `[]` (matches the :67 pin); (c) journal missing, non-empty path → `.allEntries` with the same path; (d) `.allEntries` with a path when journals change → unchanged.

- [ ] **Step 2: RED. Step 3: implement; `ContentView` onChange becomes `let r = PlaceRouting.reroute(router.place, journals: journals, detailPath: router.detailPath); if r.place != router.place { router.apply(r) }`. Update the rationale comment at 113-128 to say why the path survives.**

- [ ] **Step 4: `PlaceRoutingTests`, `AppRouterCommandTests` GREEN (+4). Commit `fix(nav): a journals pull that removes the current journal reroutes to All Entries without popping the entry (#67 item 2)`.**

### Task 9: Sidebar containment and one clock formatter (#67 items 3 and 4)

**Files:**
- Modify: `Raconte/App/SidebarView.swift` (`captureLiveRow` 87-90 + doc 79-86; `rows` 92-107; `SidebarRowView` 116)
- Modify: `Raconte/Library/LibraryScreenModel.swift` (`dateLine(forJournal:)` 328, `dateRange(forJournal:)` 322, `rescan()` 253)
- Modify: `Raconte/Capture/CaptureCoordinator.swift` (`formatDuration` 883)
- Modify: `Raconte/Capture/UI/RecStatusLine.swift` (`RecFormat.clock` 8)
- Test: `RaconteTests/JournalDateLineTests.swift`, `RaconteTests/CaptureSidebarRowTests.swift`, `RaconteTests/CaptureCoordinatorTests.swift`, a source pin in `RaconteTests/SidebarRowInsetTests.swift`

**Interfaces:**

```swift
extension LibraryScreenModel {
    /// Recomputed once per rescan (one pass over allEntries), read by the sidebar.
    private(set) var journalDateLines: [String: String]   // journalID → date line; absent = no line
}
struct CaptureLiveBadge: View { }   // reads services.capture.coordinator itself; the ONLY view that reads .elapsed
```

- [ ] **Step 1: Failing tests.** `JournalDateLineTests`: after `rescan()` on a 3-journal corpus, `journalDateLines[j.id] == model.dateLine(forJournal: j.id)` for each, and a journal with no entries is absent. `CaptureCoordinatorTests`: `CaptureCoordinator.formatDuration(3661) == RecFormat.clock(3661)` and `formatDuration(3600) == "1:00:00"` (today it reads `60:00`). Source pin (comments stripped): in `SidebarView.swift` the token `.elapsed` occurs zero times; it occurs in `CaptureLiveBadge.swift` (new file, `Raconte/App/`).

- [ ] **Step 2: RED. Step 3: implement.** `journalDateLines` filled at the end of `rescan()` from a single grouped pass (`Dictionary(grouping: allEntries, by: \.journalID)`), `dateLine(forJournal:)` reads it. `rows` takes the line from the dictionary. `CaptureLiveBadge` owns the `phase`/`elapsed` read and renders `CaptureSidebarRow.make(phase:elapsed:)`'s text; `SidebarRowView` for the Capture row embeds it. `formatDuration` delegates to `RecFormat.clock`. Rewrite the "accepted cost" comment at 79-86 to describe the containment.

- [ ] **Step 4: `JournalDateLineTests`, `CaptureSidebarRowTests`, `CaptureCoordinatorTests`, `SidebarRowInsetTests`, `PlaceRoutingTests` GREEN (+4). `xcodegen generate` for the new file. Full unit suite; iOS compile. Run `-only-testing:RaconteUITests/NavigationUITests` (it covers the sidebar while recording, :190/:385). Commit `perf(sidebar): contain the live badge; one date-line pass per rescan; one clock formatter (#67 items 3, 4)`.**

Push, open PR 3 (`Closes #71`; body lists #67 items 2, 3, 4 with "done in this PR" — no
close keyword for #67). Post a comment on #67 naming the three items and the PR.

---

## PR 4 — open-format archive export + verifier: `feat/archive-export`

Branch from `main`. No issue closes; the PR body cites `docs/native-rebuild-plan.md:39`
("Export is a v1 acceptance criterion").

Design summary: the archive on disk is already an open format — sorted-key pretty JSON,
JSONL, m4a — so the exporter copies files **byte-for-byte** and adds three derived things:
a human-readable `transcript.md` per entry, a top-level manifest with a sha256 for every
file, and a report. Nothing is re-encoded, so nothing can be lost in translation; the
verifier proves the copy. Package layout (documented in `docs/export-format.md`, Task 13):

```
Raconte-export-<yyyyMMdd-HHmmss>/
  raconte-export.json            # ExportManifest (below); written LAST
  journals.json                  # byte copy of the registry
  journals/<journalID>/cover.jpg # byte copy when present
  entries/<captureID>/
    entry.json                   # byte copy of the sidecar (even if unreadable — bytes are bytes; a warning is recorded)
    capture.json                 # byte copy of manifest.json (renamed: "manifest" is taken)
    audio.m4a                    # byte copy of final/recording.m4a when present
    transcript.md                # DERIVED: frontmatter + current revision's plain text
    revisions/canonical-<n>.json # byte copies; revisions/draft.json when present
    markers/markers.jsonl, markers/markers-<deviceID>.jsonl
    live.jsonl                   # transcript/live.jsonl
    entry-log.jsonl
    images/<id>.<ext>, images/<id>.json   # thumbnails skipped
```

Skipped on purpose: `segments/` (deleted at finalize anyway), `transcript/head.json`
(a cache), `images/thumbnails/`, `trash-pending/`, `quarantine/`, `sync/`.

### Task 10: `ExportManifest` and `ArchiveWalker` (what to copy)

**Files:**
- Create: `Raconte/Export/ExportManifest.swift`
- Create: `Raconte/Export/ArchiveWalker.swift`
- Create: `RaconteTests/ArchiveWalkerTests.swift`
- Reference: `Raconte/Capture/SegmentLayout.swift` (all file names + URL builders 76-250), `Raconte/Library/AppContainer.swift`, `Raconte/Sync/SyncTreeScanner.swift:77-130` (the walk to copy the shape of, minus its exclusions)

**Interfaces:**

```swift
struct FileDigest: Codable, Equatable, Sendable { var sha256: String; var bytes: Int }

struct ExportManifest: Codable, Equatable, Sendable {
    static let format = "raconte-export"
    static let schemaVersion = 1
    var format: String
    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String
    var build: String
    struct Counts: Codable, Equatable, Sendable { var entries: Int; var journals: Int; var files: Int; var bytes: Int }
    var counts: Counts
    struct EntrySummary: Codable, Equatable, Sendable {
        var journalID: String?
        var hasAudio: Bool
        var revisionCount: Int
        var currentRevisionID: String?
        var transcriptCharacterCount: Int
        var sidecarReadable: Bool
    }
    var entries: [String: EntrySummary]     // captureID → summary
    var files: [String: FileDigest]         // package-relative path → digest (EVERY file except this manifest)
    var warnings: [String]
}

struct ExportFile: Equatable, Sendable { var source: URL; var relativePath: String }

enum ArchiveWalker {
    struct Listing: Equatable, Sendable {
        var files: [ExportFile]                 // sorted by relativePath
        var captureIDs: [String]                // sorted
        var journalIDs: [String]
        var warnings: [String]                  // "entries/<id>: no final audio", "entries/<id>: sidecar unreadable", …
    }
    /// Pure listing, no writes. Lists `journals.json`, covers, and every `captures/<ULID>/`
    /// directory's exportable files under the package layout above. A capture directory
    /// whose name is not a well-formed ULID is skipped with a warning.
    static func list(containerRoot: URL) throws -> Listing
}
```

- [ ] **Step 1: Failing tests.** Build a temp container with the `SyncTreeScannerTests` helpers' shape (copy the helpers you need into the new test file; do not import across test files): two captures (one with audio + two revisions + own markers + a foreign marker stream + one image; one with no final audio and a garbage `entry.json`), `journals.json` with one journal and a cover. Assert: `files.map(\.relativePath)` equals the exact expected sorted list (write it out in full in the test); `captureIDs` sorted; the warning strings for the second capture; `segments/`, `head.json`, thumbnails absent; a `captures/not-a-ulid/` directory produces a warning and no files.

- [ ] **Step 2: `xcodegen generate`; run `ArchiveWalkerTests` → RED. Step 3: implement.** Use `SegmentLayout`'s URL builders and names; never hand-spell a file name that `SegmentLayout` already declares. Manifest types are plain Codable; encode with `CaptureCoding.encoder()` (sorted keys, pretty).

- [ ] **Step 4: GREEN (+5). Commit `feat(export): ExportManifest and ArchiveWalker list the exportable archive`.**

### Task 11: `ArchiveExporter` writes the package (copy, derive, hash, manifest last)

**Files:**
- Create: `Raconte/Export/ArchiveExporter.swift`
- Create: `Raconte/Export/TranscriptMarkdown.swift`
- Create: `RaconteTests/ArchiveExporterTests.swift`, `RaconteTests/TranscriptMarkdownTests.swift`
- Reference: `Raconte/Transcription/TranscriptChain.swift` (`ordered` 13, `current` 68, `plainText` 107), `TranscriptRevisionStore.loadChain` (186; a `nonisolated static` read), `Raconte/Sync/SyncTreeScanner.swift:330` (`sha256Hex`; hoist it to a shared `enum SHA256Hex { static func of(_ data: Data) -> String; static func ofFile(at url: URL) throws -> String }` in `Raconte/Export/SHA256Hex.swift` and make `SyncTreeScanner`/`ImageStore` call it — `SyncTreeScannerTests:610/618` must stay green as the proof)

**Interfaces:**

```swift
enum TranscriptMarkdown {
    /// YAML frontmatter (captureID, revisionID, source, createdAt, journalID, originalDate)
    /// then a blank line then the current revision's plain text. Deterministic.
    static func render(captureID: String, journalID: String?, originalDate: String?,
                       revision: TranscriptRevision?) -> String
    /// Splits a rendered document back into (frontmatter lines, body). Used by the verifier.
    static func body(of document: String) -> String
}

struct ArchiveExporter: Sendable {
    init(containerRoot: URL, appVersion: String, build: String,
         now: @escaping @Sendable () -> Date = { Date() })
    struct Report: Equatable, Sendable {
        var packageURL: URL; var counts: ExportManifest.Counts; var warnings: [String]
    }
    /// Assembles `<destination>/Raconte-export-<stamp>.part/`, copies every listed file,
    /// writes transcript.md per entry, hashes every file, writes raconte-export.json LAST,
    /// then renames `.part` away. Throws on any I/O failure and removes the `.part`.
    func export(into destination: URL) async throws -> Report
}
```

- [ ] **Step 1: Failing tests.** `TranscriptMarkdownTests`: render → body round-trips; nil revision renders an empty body; frontmatter keys appear in a fixed order. `ArchiveExporterTests` on the Task 10 fixture: (a) every `ExportFile` from the walker exists in the package with identical bytes (`Data(contentsOf:)` equality); (b) `raconte-export.json` decodes, `files` has one key per package file except itself, each sha256 equals a locally recomputed CryptoKit digest; (c) `transcript.md` body equals `TranscriptChain.plainText(TranscriptChain.current(ordered))` for the two-revision capture; (d) `counts.entries == 2`, `entries[<noAudio>].hasAudio == false`, `sidecarReadable == false` for the garbage sidecar; (e) no `.part` directory remains; (f) an unwritable destination (a file where a directory is expected) throws and leaves nothing behind; (g) the stamp uses the injected clock (`Raconte-export-20260906-233000`).

- [ ] **Step 2: `xcodegen generate`; RED. Step 3: implement.** Copy with `FileManager.copyItem` after creating parent dirs; hash with `Data(contentsOf:options:.mappedIfSafe)` (the m4a can be tens of MB); `sidecarReadable` from `EntryMetadataStore.read(url:)` throwing; revisions via `TranscriptRevisionStore.loadChain`-family static reads — never write anything into the source container (a `nonisolated static` read path is the rule there). Manifest written last with `AtomicFile.replace`.

- [ ] **Step 4: GREEN (+10). Full unit suite; iOS compile. Commit `feat(export): ArchiveExporter writes a checksummed byte-for-byte package with a derived transcript.md`.**

### Task 12: `ArchiveVerifier` reads the package back

**Files:**
- Create: `Raconte/Export/ArchiveVerifier.swift`
- Create: `RaconteTests/ArchiveVerifierTests.swift`

**Interfaces:**

```swift
enum ArchiveVerifier {
    enum Problem: Equatable, Sendable {
        case manifestUnreadable(String)
        case missingFile(String)
        case checksumMismatch(String)
        case unlistedFile(String)
        case transcriptMismatch(captureID: String)
        case countMismatch(field: String, manifest: Int, found: Int)
    }
    struct Report: Equatable, Sendable {
        var checkedFiles: Int; var problems: [Problem]
        var ok: Bool { problems.isEmpty }
    }
    /// Three-answer honesty: a missing file, an unreadable file and a mismatched file
    /// are three different problems, never collapsed.
    static func verify(packageURL: URL) -> Report
}
```

- [ ] **Step 1: Failing tests** (each builds a package with Task 11's exporter on the Task 10 fixture, then mutates it): clean → `ok`, `checkedFiles == manifest.files.count`; flip one byte in `audio.m4a` → `[.checksumMismatch("entries/<id>/audio.m4a")]`; delete a revision file → `.missingFile`; add `entries/<id>/extra.txt` → `.unlistedFile`; edit `transcript.md`'s body → `.transcriptMismatch` (and `.checksumMismatch` for that path — both, in that order: files first, then transcripts); truncate the manifest → `[.manifestUnreadable(...)]` only; delete an entry directory → `.missingFile` per file plus `.countMismatch(field: "entries", …)`.

- [ ] **Step 2: RED. Step 3: implement.** Walk the package with `FileManager.enumerator`, compare to `manifest.files`; recompute `transcript.md` from the package's own `revisions/` via `TranscriptChain` (never from the source container — the verifier must work on a USB stick years later).

- [ ] **Step 4: GREEN (+7). Commit `feat(export): ArchiveVerifier proves the package against its manifest and its own revisions`.**

### Task 13: "Export archive…" on About, entitlement, docs

**Files:**
- Modify: `Raconte/App/AboutView.swift` (List `about.list` 74; sections at 27/35/51/71; doc comment at 6 says read-only — amend it)
- Modify: `Raconte/App/RaconteApp.swift` (`AppServices` at 8 — construct the exporter with `AppContainer.root()` and the About view's version strings; reuse the `BuildInfo`/`AppVersion` types the About rows already read)
- Modify: `project.yml` (`entitlements.properties`: add `com.apple.security.files.user-selected.read-write: true`)
- Modify: `Raconte/Raconte-nocloud.entitlements` (add the same key — `EntitlementsParityTests` pins override == generated minus the three sync keys)
- Modify: `Raconte/Raconte.entitlements` and `Raconte/Info.plist` if `xcodegen generate` changes them (they are tracked generated output — commit in step)
- Modify: `RaconteUITests/AboutUITests.swift` (`testAboutScreenShowsVersionEnvironmentAndSyncRows` :52; `revealRow` :42)
- Create: `docs/export-format.md`
- Modify: `docs/plans/2026-09-06-roadmap-review-and-phases.md` (open question 1 → "Answered 2026-09-06: never run"; Phase 2's export bullet → "built in PR #<n>"), `docs/native-rebuild-plan.md` if it lists export as unbuilt in a status line

**Interfaces:**
- Produces identifiers: `about.export` (the button row), `about.export.progress` (visible while running), `about.export.result` (a text row: `"Exported N entries to <folder name> — verified"` or `"Export failed: <reason>"` or `"Exported, but verification found N problems"`).

- [ ] **Step 1: Failing UI assertion.** In `testAboutScreenShowsVersionEnvironmentAndSyncRows`, after the sync rows and in document order (revealRow scrolls down only): `revealRow(app, "about.export")`. Run `-only-testing:RaconteUITests/AboutUITests` → RED on the missing row. (UI count stays 62: an assertion inside an existing test does not move it — the honest check is green at the baseline count.)

- [ ] **Step 2: Implement.** New `Section("Archive")` after Sync: `Button("Export archive…") { showingPicker = true }.accessibilityIdentifier("about.export")`, `.fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false)` attached to the **List** (outer view; the `ImageCapturePickerSheet.swift:98` importer is the precedent). On pick: `guard url.startAccessingSecurityScopedResource()`; `defer { url.stopAccessingSecurityScopedResource() }` inside the task; run `exporter.export(into: url)` then `ArchiveVerifier.verify(packageURL:)` on a detached utility task; publish progress/result through a small `@Observable final class ExportRunner` (`Raconte/Export/ExportRunner.swift`, `@MainActor`; states `.idle`, `.running`, `.finished(Report, ArchiveVerifier.Report)`, `.failed(String)`) so the view is dumb. Entitlement key in `project.yml` + the nocloud file; `xcodegen generate`; run `EntitlementsParityTests`. Amend the About doc comment: read-only EXCEPT the export action, which writes only to a folder the owner picked.

- [ ] **Step 3: Docs.** `docs/export-format.md`: the tree above, the manifest fields, "verify" semantics, what is skipped and why, and a plain statement that every file except `transcript.md` and `raconte-export.json` is a byte copy of the archive. Roadmap review edits as listed.

- [ ] **Step 4: `AboutUITests` GREEN at 62. macOS unit suite green. iOS compile green. Owner smoke (in the PR body, self-contained): build N+1 per `project.yml`'s rule is the owner's call — the body says "About → Archive → Export archive… → pick a folder → row reads `Exported N entries to <folder> — verified`; open the folder; `entries/<id>/transcript.md` reads as the entry". Commit:**

```bash
git commit -am "feat(about): Export archive… writes and verifies an open-format package; user-selected-files entitlement; docs/export-format.md"
```

Push, open PR 4. Body: the package layout, the smoke, and that the iOS document picker
returns a folder URL the app must hold security-scoped access to for the duration.

**Whole-branch review (Opus):** byte equality of every copied file is asserted, not
assumed; the verifier recomputes `transcript.md` from the PACKAGE's revisions; the exporter
never writes into the source container; `.part` cleanup on every throw path; the entitlement
appears in both entitlement files.

---

## Wrap-up (after the last PR is open)

- [ ] For each PR: `gh pr checks <n>`; read `Executed N tests` from the job logs (`gh api repos/nicolovejoy/raconte/actions/jobs/<id>/logs | grep Executed`), record against the baseline (unit 2082 / UI 62), fix anything red before ending.
- [ ] Expected deltas: PR 1 unit +29; PR 2 unit +6, UI +1; PR 3 unit +16; PR 4 unit +22, UI +0. Re-derive against the CURRENT base if main moved.
- [ ] `/handoff`: CLAUDE.md latest-session block lists the four PRs with URLs, counts, merge order (1 → 2 → 3 → 4, "Update branch" between), the owner smoke for PR 4, and these named manual follow-ups:
  1. **M4 acceptance gate, never run** — on a Mac with a synced archive: quit Raconte, move `~/Library/Application Support/Raconte` aside (do not delete), relaunch, sign in to the same iCloud, wait for the sync to settle (About → Sync), then export with PR 4's action and verify; compare entry counts against the iPhone. Only after this passes does any recountly teardown get scheduled.
  2. #50 needs a design pass (fingerprint in `head.json`) — not built here, on purpose.
  3. #2 held by ruling.
- [ ] Close nothing manually; the PR bodies carry the close keywords (and #67 has none).
