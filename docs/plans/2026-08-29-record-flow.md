# Record Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The library's floating record button (and Home's "New entry") starts recording
immediately into the chosen journal, and a mis-tap can be discarded in one tap with nothing
left behind but a trash row.

**Architecture:** Two model-owned intents on `CaptureScreenModel` —
`beginCapture(inJournal:)` (select journal → bootstrap → record) and
`discardCurrentCapture()` (stop, then trash the capture the finalizer just committed instead
of building a receipt). Neither hangs off a view lifecycle, per the repo invariant. The
button's visibility rule goes in the pure `CaptureLayoutModel`. `bootstrap()` becomes
await-once so a caller arriving from the library can never start a capture while the
launch-recovery scan is still running.

**Tech Stack:** SwiftUI (iOS 26 / macOS 26), Swift 6 strict concurrency, XCTest.

**Spec:** this document. It records two owner rulings made 2026-08-29:

- **Option 1 (record flow).** The library's floating record button starts recording on
  arrival, rather than preselecting the journal and landing on capture's idle screen where
  the "Last entry" card reads as noise. Sidebar navigation keeps its own current-journal
  behavior, unchanged. The idle screen's own redesign stays with #118.
- **Discard semantics 1 (trash, not hard delete).** A discarded capture finalizes normally
  and goes to the trash — recoverable 30 days, exactly like every other delete, per the rule
  `CaptureScreenModel.delete` already refuses to make an exception to. Never a hard delete:
  the failure mode of a fat-fingered discard 40 minutes into a real reading must not be lost
  audio.

## Global Constraints

- Swift 6 strict concurrency. `CaptureScreenModel` is `@MainActor`.
- **Nothing that must happen while a capture is running may hang off a view's lifecycle.**
  `CaptureView` can be navigated away from at any time. New behavior lives on
  `CaptureScreenModel`, never in `.onAppear`/`.task`/`.onChange` on a view.
- The capture screen pins a near-black background (`InkTone.studio`). Any system control
  placed on it must pin `.environment(\.colorScheme, .dark)`.
- **Never put an accessibility identifier on a control-bar container** — it flattens the bar
  into one element and its children stop being queryable. Identifiers go on the leaf button.
- **A new test FILE does not run until `xcodegen generate`.** This plan adds no new test
  files (every test lands in an existing one) — if you add one anyway, run `xcodegen
  generate` and confirm the executed test count went *up*, not merely that the suite exited 0.
- Unit test command (macOS), copy verbatim:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test
```

- UI test command (simulator only), copy verbatim:

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/NavigationUITests test
```

- Never `CODE_SIGNING_ALLOWED=NO` on the macOS test command: the tests run with the real app
  as host, and an unsandboxed run points `AppContainer.root()` at the owner's real archive.
- Baseline before this plan: 2017 unit tests green; `NavigationUITests` 11/11.

## File Structure

- `Raconte/Capture/UI/CaptureLayoutModel.swift` — add `showsDiscardButton` (Task 1).
- `Raconte/Capture/UI/CaptureScreenModel.swift` — `discardCurrentCapture()` and the
  trash-instead-of-receipt branch (Task 2); await-once `bootstrap()` (Task 4);
  `beginCapture(inJournal:)` (Task 5).
- `Raconte/Capture/UI/CaptureView.swift` — the Discard button in the status row (Task 3).
- `Raconte/App/ContentView.swift` — library and Home call sites (Task 6).
- `RaconteTests/CaptureLayoutModelTests.swift` — Task 1 tests.
- `RaconteTests/CaptureScreenModelTests.swift` — Task 2, 4, 5 tests.
- `RaconteUITests/NavigationUITests.swift` — Task 7 end-to-end smoke.

---

### Task 1: `CaptureLayoutModel.showsDiscardButton`

The pure visibility rule, so the view has no phase logic of its own.

Discard is offered exactly while a capture is under way and can still be stopped by the
owner — `.recording` and `.interrupted`. Not `.preparing`/`.resuming`/`.stopping`: those are
machine-busy phases where the primary control is already disabled, and a Discard that races
the start or the stop is a bug waiting to be filed. Not in `.setup` or `.receipt` mode:
there is nothing in flight to discard.

**Files:**
- Modify: `Raconte/Capture/UI/CaptureLayoutModel.swift`
- Test: `RaconteTests/CaptureLayoutModelTests.swift`

**Interfaces:**
- Consumes: `CaptureState` (existing enum: `.idle, .preparing, .recording, .interrupted,
  .resuming, .stopping, .captured, .finalizing, .complete`).
- Produces: `CaptureLayoutModel.showsDiscardButton: Bool`, set by
  `CaptureLayoutModel.make(phase:hasReceipt:)`. Task 3 reads it.

- [ ] **Step 1: Write the failing tests**

Append to `RaconteTests/CaptureLayoutModelTests.swift`, inside the existing test class:

