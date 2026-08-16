> **Archived — shipped 2026-08-05.** #23 and #24 closed.

# Failure-path hygiene — build prompts (#23, #24)

**Status: EXECUTED — shipped 2026-08-05 (issues #23 and #24 closed).** Kept as the build
record. (Original 2026-08-05 caveat: written on a machine without Xcode, unverified at the
time of writing.)

Both steps close a filed issue when they land green: **step 1 fixes #24**, **step 2 fixes
#23**. Neither depends on the other; either can land alone. They are grouped because they
are the same kind of defect — a failure path that does something quietly wrong — found in
the same file by the same #20 audit.

Neither issue is data loss. #24 leaves an OS resource held; #23 leaves in-memory truth
ahead of on-disk truth until relaunch recovery catches up. Both are honesty bugs, and the
scope of each fix is deliberately that small: **do not add retry logic, a write queue, or
new manifest machinery.** Recovery-on-relaunch already repairs the disk state.

## 0. Conventions for every step

### 0.1 Build/test commands

The Xcode project is generated. Neither step adds a file, so `xcodegen generate` is not
strictly required here — but it is free and harmless, and it *is* required after a clone:

```
xcodegen generate
```

Full unit suite (the green gate for every step):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test
```

Focused run (for red-first evidence — both steps live in the same test class):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/CaptureCoordinatorTests
```

No UI tests in either step. Nothing here is visible on the capture screen beyond an
existing red `lastError` line (`CaptureView.swift:640-645`), which needs no change.

### 0.2 House rules that bite here

- **XCTest only** — no Swift Testing. `final class XxxTests: XCTestCase`, files flat in
  `RaconteTests/`. Both steps *edit* `RaconteTests/CaptureCoordinatorTests.swift`; neither
  adds a test file.
- **Red first or mutation-verified.** Each test below is labelled RED (fails today, must
  be pasted failing before the fix) or GUARD (passes today; earns its keep via a named
  mutation that must make it fail). A GUARD test with no mutation is not acceptable
  evidence.
- **Concurrency primitive** is `NSLock` + `@unchecked Sendable` (`LevelBox`,
  `CaptureCoordinator.swift:759-764`). Nothing new here needs locking — `FakeSession`
  already locks its counters correctly.
- **`chmod`-based failure injection must skip under root**, or it silently tests nothing.
  Idiom: `try XCTSkipIf(FileManager.default.isWritableFile(atPath: …), "running as root —
  permissions cannot be made to bite")`, mirroring
  `LiveTranscriptIntegrityTests.swift:42-82`. Always pair the seal with a `defer` that
  unseals: `tearDownWithError` deletes the temp root, and a sealed directory's children
  cannot be removed, so a missing `defer` leaks temp dirs forever.
- Subagent builds: **leave changes uncommitted** — the parent session reviews the diff,
  then commits. Report red-run and green-run output verbatim.

### 0.3 What was read, and the two decisions taken from it

Recorded here rather than smuggled into the steps.

1. **`completeCapture()` has three call sites, not two, and two of them leak.**
   `CaptureCoordinator.swift:327` (row 14 — Done tapped while `.interrupted`),
   `:485` (row 11 — resume-retry budget exhausted), and `:520` (row 13 — `drainAndFinish`,
   the normal stop). Only `drainAndFinish` deactivates, at `:519`, immediately before the
   call. So issue #24's give-up path is *one of two* leaking paths; the stop-while-
   interrupted path has the same hole and the issue does not name it. Nothing in
   `enterInterrupted` (`:410-420`) ever deactivates either.

2. **#24's fix goes inside `completeCapture()`, and `drainAndFinish`'s call at `:519` is
   removed.** Reasoning:
   - Fixing it at the give-up call site (`:485`) would leave `:327` still leaking. Two
     call-site fixes would be needed, and a third would be needed the next time a path to
     `captured` is added. Putting it in `completeCapture()` makes it structural: *reaching
     `captured` releases the session*, one statement, one invariant.
   - The double-deactivate hazard the placement raises is real but is answered by deleting
     the redundant call rather than by tolerating it. (For the record: a double call would
     in fact be harmless — `IOSAudioSessionController.deactivate()` is
     `try? setActive(false, options: .notifyOthersOnDeactivation)`, which swallows the
     error from an already-inactive session, and `MacAudioSessionController.deactivate()`
     is an empty body. "Harmless" is not a reason to keep a redundant call, and it would
     weaken the regression assertion from `== 1` to `== 2`.)
   - **Placement within `completeCapture()`: first statement**, before `enqueueFinalize`.
     That makes the normal path byte-for-byte the same ordering it has today, minus one
     line. Checked for all three inbound paths: the recorder is already stopped before
     each one (`:414` via `enterInterrupted` for row 14; `:436`/`:461` in
     `rebuildAndReacquire` for row 11; `:513` for row 13), so no live tap ever outlives
     the session.
   - **Rejected: putting it in `resetCaptureWiring()`.** That is called by
     `handlePrepareFailed` (`:405`) and `teardownFailedCapture` (`:621`), both of which
     already deactivate — instant double call on the two failure paths. Test 1.4 below
     exists specifically to catch someone making this move later.
   - **Not touching `CaptureMachine`.** The machine's row 13 emits `.releaseSession`
     (`CaptureMachine.swift:166`); rows 11 and 14 do not (`:141-143`, `:175-177`), so the
     bug is expressible at the machine level too. Left alone deliberately: the coordinator
     does not realize session effects from the effect list at all — it realizes them from
     the transition (see its own section header, `CaptureCoordinator.swift:281-290`), and
     `executedEffectLog` is test introspection only. Adding the effect would change no
     behavior while churning the exact-effect-array assertions in `CaptureMachineTests`.
     Worth a follow-up note on the issue when it closes; not worth folding in here.

3. **#23 keeps `try?`-equivalent control flow and records the error in `lastError`.** The
   two sites (`:417` `markInterrupted`, `:541` the generic `setState`) become `do/catch`
   whose catch sets `lastError` and falls through exactly as before. No throw is
   propagated, no transition is blocked, no retry is scheduled. That is the issue's stated
   minimum bar and the whole of the scope.
   - **The string is one new literal, not a `message(for:)` case.** `message(for:)`
     (`:646-652`) maps `CaptureError`, and a failed manifest write is not a `CaptureError`
     — it is any `Error` the store threw. The file's precedent for a situation-specific
     line is a bare literal (`:476` "Couldn't resume recording — retrying", `:483`
     "Couldn't resume recording. Saved what was recorded."). Use exactly:

     ```swift
     private static let storeWriteFailedMessage = "Couldn't save recording status. The audio is safe."
     ```

     The second clause is accurate, not reassurance: the issue's own analysis is that
     audio is enqueued and recoverable on every one of these paths, and relaunch recovery
     rebuilds the manifest from the segments.
   - **The helper assigns `lastError` *before* returning, and every call site that has a
     more specific message assigns *after* the `await`** — so specificity always wins.
     Verified against all six call sites: `:334→:335` (`.diskFull` → "Storage full"),
     `:474→:476`, `:480→:483`, `:321→:517` (`.stopping`, then `finish` failure →
     "Storage full"), `:423` and `:326` (no later assignment, so the new literal is what
     the owner sees). Test 2.3 pins this ordering.
   - **Stated consequence, accepted:** the `.resuming` write-ahead at `:423` can fail and
     then the resume can succeed, leaving a red line over a healthy recording. That is
     honest — the manifest genuinely still says `interrupted` while the tap is live, which
     is exactly the dishonesty #23 is about — and it clears at the next `record()`
     (`:211`). Same stickiness rule the structure-markers plan adopted for marker failures
     (§0.3.3 there).
   - **No new observable property.** `lastError` is the existing loud-failure surface,
     already rendered red by `CaptureView.swift:640-645`. A second "last store write
     failed" flag would be state nobody reads.

4. **No new test seam is needed for either step, and none may be added.**
   - #24: `FakeSession` in `CaptureCoordinatorTests.swift` **already counts deactivations**
     — `_deactivateCount` / `deactivateCount` / `func deactivate()` at lines 17, 19, 27,
     lock-guarded. It is currently declared and never asserted anywhere in the suite
     (verified by grep). Step 1 is the first consumer. Do not modify `FakeSession`.
   - #23: `makeStore` is a `StoreFactory` returning a **concrete** `SegmentStore` actor,
     so a throwing store cannot be injected through it — and adding a store protocol for
     this is far out of scope. It is not needed: the real store can be made to fail on
     demand by sealing the on-disk capture directory. `SegmentStore.persistManifest()`
     (`SegmentStore.swift:314-320`) goes through `AtomicFile.replace`, which
     `open(…, O_WRONLY|O_CREAT|O_TRUNC)`s `manifest.json.part` *inside the capture
     directory* and then `rename`s it there — both need write permission on that
     directory, so `chmod 0o555` on it makes every manifest write throw while leaving
     `segments/` (a subdirectory, unaffected by its parent's mode) fully writable. This is
     the same technique as the existing `sealSegmentsDirectory(_:)` helper
     (`CaptureCoordinatorTests.swift:343-350`), one level up.

### 0.4 Step order

Independent. #24 first because it is the smaller diff and its evidence is unambiguous
(a counter goes 0 → 1). If a session runs both, land and commit step 1 before starting
step 2 — they edit the same two files.

---

## Step 1 — the give-up path releases the audio session (#24)

### Files

**Edit: `Raconte/Capture/CaptureCoordinator.swift`** — two lines, opposite signs.

`completeCapture()` (currently `:523-530`) gains the deactivate as its first statement and
a doc-comment sentence naming the invariant:

```swift
/// A capture reached `captured` (durability commit point). Hand it to the finalizer
/// queue and tear down the live wiring.
///
/// Releases the audio session for EVERY path to `captured` (issue #24): the normal
/// stop (row 13), Done-while-interrupted (row 14), and the resume-retry give-up
/// (row 11). The last two used to leave the session active with no recorder — row 13
/// happened to deactivate on its way here, and the other two had nowhere that did.
/// The recorder is already stopped on all three paths before this runs.
private func completeCapture() async {
    session.deactivate()
    if let id = activeCaptureID { enqueueFinalize(id) }
    stopRecordingClock()
    finishPump()
    resetCaptureWiring()
}
```

`drainAndFinish()` (currently `:512-521`) **loses** its now-redundant `session.deactivate()`
at `:519` — the line between the `store.finish` do/catch and `await completeCapture()`.
Nothing else in that function changes.

Do not touch `handlePrepareFailed` (`:401-406`), `teardownFailedCapture` (`:617-622`),
`configureAndStart`'s two failure exits (`:372`, `:376`), `resetCaptureWiring`, or
`CaptureMachine`.

### Tests — write first

**Edit: `RaconteTests/CaptureCoordinatorTests.swift`** — new section
`// MARK: issue #24 — every path to `captured` releases the audio session`, reusing the
file's existing private `FakeSession` / `FakeRecorder` / `makeCoordinator` / `waitUntil`
fixtures (lines 10-130). `FakeSession.deactivateCount` already exists; do not add it.

- **1.1 `testGiveUpPathDeactivatesTheAudioSession` — RED.** Clone the setup of
  `testReacquireBudgetExhaustedClosesInterruptionAsNotResumed` (`:301`): coordinator with
  `machine: CaptureMachine(resumeRetryBudget: 1)`, `resumeBackoff: .milliseconds(20)`;
  `record()`, `feed(frames: 750)`, `emit(.interrupted)`, wait `.interrupted`, **then** set
  `session.activateError` (the initial `record()` must succeed first — that comment on the
  original test is load-bearing), `await coordinator.resume()`, wait for `.captured`.
  Assert `session.deactivateCount == 1`. Today: 0.
- **1.2 `testStopFromInterruptedDeactivatesTheAudioSession` — RED.** Clone
  `testStopFromInterruptedClosesInterruptionAsNotResumed` (`:274`): record, feed, emit
  `.interrupted`, wait, `await coordinator.done()`, assert `phase == .captured` and
  `session.deactivateCount == 1`. Today: 0. This is the leak the issue did not name; the
  test comment should say so.
- **1.3 `testNormalStopDeactivatesExactlyOnce` — GUARD.** Full lifecycle (record, feed,
  `done()`), assert `phase == .captured` and `session.deactivateCount == 1`. Passes today
  (`drainAndFinish` does it) and must still be exactly 1 after the move. **Mutation:**
  keep the `session.deactivate()` at `drainAndFinish:519` while also adding it to
  `completeCapture()` → this test must fail at 2. That mutation is the entire reason the
  test exists; run it and paste the failure.
- **1.4 `testPrepareFailureDeactivatesExactlyOnce` — GUARD.** `session.permissionGranted
  = false`, `await coordinator.record()`, assert `phase == .idle`, `lastError ==
  "Microphone access denied"`, `session.deactivateCount == 1`. **Mutation:** move the new
  `session.deactivate()` from `completeCapture()` into `resetCaptureWiring()` → this test
  must fail at 2, because `handlePrepareFailed` deactivates and *then* calls
  `resetCaptureWiring`. This is the test that pins the placement decision in §0.3.2, not a
  decoration.

### Red/green evidence

Red: write all four tests against the unmodified coordinator and run

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/CaptureCoordinatorTests
```

1.1 and 1.2 must be seen failing at `0 != 1`; 1.3 and 1.4 pass at this point (they are
guards). Paste that output. Then make the two-line change, re-run to green, then run both
mutations and paste each failure, reverting after each.

Green gate: full `-scheme Raconte` suite. Commit:

```
capture: release the audio session on every path to captured (fixes #24)
```

### Subagent prompt — step 1

```
You are implementing step 1 of docs/plans/2026-08-05-failure-path-hygiene-build-prompts.md
in the raconte repo (branch plan/structure-markers). Read that file's §0 and Step 1 in
full first, then read Raconte/Capture/CaptureCoordinator.swift around lines 300-345,
400-530, and 615-635.

Background: CaptureCoordinator.completeCapture() (line ~525) never deactivates the audio
session. It has THREE call sites — line ~327 (Done tapped while interrupted, row 14),
line ~485 (resume-retry budget exhausted, row 11), and line ~520 inside drainAndFinish
(normal stop, row 13). Only drainAndFinish deactivates, at line ~519, just before the
call. So two of the three paths to `captured` leave the audio session active with no
recorder.

Task, exactly as specified: add `session.deactivate()` as the FIRST statement of
completeCapture(), and DELETE the now-redundant session.deactivate() from drainAndFinish.
Two lines. Do NOT put the deactivate in resetCaptureWiring() (handlePrepareFailed and
teardownFailedCapture already deactivate and then call it — instant double call). Do NOT
touch CaptureMachine, handlePrepareFailed, teardownFailedCapture, or configureAndStart.
Add the doc-comment sentence shown in the plan naming the invariant.

TDD, in this order:
1. Add the four tests named in the plan's Step 1 as a new MARK section in
   RaconteTests/CaptureCoordinatorTests.swift, reusing that file's existing FakeSession /
   FakeRecorder / makeCoordinator / waitUntil fixtures. FakeSession ALREADY has a
   lock-guarded `deactivateCount` (lines 17/19/27) — use it, do not modify FakeSession.
   Clone the setups of the existing tests the plan names (lines ~274 and ~301).
2. Before changing any source, run
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/CaptureCoordinatorTests`
   and CAPTURE the failing output. testGiveUpPathDeactivatesTheAudioSession and
   testStopFromInterruptedDeactivatesTheAudioSession must both be seen failing at 0 != 1.
3. Make the two-line change, re-run focused to green, then run the FULL suite:
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test`
4. Mutation checks (run each, observe the failure, revert each):
   (a) also leave the deactivate in drainAndFinish -> testNormalStopDeactivatesExactlyOnce
       must fail at 2;
   (b) move the deactivate from completeCapture into resetCaptureWiring ->
       testPrepareFailureDeactivatesExactlyOnce must fail at 2.

Swift 6 strict concurrency is on. XCTest only. Do not commit. Report: diff, red output,
green output, both mutation results.
```

---

## Step 2 — a swallowed manifest write is recorded, not discarded (#23)

### Files

**Edit: `Raconte/Capture/CaptureCoordinator.swift`** — two `try?` sites become `do/catch`,
plus one private constant.

New constant beside `message(for:)` (`:646-652`):

```swift
/// A plain manifest write failed. The transition still happened and the audio is
/// enqueued either way — relaunch recovery rebuilds the manifest from the segments —
/// so this records the failure instead of discarding it (issue #23), and never blocks
/// the transition.
private static let storeWriteFailedMessage = "Couldn't save recording status. The audio is safe."
```

`enterInterrupted(kind:)` (`:410-420`), replacing `:417`:

```swift
if let store = currentStore {
    do { try await store.markInterrupted(kind: kind, beganAt: now()) }
    catch { lastError = Self.storeWriteFailedMessage }
}
```

The generic `store(setState:…)` helper (`:534-544`), replacing the `try?` at `:541`:

```swift
guard let store = currentStore else { return }
do {
    try await store.setState(state, needsAttention: needsAttention, lastError: lastError,
                             retryCount: retryCount, finalizeAttempts: finalizeAttempts,
                             closingInterruption: resumed)
} catch {
    // Every caller with a more specific message assigns AFTER this returns, so the
    // specific line always wins (see the plan's §0.3.3 site-by-site check).
    self.lastError = Self.storeWriteFailedMessage
}
```

Note the shadowing: the helper's own parameter is named `lastError` (a `String?` written
onto the *manifest*), so the observable property needs `self.lastError`. Getting this
wrong is a compile error, not a silent bug, but it is the one syntactic trap in the step.

Out of scope, explicitly: no retry, no queue, no new manifest field, no new observable
property, no change to `SegmentStore`, no change to any call site of
`store(setState:)`.

### Tests — write first

**Edit: `RaconteTests/CaptureCoordinatorTests.swift`** — new section
`// MARK: issue #23 — a swallowed manifest write is recorded, not discarded`.

New private helper beside `sealSegmentsDirectory(_:)` (`:343-350`):

```swift
/// Make every manifest write fail while leaving `segments/` writable: `AtomicFile.replace`
/// creates `manifest.json.part` in — and renames within — the capture directory, both of
/// which need write permission on it. `segments/` is a subdirectory and is unaffected.
@discardableResult
private func sealCaptureDirectory(_ sealed: Bool) throws -> URL
```

Every test using it must `defer { try? sealCaptureDirectory(false) }` and, right after
sealing, `try XCTSkipIf(FileManager.default.isWritableFile(atPath: dir.path), "running as
root — permissions cannot be made to bite")`.

- **2.1 `testFailedInterruptedManifestWriteSetsLastErrorAndStillInterrupts` — RED.**
  `record()`, `feed(frames: 750)`, seal the capture directory, `emit(.interrupted)`, wait
  for `coordinator.phase == .interrupted`, then wait for
  `coordinator.lastError != nil` (the write is realized after the phase publishes — the
  same race `testInterruptionClosesSegmentAndEntersInterrupted` documents at `:185-188`).
  Assert: `lastError == "Couldn't save recording status. The audio is safe."`; the on-disk
  manifest **still reads `.recording`** (this assertion is what proves the write really
  failed rather than the test proving nothing); the segment 0 sidecar still has
  `frameCount == 750` and `closedReason == .interruption` (the segment close happens
  before the manifest write and is unaffected). Today: `lastError` is nil → red.
- **2.2 `testFailedCapturedManifestWriteSetsLastErrorAndStillSaves` — RED.** `record()`,
  feed 750, `emit(.interrupted)`, wait `.interrupted` **and** wait for the manifest on
  disk to read `.interrupted`, seal the capture directory, `await coordinator.done()`.
  Assert: `phase == .captured`; `finalizeQueue == [kCaptureID]` (the audio still reaches
  the finalizer); the on-disk manifest **still reads `.interrupted`** — the exact lie the
  issue names, "the manifest can stay interrupted while the UI says Saved"; and
  `lastError == "Couldn't save recording status. The audio is safe."`. Today: nil → red.
- **2.3 `testStoreWriteFailureDoesNotClobberTheResumeFailureMessage` — GUARD.** The
  ordering pin for §0.3.3. Build on `testFailedResumeDiskWriteGivesUpToCapturedWithAudioIntact`
  (`:401`): `machine: CaptureMachine(resumeRetryBudget: 0)`, `resumeBackoff:
  .milliseconds(20)`; record, feed 750, interrupt, wait for `.interrupted` on disk, then
  seal **both** `sealSegmentsDirectory(true)` and `sealCaptureDirectory(true)` (so the
  resume's disk half fails *and* the give-up's `.captured` write fails), emit
  `.resumeAvailable(shouldResume: true)`, wait `.captured`. Assert `lastError ==
  "Couldn't resume recording. Saved what was recorded."` — the specific message, not the
  generic one. **Mutation:** in `handleReacquireResult` (`:478-486`), move the
  `lastError = "Couldn't resume recording. Saved what was recorded."` assignment to
  *before* the `await store(setState: .captured, …)` call → this test must fail with the
  generic string. Unseal both directories in `defer`, innermost first.
- **2.4 `testASuccessfulCaptureLeavesLastErrorNil` — GUARD.** Plain full lifecycle
  (record, feed, `done()`), assert `phase == .captured` and `lastError == nil`.
  **Mutation:** move the `self.lastError = …` assignment in the `store(setState:)` helper
  out of the `catch` and onto the success path → this test must fail. Cheap insurance that
  the new code fires only on failure.

### Red/green evidence

Red: write all four tests plus `sealCaptureDirectory` against the unmodified coordinator
and run

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/CaptureCoordinatorTests
```

2.1 and 2.2 must be seen failing on the `lastError` assertion (nil). Paste that output.
Implement, re-run focused to green, then run both mutations and paste each failure,
reverting after each.

Watch for: if 2.1 or 2.2 reports a *skip* rather than a pass, the run is root and the
tests measured nothing — say so explicitly in the report rather than calling it green.

Green gate: full `-scheme Raconte` suite, with `testFailedResumeDiskWriteReturnsToInterruptedNotRecording`
and `testFailedResumeDiskWriteGivesUpToCapturedWithAudioIntact` (the #20 tests, which
share this territory) still passing untouched. Commit:

```
capture: record swallowed manifest-write failures in lastError (fixes #23)
```

### Subagent prompt — step 2

```
You are implementing step 2 of docs/plans/2026-08-05-failure-path-hygiene-build-prompts.md
in the raconte repo (branch plan/structure-markers). Read that file's §0 and Step 2 in
full first, then Raconte/Capture/CaptureCoordinator.swift lines 400-425 and 530-545 and
640-655, and Raconte/Capture/SegmentStore.swift's persistManifest/markInterrupted/setState.

Background: two manifest writes are swallowed with `try?`. CaptureCoordinator.swift line
~417 (`try? await store.markInterrupted(...)` inside enterInterrupted) and line ~541
(`try? await store.setState(...)` inside the generic store(setState:) helper, which
carries EVERY plain transition: .stopping, .resuming, .interrupted, and both .captured
writes). On failure the on-disk manifest stays stale while the UI moves on — e.g. the
manifest reads `interrupted` while the screen says Saved. Relaunch recovery repairs the
disk from the segments, so no audio is at risk; the bug is that the in-memory surface
lies in the meantime.

Task, exactly as specified in the plan and NOTHING MORE: turn both `try?` sites into
do/catch whose catch sets `lastError` to a new private static constant
`storeWriteFailedMessage = "Couldn't save recording status. The audio is safe."` and then
falls through exactly as before. Control flow is unchanged — no throw is propagated, no
transition is blocked. DO NOT add retry logic, a write queue, a new manifest field, a new
observable property, or any change to SegmentStore or to any call site of
store(setState:). Syntactic trap: the helper's own parameter is named `lastError`, so the
observable property must be written as `self.lastError`.

TDD, in this order:
1. Add the four tests named in the plan's Step 2 as a new MARK section in
   RaconteTests/CaptureCoordinatorTests.swift, plus a `sealCaptureDirectory(_:)` helper
   beside the existing `sealSegmentsDirectory(_:)` (line ~343). Failure injection is
   chmod 0o555 on the CAPTURE directory: AtomicFile.replace writes manifest.json.part into
   it and renames within it, so both need write permission, while segments/ is a
   subdirectory and stays writable. Every sealing test needs `defer { try?
   sealCaptureDirectory(false) }` AND `try XCTSkipIf(FileManager.default.isWritableFile(
   atPath:), "running as root — permissions cannot be made to bite")`. Do not add a store
   protocol or any injection seam — makeStore returns a concrete SegmentStore and must
   stay that way.
2. Before changing any source, run
   `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test -only-testing:RaconteTests/CaptureCoordinatorTests`
   and CAPTURE the failing output. testFailedInterruptedManifestWriteSetsLastErrorAndStillInterrupts
   and testFailedCapturedManifestWriteSetsLastErrorAndStillSaves must both be seen failing
   on a nil lastError. If either SKIPS, you are running as root and the evidence is void —
   say so instead of proceeding.
3. Implement, re-run focused to green, then the FULL suite
   (`xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' test`).
   The issue-#20 tests testFailedResumeDiskWriteReturnsToInterruptedNotRecording and
   testFailedResumeDiskWriteGivesUpToCapturedWithAudioIntact must still pass unchanged.
4. Mutation checks (run each, observe the failure, revert each):
   (a) in handleReacquireResult, move the `lastError = "Couldn't resume recording. Saved
       what was recorded."` assignment to BEFORE the `await store(setState: .captured, …)`
       call -> testStoreWriteFailureDoesNotClobberTheResumeFailureMessage must fail with
       the generic string;
   (b) move the `self.lastError = …` assignment in store(setState:) out of the catch onto
       the success path -> testASuccessfulCaptureLeavesLastErrorNil must fail.

Swift 6 strict concurrency is on. XCTest only. Do not commit. Report: diff, red output,
green output, both mutation results.
```