```swift
// MARK: Discard button (record-flow plan, Task 1)

/// Discard exists to undo a mis-tap of the library's floating record button, so it is
/// offered exactly while there is a capture the owner could still be stopping himself.
func testDiscardIsOfferedWhileRecording() {
    XCTAssertTrue(CaptureLayoutModel.make(phase: .recording).showsDiscardButton)
}

/// An interrupted capture is still the owner's to abandon — the same reason
/// `RecordControlModel` offers Done there.
func testDiscardIsOfferedWhileInterrupted() {
    XCTAssertTrue(CaptureLayoutModel.make(phase: .interrupted).showsDiscardButton)
}

/// The machine-busy phases. The primary control is already disabled in all three; a
/// Discard racing the start or the stop is a defect, not a feature.
func testDiscardIsHiddenInMachineBusyPhases() {
    for phase in [CaptureState.preparing, .resuming, .stopping] {
        XCTAssertFalse(CaptureLayoutModel.make(phase: phase).showsDiscardButton,
                       "\(phase) must not offer Discard")
    }
}

/// Nothing in flight: the landing screen, the receipt, and the terminal phases.
func testDiscardIsHiddenWhenNothingIsInFlight() {
    XCTAssertFalse(CaptureLayoutModel.make(phase: .idle).showsDiscardButton)
    XCTAssertFalse(CaptureLayoutModel.make(phase: .captured, hasReceipt: true).showsDiscardButton)
    XCTAssertFalse(CaptureLayoutModel.make(phase: .finalizing).showsDiscardButton)
    XCTAssertFalse(CaptureLayoutModel.make(phase: .complete).showsDiscardButton)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the unit test command from Global Constraints, scoped:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements \
  -only-testing:RaconteTests/CaptureLayoutModelTests test
```

Expected: FAIL to compile — `value of type 'CaptureLayoutModel' has no member 'showsDiscardButton'`.

- [ ] **Step 3: Add the property**

In `Raconte/Capture/UI/CaptureLayoutModel.swift`, add the stored property after
`showsRecoveryBanners`:

```swift
    /// Whether the one-tap Discard is on screen (record-flow plan, Task 1).
    ///
    /// Option 1 makes the library's floating record button start recording on arrival, so
    /// a mis-tap now produces audio rather than a screen change. Discard is what makes that
    /// cheap. Offered only in `.recording` and `.interrupted` — the phases where the owner
    /// is the one holding the capture open. The machine-busy phases
    /// (`.preparing`/`.resuming`/`.stopping`) already disable the primary control, and a
    /// Discard racing a start or a stop is a defect, not an affordance.
    var showsDiscardButton: Bool
```

Then fill it in each of the three returned literals in `make(phase:hasReceipt:)`:

- the `.preparing, .recording, .interrupted, .resuming, .stopping` case:
  `showsDiscardButton: phase == .recording || phase == .interrupted,`
- the `hasReceipt` literal: `showsDiscardButton: false,`
- the landing-screen literal: `showsDiscardButton: false,`

Place the new argument immediately after `showsRecoveryBanners:` in each literal, matching
the property order.

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: PASS. Then run the whole unit suite (the Global
Constraints command with no `-only-testing:`) — `CaptureLayoutModel` is `Equatable` and
other tests construct it; fix any call sites that now miss the argument.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Capture/UI/CaptureLayoutModel.swift RaconteTests/CaptureLayoutModelTests.swift
git commit -m "feat: CaptureLayoutModel.showsDiscardButton — Discard while recording or interrupted"
```

---

### Task 2: `discardCurrentCapture()` — stop, then trash instead of receipting

The behavior itself. The capture is **not** aborted mid-flight: it stops through the normal
`done()` path and finalizes normally, so the m4a is verified and promoted and nothing is
left half-written on disk. Only then is the entry trashed. That is what makes "no cruft"
true — there is no second teardown path to keep correct, and the discarded capture is
recoverable for 30 days like every other delete (owner ruling, discard semantics 1).

**Files:**
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift`
- Test: `RaconteTests/CaptureScreenModelTests.swift`

**Interfaces:**
- Consumes: `coordinator.phase: CaptureState`, `done() async`, `library.trashEntry(_:now:)
  async -> Bool`, `finishCurrentCapture()`, `buildReceipt(for:)`.
- Produces: `CaptureScreenModel.discardCurrentCapture() async`, and
  `CaptureScreenModel.discardNotice: String?` (Task 3 renders it).

- [ ] **Step 1: Write the failing tests**

Append to `RaconteTests/CaptureScreenModelTests.swift`, inside `CaptureScreenModelTests`.
Note the idiom already used in this file: drive the model with `ModelFakeRecorder` /
`ModelFakeSession` / `FakeAudioEncoder`, then `waitUntil` on the effect you are actually
asserting — never on an earlier one that merely tends to precede it.

```swift
// MARK: Discard (record-flow plan, Task 2)

/// A discarded capture still finalizes — the audio is committed and verified on disk —
/// and is then trashed. Trash, not a hard delete: owner ruling 2026-08-29, the same
/// "delete anywhere, recoverable 30 days" rule `delete(_:)` refuses to make an exception
/// to. The library therefore ends with nothing visible and exactly one trashed entry.
func testDiscardFinalizesTheCaptureAndThenTrashesIt() async throws {
    let recorder = ModelFakeRecorder()
    let encoder = FakeAudioEncoder()
    let model = CaptureScreenModel(
        capturesRoot: root,
        makeSession: { ModelFakeSession() },
        makeRecorder: { recorder },
        encoder: encoder)
    await model.bootstrap()
    let liveCoordinator = model.coordinator

    await model.record()
    recorder.feed(frames: 1000)
    await model.discardCurrentCapture()

    await waitUntil({ liveCoordinator.finalizeQueue.isEmpty == false },
                    "capture never committed to finalizeQueue")
    model.handleFinalizeQueue()

    await waitUntil({ model.coordinator !== liveCoordinator },
                    "model should reset to a fresh idle coordinator after the commit")
    XCTAssertEqual(encoder.calls.count, 1,
                   "a discarded capture must still finalize — the audio is trashed, not abandoned")
    XCTAssertTrue(model.library.items.isEmpty,
                  "a discarded capture must not be visible in the library")
    XCTAssertEqual(model.library.trashed.count, 1,
                   "the discarded capture belongs in the trash, recoverable")
}

/// No receipt. The receipt says "here is the reading you just made" — for a mis-tap that
/// is exactly the cruft the owner asked not to be left with.
func testDiscardLeavesNoReceipt() async throws {
    let recorder = ModelFakeRecorder()
    let model = CaptureScreenModel(
        capturesRoot: root,
        makeSession: { ModelFakeSession() },
        makeRecorder: { recorder },
        encoder: FakeAudioEncoder())
    await model.bootstrap()
    let liveCoordinator = model.coordinator

    await model.record()
    recorder.feed(frames: 1000)
    await model.discardCurrentCapture()
    await waitUntil({ liveCoordinator.finalizeQueue.isEmpty == false }, "no commit")
    model.handleFinalizeQueue()
    await waitUntil({ model.coordinator !== liveCoordinator }, "no coordinator reset")

    XCTAssertNil(model.receipt, "a discarded capture must not produce a receipt")
    XCTAssertEqual(model.discardNotice, "Discarded to Trash",
                   "the screen must say what just happened")
}

/// The very next reading is an ordinary one. The discard flag is per-capture: if it
/// survived, the next entry would silently trash itself — a data-loss bug, and the one
/// this test exists to prevent.
func testTheCaptureAfterADiscardIsKeptNormally() async throws {
    let recorder = ModelFakeRecorder()
    let model = CaptureScreenModel(
        capturesRoot: root,
        makeSession: { ModelFakeSession() },
        makeRecorder: { recorder },
        encoder: FakeAudioEncoder())
    await model.bootstrap()

    var live = model.coordinator
    await model.record()
    recorder.feed(frames: 1000)
    await model.discardCurrentCapture()
    await waitUntil({ live.finalizeQueue.isEmpty == false }, "no commit (discarded capture)")
    model.handleFinalizeQueue()
    await waitUntil({ model.coordinator !== live }, "no coordinator reset (discarded capture)")

    live = model.coordinator
    await model.record()
    recorder.feed(frames: 1000)
    await model.done()
    await waitUntil({ live.finalizeQueue.isEmpty == false }, "no commit (kept capture)")
    model.handleFinalizeQueue()
    await waitUntil({ model.coordinator !== live }, "no coordinator reset (kept capture)")

    XCTAssertEqual(model.library.items.count, 1,
                   "the capture after a discard must be kept")
    XCTAssertNotNil(model.receipt, "a kept capture still gets its receipt")
    XCTAssertNil(model.discardNotice, "starting a new reading retires the discard notice")
}

/// Discard is only meaningful while the owner is holding a capture open. From idle it is
/// a no-op — it must never arm the flag and trash whatever the NEXT reading turns out to
/// be.
func testDiscardFromIdleIsANoOp() async throws {
    let recorder = ModelFakeRecorder()
    let model = CaptureScreenModel(
        capturesRoot: root,
        makeSession: { ModelFakeSession() },
        makeRecorder: { recorder },
        encoder: FakeAudioEncoder())
    await model.bootstrap()

    await model.discardCurrentCapture()
    XCTAssertNil(model.discardNotice, "discard from idle must do nothing at all")

    let live = model.coordinator
    await model.record()
    recorder.feed(frames: 1000)
    await model.done()
    await waitUntil({ live.finalizeQueue.isEmpty == false }, "no commit")
    model.handleFinalizeQueue()
    await waitUntil({ model.coordinator !== live }, "no coordinator reset")

    XCTAssertEqual(model.library.items.count, 1,
                   "an idle-phase discard must not trash the next capture")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements \
  -only-testing:RaconteTests/CaptureScreenModelTests test
```

Expected: FAIL to compile — no member `discardCurrentCapture` / `discardNotice`.

- [ ] **Step 3: Implement**

In `Raconte/Capture/UI/CaptureScreenModel.swift`.

3a. Add the state, next to the other observable screen state (near `receipt`):

```swift
    /// One line saying a capture was just discarded, shown for a few seconds and then
    /// cleared. The mic meter falling still and the timer resetting are the real feedback
    /// that the recording stopped; this is what distinguishes "stopped and kept" from
    /// "stopped and thrown away", which otherwise look identical.
    private(set) var discardNotice: String?

    /// Armed by `discardCurrentCapture()` and consumed by `finishCurrentCapture()` — the
    /// one place that knows which capture ids actually committed. Per-capture: it is
    /// snapshotted and cleared at the top of the finish, so it can never leak into the
    /// next reading.
    private var pendingDiscard = false

    private var discardNoticeTask: Task<Void, Never>?
```

3b. Add the intent, next to `done()`/`resume()`:

```swift
    /// Stop this capture and throw it away (record-flow plan, Task 2).
    ///
    /// Option 1 makes the library's floating record button start recording on arrival, so
    /// a mis-tap now costs real audio instead of a screen change; this is the one tap that
    /// undoes it.
    ///
    /// It stops through the ORDINARY `done()` path and lets the capture finalize normally.
    /// Nothing here aborts a recording mid-flight: there is no second teardown path to
    /// keep correct, the m4a is verified and promoted exactly as for a kept reading, and
    /// nothing is left half-written on disk. The entry is trashed afterwards, in
    /// `finishCurrentCapture`, once it exists.
    ///
    /// Trash, not a hard delete — owner ruling 2026-08-29. "Delete anywhere, recoverable
    /// 30 days" has no exception for this one either (same reasoning as `delete(_:)`), and
    /// the failure mode that matters is a fat-fingered discard forty minutes into a real
    /// reading, which must not be unrecoverable.
    ///
    /// Only from `.recording`/`.interrupted` — the phases where the owner is the one
    /// holding the capture open, matching `CaptureLayoutModel.showsDiscardButton`. From
    /// idle it does nothing at all: arming the flag with no capture in flight would trash
    /// whatever the next reading turned out to be.
    func discardCurrentCapture() async {
        guard coordinator.phase == .recording || coordinator.phase == .interrupted else { return }
        pendingDiscard = true
        await done()
    }
```

3c. In `finishCurrentCapture()`, snapshot the flag at the top, immediately after
`finishing = true`:

```swift
        // Snapshotted and cleared HERE, before any await: the flag is about the capture
        // that is finishing right now, and a launch-recovery drain through this same
        // method must never inherit it.
        let discarding = pendingDiscard
        pendingDiscard = false
```

3d. Replace the `await buildReceipt(for: transcribed)` line with:

```swift
        if discarding {
            // After the rescan, deliberately: `trashEntry` writes the tombstone through
            // `EntryMetadataStore`, which needs the entry to exist, and it rescans itself
            // afterwards — so the library's visible list is correct without a second
            // rescan here.
            for id in transcribed { _ = await library.trashEntry(id) }
            receipt = nil
            showDiscardNotice()
        } else {
            await buildReceipt(for: transcribed)
        }
```

3e. Add the notice helper, next to `buildReceipt`:

```swift
    /// Three seconds, then gone. Unstructured `Task`, cancelled and replaced by the next
    /// discard so two in quick succession do not leave the first one's timer to blank the
    /// second one's notice early.
    private func showDiscardNotice() {
        discardNotice = "Discarded to Trash"
        discardNoticeTask?.cancel()
        discardNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.discardNotice = nil
        }
    }
```

3f. In `record()`, retire the notice alongside the receipt — starting a new reading ends
the last one's story:

```swift
    func record() async {
        receipt = nil
        discardNoticeTask?.cancel()
        discardNotice = nil
        await coordinator.record()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: PASS, four new tests. Then run the full unit suite.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Capture/UI/CaptureScreenModel.swift RaconteTests/CaptureScreenModelTests.swift
git commit -m "feat: discardCurrentCapture — stop, finalize, then trash instead of receipt"
```

---

### Task 3: The Discard button on the capture screen

**Files:**
- Modify: `Raconte/Capture/UI/CaptureView.swift`

**Interfaces:**
- Consumes: `layout.showsDiscardButton` (Task 1), `model.discardCurrentCapture()` and
  `model.discardNotice` (Task 2).
- Produces: a button with `accessibilityIdentifier("capture.discard")`, queried by Task 7.

No unit test: this is view wiring, and the two things worth testing (when the button shows,
what the action does) are already pinned by Tasks 1 and 2. The end-to-end smoke is Task 7.

- [ ] **Step 1: Add the button to the status row**

Find `private var statusRow` in `Raconte/Capture/UI/CaptureView.swift`. It is the fixed-height
row holding the timer, live dot, status text and Done. Add the Discard button as its
trailing element, before the closing of the row's `HStack`:

```swift
            if layout.showsDiscardButton {
                Button("Discard") { Task { await model.discardCurrentCapture() } }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityIdentifier("capture.discard")
                    .accessibilityLabel("Discard recording")
            }
```

Deliberately quiet, not red: it sits beside a live red record control and must not compete
with it for the eye. No confirmation dialog — the discard is recoverable from the trash for
30 days, so a confirmation would buy nothing and cost a tap on the path the owner is
actually on. Do NOT put an accessibility identifier on the row or the bar; the leaf button
only (repo trap: a container identifier flattens the bar and its children stop being
queryable).

- [ ] **Step 2: Render the discard notice**

Find `private var errorBanner`. Directly above it in `body`'s `VStack`, add:

```swift
                if let notice = model.discardNotice {
                    Text(notice)
                        .captureLabel(.receiptSavedChip)
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityIdentifier("capture.discardNotice")
                        .transition(.opacity)
                }
```

If `.receiptSavedChip` does not exist as a `captureLabel` case in this build, use the
nearest existing small-label case rather than inventing one — check
`Raconte/Capture/UI/CaptureLabel.swift` (or wherever `captureLabel` is defined) and pick from
what is there.

- [ ] **Step 3: Build both platforms**

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements build
```

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: both BUILD SUCCEEDED.

- [ ] **Step 4: Run the full unit suite**

The Global Constraints unit command, no `-only-testing:`. Expected: green, at the Task 2
count.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Capture/UI/CaptureView.swift
git commit -m "feat: Discard button and discard notice on the capture screen"
```

---

### Task 4: `bootstrap()` becomes await-once

Task 5 needs to start a capture from the library, on an app that may never have mounted
`CaptureView` — so it must be able to *wait* for the launch-recovery scan rather than race
it. Today `bootstrap()` sets `didBootstrap = true` synchronously and returns immediately on
a second call, which means a concurrent caller is told "done" while `recoverAtLaunch()` and
the trash sweep are still running. Starting a capture in that window would run a fresh
recording against a recovery pass that is mid-flight over the same directory.

Replace the boolean latch with a stored `Task`, which every caller awaits.

**Files:**
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift`
- Test: `RaconteTests/CaptureScreenModelTests.swift`

**Interfaces:**
- Produces: `bootstrap() async` — unchanged signature, now returns only once the work is
  actually finished, and runs the body exactly once across any number of callers.

- [ ] **Step 1: Write the failing test**

Append to `RaconteTests/CaptureScreenModelTests.swift`:

```swift
// MARK: bootstrap is await-once (record-flow plan, Task 4)

/// Two concurrent callers must both come back to a FINISHED bootstrap, not merely a
/// started one. `beginCapture` (the library's floating record button) awaits this before
/// it starts recording, and the thing it is waiting for is the launch-recovery scan: a
/// second caller told "done" early would start a capture while recovery is still walking
/// the same directory.
func testConcurrentBootstrapCallersAllWaitForTheRealWork() async throws {
    let model = CaptureScreenModel(
        capturesRoot: root,
        makeSession: { ModelFakeSession() },
        makeRecorder: { ModelFakeRecorder() },
        encoder: FakeAudioEncoder())

    async let first: Void = model.bootstrap()
    async let second: Void = model.bootstrap()
    _ = await (first, second)

    // `recoverAtLaunch` populates this; a caller that returned early would observe the
    // pre-bootstrap value. Both callers are past it here.
    XCTAssertEqual(model.recovered, model.coordinator.recoveredRecordings,
                   "a bootstrap caller must not return before recovery has published")
    XCTAssertFalse(model.library.isLoading,
                   "a bootstrap caller must not return before the library scan has landed")
}
```

- [ ] **Step 2: Run the test to verify it fails**

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements \
  -only-testing:RaconteTests/CaptureScreenModelTests/testConcurrentBootstrapCallersAllWaitForTheRealWork test
```

Expected: FAIL — the second caller returns before the library scan has landed.

If it passes on the first run, do not shrug and move on: the timing may be hiding the race.
Confirm the test is meaningful by temporarily adding `try? await Task.sleep(for:
.milliseconds(200))` immediately after `didBootstrap = true` in the current `bootstrap()`
and re-running — it must fail then. Remove the sleep before Step 3.

- [ ] **Step 3: Implement**

In `Raconte/Capture/UI/CaptureScreenModel.swift`, replace the `didBootstrap` latch. Delete
the `didBootstrap` property and rename the existing `bootstrap()` body to
`performBootstrap()`, then add:

```swift
    /// The one bootstrap, shared by every caller.
    ///
    /// Was a plain `didBootstrap` boolean flipped synchronously at the top, which made a
    /// second caller return immediately while `recoverAtLaunch()` and the trash sweep were
    /// still running. That was harmless while `CaptureView.task` was the only caller;
    /// `beginCapture(inJournal:)` (record-flow plan, Task 5) starts a recording as soon as
    /// this returns, and starting one on top of an in-flight recovery pass over the same
    /// directory is not harmless. A stored `Task` runs the work once and lets everyone
    /// await the same completion.
    private var bootstrapTask: Task<Void, Never>?

    func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        // ... the existing bootstrap body verbatim, minus the `guard !didBootstrap` /
        // `didBootstrap = true` two lines at the top ...
    }
```

Keep the existing body's comments and ordering exactly as they are — the sequencing in
there is load-bearing and documented at length.

- [ ] **Step 4: Run the tests to verify they pass**

Scoped command from Step 2, then the full unit suite. Expected: green — no other test
should change behavior, since single-caller semantics are identical.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Capture/UI/CaptureScreenModel.swift RaconteTests/CaptureScreenModelTests.swift
git commit -m "refactor: bootstrap() is await-once so callers can't race launch recovery"
```

---

### Task 5: `beginCapture(inJournal:)`

The option-1 intent itself: arrive already recording.

**Files:**
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift`
- Test: `RaconteTests/CaptureScreenModelTests.swift`

**Interfaces:**
- Consumes: `selectJournal(_:)`, `bootstrap()` (Task 4), `record()`,
  `coordinator.phase`.
- Produces: `CaptureScreenModel.beginCapture(inJournal journalID: String?) async`, with
  `journalID` defaulting to `nil`. Task 6 calls it.

- [ ] **Step 1: Write the failing tests**

Append to `RaconteTests/CaptureScreenModelTests.swift`:

```swift
// MARK: beginCapture (record-flow plan, Task 5)

/// Option 1, owner ruling 2026-08-29: the library's floating record button starts
/// recording on arrival. Two taps to make a recording was the complaint; this is the fix.
func testBeginCaptureStartsRecordingImmediately() async throws {
    let recorder = ModelFakeRecorder()
    let model = CaptureScreenModel(
        capturesRoot: root,
        makeSession: { ModelFakeSession() },
        makeRecorder: { recorder },
        encoder: FakeAudioEncoder())

    await model.beginCapture()

    await waitUntil({ model.coordinator.phase == .recording },
                    "beginCapture must leave the machine recording")
    XCTAssertTrue(recorder.isRunning, "the engine must actually be running")
}

/// It selects the journal first, so the sidecar written at `.recording` names the journal
/// the owner was looking at — not whichever one the capture screen happened to hold.
func testBeginCaptureRecordsIntoTheJournalItWasGiven() async throws {
    let recorder = ModelFakeRecorder()
    let model = CaptureScreenModel(
        capturesRoot: root,
        makeSession: { ModelFakeSession() },
        makeRecorder: { recorder },
        encoder: FakeAudioEncoder())
    await model.bootstrap()
    guard let target = await model.createJournal(name: "Letters") else {
        return XCTFail("could not create the target journal")
    }
    // Move off it, so the assertion cannot pass by accident.
    if let other = model.journals.first(where: { $0.id != target.id }) {
        model.selectJournal(other.id)
    }

    await model.beginCapture(inJournal: target.id)

    await waitUntil({ model.coordinator.phase == .recording }, "never started recording")
    XCTAssertEqual(model.selectedJournalID, target.id,
                   "the capture must be filed in the journal the record button came from")
}

/// The safety property. A second tap — or arriving from the library while a reading is
/// already under way — must never restart, and must never re-file a live capture into a
/// different journal underneath the owner.
func testBeginCaptureNeverDisturbsACaptureAlreadyRunning() async throws {
    let recorder = ModelFakeRecorder()
    let model = CaptureScreenModel(
        capturesRoot: root,
        makeSession: { ModelFakeSession() },
        makeRecorder: { recorder },
        encoder: FakeAudioEncoder())
    await model.bootstrap()
    guard let other = await model.createJournal(name: "Elsewhere") else {
        return XCTFail("could not create the second journal")
    }

    await model.record()
    await waitUntil({ model.coordinator.phase == .recording }, "never started recording")
    let live = model.coordinator
    let journalBefore = model.selectedJournalID

    await model.beginCapture(inJournal: other.id)

    XCTAssertTrue(model.coordinator === live,
                  "a live capture must not be restarted by a second record tap")
    XCTAssertEqual(model.coordinator.phase, .recording)
    XCTAssertEqual(model.selectedJournalID, journalBefore,
                   "a live capture must not be re-filed into another journal mid-reading")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements \
  -only-testing:RaconteTests/CaptureScreenModelTests test
```

Expected: FAIL to compile — no member `beginCapture`.

- [ ] **Step 3: Implement**

In `Raconte/Capture/UI/CaptureScreenModel.swift`, next to `record()`:

```swift
    /// Start a reading from outside the capture screen — the library's floating record
    /// button and Home's "New entry" (record-flow plan, Task 5).
    ///
    /// Owner ruling 2026-08-29, option 1: those buttons used to preselect the journal and
    /// route to capture's IDLE screen, where a second tap was needed and the "Last entry"
    /// card read as noise. A big red mic button should record.
    ///
    /// Lives here rather than in the call site's closure because of the repo invariant:
    /// nothing that must happen while a capture is running may hang off a view's
    /// lifecycle. The caller routes and fires this; it does not matter whether, or when,
    /// `CaptureView` mounts.
    ///
    /// `bootstrap()` is awaited, not fired: on a launch that went straight to the library,
    /// `CaptureView` has never mounted and the launch-recovery scan has not run. Starting
    /// a capture on top of an in-flight recovery pass over the same directory is the race
    /// Task 4 made this method able to avoid.
    ///
    /// The `.idle` guard is the safety property. A second tap of the floating button, or
    /// arriving from the library while a reading is already under way, must leave that
    /// reading exactly alone — including its journal, which is why the guard sits AFTER
    /// the select would have happened and the select is guarded with it.
    func beginCapture(inJournal journalID: String? = nil) async {
        await bootstrap()
        guard coordinator.phase == .idle else { return }
        if let journalID { selectJournal(journalID) }
        await record()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Scoped command from Step 2, then the full unit suite. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Capture/UI/CaptureScreenModel.swift RaconteTests/CaptureScreenModelTests.swift
git commit -m "feat: beginCapture(inJournal:) — arrive at capture already recording"
```

---

### Task 6: Wire the library and Home buttons

**Files:**
- Modify: `Raconte/App/ContentView.swift` (the `.home`, `.allEntries` and `.journal` cases
  of the place switch, around lines 180–215)

**Interfaces:**
- Consumes: `CaptureScreenModel.beginCapture(inJournal:)` (Task 5).

- [ ] **Step 1: Rewrite the three call sites**

`.home` — "New entry" has the same idle-screen detour. Home has no journal context, so it
records into whatever journal is current:

```swift
        case .home:
            HomeView(library: services.library,
                     capture: services.capture,
                     onOpenJournal: { services.router.select(.journal($0)) },
                     onNewEntry: {
                         services.router.select(.capture)
                         Task { await services.capture.beginCapture() }
                     })
```

`.allEntries` — not a journal (spec ruling 5), so it records into the current journal
unchanged, exactly as before; only the "starts recording" half changes:

```swift
            LibraryView(model: services.library, title: "All Entries", journal: nil,
                        onCreateEntry: { services.router.detailPath.append(.entry($0)) },
                        onRecord: {
                            services.router.select(.capture)
                            Task { await services.capture.beginCapture() }
                        })
```

`.journal(let id)`:

```swift
                        onRecord: {
                            services.router.select(.capture)
                            Task { await services.capture.beginCapture(inJournal: id) }
                        })
```

Update the comment above the `.journal` case: it currently explains that the button
preselects the journal via `selectJournal` and routes. It now hands both jobs to
`beginCapture(inJournal:)`, which selects through the same `selectJournal` the capture
screen's own picker uses — so the two still never disagree about how a journal gets chosen —
and then starts the reading (owner ruling 2026-08-29, option 1).

Route first, then fire the Task: the routing is synchronous state on the router and should
land in the same runloop turn as the tap, so the screen changes immediately rather than
after `bootstrap()` has awaited a recovery scan.

- [ ] **Step 2: Build both platforms**

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements build
```

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: both BUILD SUCCEEDED.

- [ ] **Step 3: Run the full unit suite**

The Global Constraints unit command. Expected: green.

- [ ] **Step 4: Commit**

```bash
git add Raconte/App/ContentView.swift
git commit -m "feat: library and Home record buttons start the reading, not the idle screen"
```

---

### Task 7: End-to-end smoke — tap record, land recording, discard cleanly

`NavigationUITests` already has a test that taps `library.record` and asserts it lands on the
capture screen. Extend that file with the option-1 behavior and the discard round trip.

**Files:**
- Modify: `RaconteUITests/NavigationUITests.swift`

**Interfaces:**
- Consumes: `openPlace(app, "sidebar.…")` from `RaconteUITests/UITestNavigation.swift` —
  never hard-code a navigation tap; `openPlace` is the one place that handles the
  iPhone-collapsed-vs-both-columns difference. Identifiers: `library.record` (Task 11 of the
  previous plan), `capture.record`, `capture.discard` (Task 3).

- [ ] **Step 1: Read the existing test first**

Open `RaconteUITests/NavigationUITests.swift` and read the existing `library.record` test
(around line 361) plus the file's setup. Match its idioms — how it reaches the library, how
it waits, what it asserts. Do not invent a new navigation helper.

- [ ] **Step 2: Write the failing test**

Append to `NavigationUITests`, adapting the navigation lines to match what the existing
`library.record` test does to reach a journal:

```swift
/// Option 1 (owner ruling 2026-08-29): the floating record button records. Before this
/// it preselected the journal and left you on capture's idle screen needing a second tap.
/// The tell is the primary control's label — "Record" while idle, "Stop" while recording.
func testLibraryRecordButtonArrivesAlreadyRecording() {
    // ... reach a journal exactly as the existing library.record test does ...
    let record = app.buttons["library.record"].firstMatch
    XCTAssertTrue(record.waitForExistence(timeout: 5), "no floating record button")
    record.tap()

    let primary = app.buttons["capture.record"].firstMatch
    XCTAssertTrue(primary.waitForExistence(timeout: 10), "never landed on the capture screen")
    let stopping = NSPredicate(format: "label == %@", "Stop")
    expectation(for: stopping, evaluatedWith: primary, handler: nil)
    waitForExpectations(timeout: 10)
}

/// The mis-tap round trip. Discard stops the reading and leaves the screen idle with no
/// receipt — the entry is in the trash, not on the landing screen.
func testDiscardEndsTheCaptureAndLeavesNoReceipt() {
    // ... reach a journal exactly as the existing library.record test does ...
    app.buttons["library.record"].firstMatch.tap()

    let discard = app.buttons["capture.discard"].firstMatch
    XCTAssertTrue(discard.waitForExistence(timeout: 10), "Discard must be offered while recording")
    discard.tap()

    let primary = app.buttons["capture.record"].firstMatch
    let idle = NSPredicate(format: "label == %@", "Record")
    expectation(for: idle, evaluatedWith: primary, handler: nil)
    waitForExpectations(timeout: 15)
    XCTAssertFalse(app.buttons["capture.receipt.open"].exists,
                   "a discarded capture must not leave a receipt")
}
```

- [ ] **Step 3: Run to verify it fails for the right reason**

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/NavigationUITests test
```

If you are running this against the finished implementation (tasks 1–6 are already in), it
should PASS. To confirm the tests are not vacuous, `git stash` the `ContentView.swift` and
`CaptureView.swift` changes, re-run, and watch them fail for the right reason ("Record" not
"Stop"; no `capture.discard`). Then `git stash pop`.

- [ ] **Step 4: Run the whole class and reconcile the count**

Same command. Expected: 13/13 (the 11 baseline plus these two). **Check the executed count
went up** — an exit code of 0 alone does not prove your new tests ran. Never background this
invocation; run it in the foreground. `NavigationUITests` alone fits inside the 10-minute
cap, but do not widen it to the whole `RaconteUI` suite in one call.

- [ ] **Step 5: Commit**

```bash
git add RaconteUITests/NavigationUITests.swift
git commit -m "test: library record arrives recording, and discard leaves nothing behind"
```

---

### Task 8: The About screen explains what Raconte is and how to use it

Owner request 2026-08-29: "be good to have the About page also describe what this is and
how it works, super short and sweet tutorial. for Lori, and maybe more down the road."

About is today a pure diagnostics screen (version, CloudKit environment, sync status —
#89). It is also the only always-visible, Release-built place a *new* person can be told
what the app is. The tutorial goes above the diagnostics: it is what a first-time reader
came for, and the version/sync rows are what the owner came for.

Prose rule for this task: plain and terse, no grandiose prose, no marketing. Short sentences.
The owner reviews the copy at smoke and will change it — write it so that is easy.

**Files:**
- Modify: `Raconte/App/AboutView.swift`
- Test: `RaconteUITests/NavigationUITests.swift`

**Interfaces:**
- Consumes: nothing new. `AboutView(sync:)` keeps its signature.
- Produces: `about.whatItIs` and `about.howItWorks` accessibility identifiers.

- [ ] **Step 1: Write the failing test**

Append to `NavigationUITests`, reaching About with `openPlace(app, "sidebar.about")` — the
one navigation helper, never a hard-coded tap:

```swift
/// Owner request 2026-08-29: About is the only Release-built screen that can tell a new
/// person (Lori, and whoever comes after) what this app is. The diagnostics stay; the
/// explanation goes above them.
func testAboutExplainsWhatTheAppIsAndHowToUseIt() {
    openPlace(app, "sidebar.about")
    XCTAssertTrue(app.staticTexts["about.whatItIs"].waitForExistence(timeout: 5),
                  "About must say what Raconte is")
    // Below the fold on a phone: an offscreen List row is absent from the accessibility
    // tree until it is scrolled into view (repo trap, 2026-08-21).
    app.swipeUp()
    XCTAssertTrue(app.staticTexts["about.howItWorks"].waitForExistence(timeout: 5),
                  "About must say how to use it")
    XCTAssertTrue(app.staticTexts["about.version"].exists,
                  "the diagnostics this screen exists for must survive")
}
```

- [ ] **Step 2: Run it to verify it fails**

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/NavigationUITests/testAboutExplainsWhatTheAppIsAndHowToUseIt test
```

Expected: FAIL — no `about.whatItIs`.

- [ ] **Step 3: Add the two sections**

In `Raconte/App/AboutView.swift`, insert above the existing `Section("App")`:

```swift
            Section("What this is") {
                Text("""
                Raconte is a private journal you speak into. Press record, say what you \
                want to remember, and it is kept — the recording first, the words second.

                Everything stays on your own devices and your own iCloud. There is no \
                account and no server.
                """)
                .accessibilityIdentifier("about.whatItIs")
            }

            Section("How it works") {
                Text("""
                1. Pick a journal. A journal is just a book to file this reading in.

                2. Tap the red button and talk. The timer and the moving bar mean it is \
                listening.

                3. Tap Stop when you are done. The recording is safe on disk before \
                anything else happens to it.

                4. The words are written out for you afterwards. If one comes out wrong, \
                the recording is still the real thing — you can always listen again.

                5. Started one by accident? Tap Discard. It goes to Trash, where it can be \
                restored for thirty days.
                """)
                .accessibilityIdentifier("about.howItWorks")
            }
```

Both are `Text` in a `List`, so they wrap and scroll with everything else — no fixed
heights, no custom layout. The section order matters: explanation first, diagnostics after.

Update the type's doc comment: it is no longer only "the Release-visible diagnostic
surface". Say that it now carries the app's own short explanation as well, and why (it is
the only Release-built screen a first-time reader can be pointed at).

- [ ] **Step 4: Run the test to verify it passes**

Scoped command from Step 2. Expected: PASS. Then run the whole class:

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/NavigationUITests test
```

Expected: 14/14 (11 baseline + two from Task 7 + this one). Check the executed count went up.

- [ ] **Step 5: Build macOS and check the layout is not clipped**

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Raconte/App/AboutView.swift RaconteUITests/NavigationUITests.swift
git commit -m "feat: About explains what Raconte is and how to use it"
```

---

## Owner smoke (after Task 7)

Hand the owner a real build and these steps, self-contained:

Build the macOS app for smoke (real signing — the only build that can sync):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -derivedDataPath /tmp/raconte-smoke -allowProvisioningUpdates build
```

Hand it over with `ditto`, never `cp -R`, and verify identity with `dwarfdump --uuid` on
`Raconte.debug.dylib` before saying which build it is.

What to check:

1. Open a journal from the sidebar. Tap the round red record button at the bottom right.
   PASS: the capture screen appears and is **already recording** — timer counting, mic meter
   live, big control reads Stop. FAIL: it shows the idle screen with a "Last entry" card and
   a Record button waiting for a second tap.
2. While it is recording, tap **Discard**. PASS: recording stops, a brief "Discarded to
   Trash" line appears and fades, and the screen returns to the landing state with **no**
   receipt. FAIL: a receipt appears, or the entry is still in the journal.
3. Open Trash in the sidebar. PASS: the discarded recording is there and can be restored.
4. Record a normal entry (tap record, speak, tap Stop). PASS: the receipt appears as always
   and the entry is in the journal — the discard must not have leaked into the next reading.
5. From Home, tap "New entry". PASS: same as step 1 — already recording, into the current
   journal.
6. Open About in the sidebar. PASS: it opens with a short "What this is" and a numbered
   "How it works", and the Version / CloudKit / Sync rows are still below them. Read the
   copy as if you were Lori and say what is wrong with it — it is meant to be rewritten.
