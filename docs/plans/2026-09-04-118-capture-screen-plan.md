# Capture Screen (#118) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the capture screen onto the post-Home UX per the owner-ratified design:
a Ready state that is nothing but journal + backdate + the bar, a receipt whose entry is
a tappable card, the voice switch present in every recording, and (gated) a live
transcript that dims the hypothesis rather than the tail.

**Architecture:** Two PRs from the same design. **PR A (re-skin)** is four sequential
tasks on one branch, all editing `CaptureView.swift`, plus a fifth that migrates the UI
tests off two identifiers the design deletes. **PR B (live transcript)** adds a pure
`runs` accessor to `TranscriptConsolidator` (can start immediately, in its own worktree)
and a view that consumes it — the view is gated on a measurement the owner has to make on
a real device (§5 of the design). `CaptureMachine`, `CaptureScreenModel`'s phase
dispatch, and `CaptureControlBarMetrics` are untouched.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency,
XcodeGen project, XCTest + XCUITest.

**Spec:** `docs/plans/2026-08-30-118-capture-screen-design.md` (owner-ratified
2026-08-30). §7 of that design already shipped in #126 and is NOT in this plan. This plan
covers §2, §3, §4, §5, §6, §8.

## Global Constraints

- Xcode project is GENERATED: after adding, renaming or deleting a Swift file, run
  `xcodegen generate`. New files under `Raconte/`, `RaconteTests/`, `RaconteUITests/`
  are picked up by the existing globs — no project.yml edit needed. **A renamed or new
  test file that is not regenerated runs green at the OLD count** — check the executed
  count moved, not the exit code.
- macOS unit-test command (sandbox is NOT optional — never `CODE_SIGNING_ALLOWED=NO`,
  the test host would sweep the owner's real archive):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test
```

- iOS compile check: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- UI tests (simulator only). **The whole `RaconteUI` suite exceeds the Bash tool's
  10-minute cap**: run it as FOREGROUND `-only-testing:RaconteUITests/<Class>`
  invocations, one class at a time, and reconcile counts. Never background a test run.

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:RaconteUITests/CaptureUITests test
```

- **Baseline on main (CI on `cae172bd`, 2026-09-01): 2057 unit (1 skipped), 62 UI.**
  Re-read the number from main's most recent code-carrying CI run before quoting it; a
  docs-only push skips CI.
- Switch convention: no `default:` in switches over `CaptureState` / `Place` — a new case
  must break the build.
- Capture surfaces stay pinned near-black (`InkTone.studio`) regardless of system
  appearance. Any system control placed there pins `.environment(\.colorScheme, .dark)`
  — never `.preferredColorScheme`, which would resolve to the whole window on macOS.
- Nothing that must happen while a capture is running may hang off a view's lifecycle.
  `CaptureView` can be navigated away from at any time.
- Accessibility identifiers go on the `NavigationLink`/`Button` itself, never on a
  nested child (the link merges its label into one element). A container identifier
  overwrites its descendants' — do not put one on the control bar or the receipt card's
  outer `VStack`.
- Source-scanning tests must strip comments; a phrase grep misses wrapped prose — grep a
  single distinctive word and count hits to zero.
- Commit messages end with the `Co-Authored-By` / `Claude-Session` trailers the session
  reminder specifies. Merges are Nico's — end at an open PR, never `gh pr merge`.

## Branches

- **PR A:** `feat/118-capture-reskin` from `main`. Tasks 1–5, in order, one worktree.
- **PR B:** `feat/118-live-transcript` from `main`. Task 6 can start at the same time
  as Task 1 (disjoint files). Task 7 waits for the measurement AND for PR A to merge —
  rebase onto main before starting it, because Task 7 edits `CaptureView.swift`.

When both PRs are open: merge A, wait for main to go green, **Update branch** on B, then
merge B. Two green PRs from the same base can still merge into a red main.

## The measurement gate (design §5, "Check first")

Task 7 must not be built until the owner has read how long text stays provisional in
real speech. Task 6 ships the instrumentation. The owner's part:

1. Build the owner-smoke macOS app from the `feat/118-live-transcript` branch:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  -derivedDataPath /tmp/raconte-118 -allowProvisioningUpdates build
```

2. Launch it, record about one minute of natural speech into any journal, stop.
3. Pull the timing log (use `/usr/bin/log`, the zsh function shadows it):

```
/usr/bin/log show --last 10m --predicate 'subsystem == "org.pianohouseproject.raconte" AND category == "transcript-timing"' --style compact
```

4. Each `promoted` / `superseded` line carries `provisionalMs=<n>`: the wall-clock time
   between a hypothesis first appearing and its text settling. Read the median and the
   max. Under about 1500 ms the dim-then-brighten flicker is constant motion in
   peripheral vision, and Task 7's design must change (e.g. dim only after a run has
   been provisional for >1 s, or not dim at all). Over about 3 s, build Task 7 as
   specified.

**Never install a dev build on the iPhone for this.** It replaces the TestFlight app and
points it at the development CloudKit database. The Mac is a device.

---

## PR A — the re-skin

### Task 1: Two voices stops being a toggle (design §4)

**Files:**
- Modify: `Raconte/Capture/UI/MarkerControls.swift:43-52`
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift` (lines ~180, 560-576, 690-705)
- Modify: `Raconte/Capture/UI/CaptureView.swift:28-31` (markers), `:853` (voice tap), delete `MultiVoiceField` at `:680-720`
- Modify: `Raconte/Capture/UI/CaptureSurface.swift` (delete `.multiVoiceToggle` from `CaptureLabel`)
- Modify: `Raconte/Library/LibraryScreenModel.swift:345-356` (delete `lastMultiVoice`)
- Modify: `RaconteTests/MarkerControlsModelTests.swift`
- Rename: `RaconteTests/MultiVoiceCarryOverTests.swift` → `RaconteTests/MultiVoiceMarkingTests.swift`
- Modify: `RaconteTests/CaptureLayoutModelTests.swift` — NOT in this task (Task 2 owns the layout flags; this task leaves `showsMultiVoiceField` in place and only removes the view that read it in Task 2). See Interfaces.

**Interfaces:**
- Produces: `MarkerControlsModel.make(phase: CaptureState) -> MarkerControlsModel` (the `multiVoice:` parameter is gone; `showsVoiceControl` is `true` in every phase).
- Produces: `CaptureScreenModel.markVoice(_ voice: String)` — the ONLY path from the view to a live voice mark. Writes the frame-0 opener (idempotent via the coordinator's latch), appends the tap's marker, and on the first mark of a capture enqueues `multiVoice: true` to the sidecar.
- Removes: `CaptureScreenModel.multiVoiceEnabled`, `setMultiVoiceEnabled(_:)`, `multiVoiceOverrides`; `LibraryScreenModel.lastMultiVoice(forJournal:)`; `MultiVoiceField`; `CaptureLabel.multiVoiceToggle`.
- Leaves: `EntryMetadata.multiVoice` and every sync/ingest site untouched — it is a synced LWW field and keeps its exact meaning (design §4). `LibraryScreenModel.mostRecentlyCaptured` stays (the `recent` list uses it).

- [ ] **Step 1: Rewrite `MarkerControlsModelTests` to the ungated rule**

Replace the whole file body (keep the header and class name):

```swift
import XCTest
@testable import Raconte

/// T6 §14 step 5, revised by #118 §4 — the pure phase → marker-control mapping. The
/// Two-voices toggle is gone: the voice switch is present in every recording, so the
/// only thing phase decides is whether a tap can land.
final class MarkerControlsModelTests: XCTestCase {

    private func model(_ phase: CaptureState) -> MarkerControlsModel {
        MarkerControlsModel.make(phase: phase)
    }

    /// #118 §4: the pre-record gate existed only to arm the live switch; nothing is lost
    /// by dropping it because `VoiceMarkingPlan.openerIfNeeded` synthesizes a frame-0
    /// opener for any entry lacking one. What the gate cost was live thumb-marking on a
    /// journal's first two-voice reading, which arriving-recording made unreachable.
    func testVoiceControlIsShownInEveryPhase() {
        for phase in CaptureState.allCases {
            XCTAssertTrue(model(phase).showsVoiceControl,
                          "\(phase): the voice switch must be present — there is no toggle to gate it")
        }
    }

    /// Owner decision 7: paragraphs are structure in a single-voice reading too.
    func testParagraphControlIsShownInEveryPhase() {
        for phase in CaptureState.allCases {
            XCTAssertTrue(model(phase).showsParagraphControl, "\(phase): paragraph control hidden")
        }
    }

    /// Visible-but-disabled must not quietly become visible-AND-tappable: a tap landing
    /// outside `.recording` has no frame to attach a marker to.
    func testTapsOnlyEverLandWhileRecording() {
        for phase in CaptureState.allCases {
            XCTAssertEqual(model(phase).isEnabled, phase == .recording,
                           "\(phase): enabled must track .recording exactly")
        }
    }

    /// Plan §0.3.9 / #53: one shape in every phase is what keeps the bar from moving.
    func testControlsHaveOneShapeInEveryPhase() {
        let reference = model(.recording)
        for phase in CaptureState.allCases {
            let m = model(phase)
            XCTAssertEqual(m.showsVoiceControl, reference.showsVoiceControl, "\(phase)")
            XCTAssertEqual(m.showsParagraphControl, reference.showsParagraphControl, "\(phase)")
        }
    }
}
```

- [ ] **Step 2: Run the unit target to see it fail**

Run the macOS unit-test command. Expected: compile error in `MarkerControlsModelTests` — `make(phase:)` has no overload without `multiVoice:`.

- [ ] **Step 3: Change `MarkerControlsModel.make`**

In `Raconte/Capture/UI/MarkerControls.swift`, replace lines 43-52:

```swift
    static func make(phase: CaptureState) -> MarkerControlsModel {
        switch phase {
        case .idle, .preparing, .recording, .interrupted, .resuming,
             .stopping, .captured, .finalizing, .complete:
            // #118 §4: the voice switch is present in every recording. The Two-voices
            // toggle that used to gate it is gone; `VoiceMarkingPlan.openerIfNeeded`
            // makes a single-voice recording convertible after the fact, so nothing the
            // gate protected is lost.
            return .init(showsVoiceControl: true,
                         showsParagraphControl: true,
                         // Only `.recording` has a frame to anchor a marker to; a tap in any
                         // other phase would have nowhere to land.
                         isEnabled: phase == .recording)
        }
    }
```

Update the type's doc comment above it: remove the sentence about the toggle if present.

- [ ] **Step 4: Rename and rewrite the carry-over tests as marking tests**

```bash
git mv RaconteTests/MultiVoiceCarryOverTests.swift RaconteTests/MultiVoiceMarkingTests.swift
```

Keep the two fake classes (`MultiVoiceFakeSession`, `MultiVoiceFakeRecorder`) and the
fixture helpers (`writeCapture`, `writeJournals`, `journal`, `makeModel`,
`startRecording`, `waitForSidecar`, `waitForSidecarFile`) exactly as they are. Replace
the class doc comment and every test method with:

```swift
/// #118 §4 — a reading becomes two-voice by MARKING a voice, not by arming a toggle
/// first. The first live mark writes the frame-0 opener (idempotent), the tap's own
/// marker, and `multiVoice: true` to the sidecar. A reading with no voice mark writes
/// none of those.
@MainActor
final class MultiVoiceMarkingTests: XCTestCase {
```

Tests:

```swift
    // MARK: no mark → single voice

    /// The sidecar-shape convention: a single-voice entry writes no `multiVoice` key at
    /// all, and no `transcript/` directory (the lazy-open rule — an eager open would make
    /// a mis-tap's directory undeletable).
    func testRecordingWithoutAVoiceMarkIsSingleVoice() async throws {
        try writeJournals([journal("J1", "1987")])
        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()

        let captureID = try await startRecording(model, recorder)
        await waitForSidecar(captureID, "the capture never filed") { $0.journalID == "J1" }
        await model.done()

        let text = try String(
            contentsOf: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(captureID)),
            encoding: .utf8)
        XCTAssertFalse(text.contains("multiVoice"), "single-voice entries write no key: \(text)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SegmentLayout.transcriptDirectory(captureDirectory: captureDir(captureID)).path),
            "a single-voice capture must not create transcript/")
        XCTAssertEqual(MarkerLogReader.load(captureDirectory: captureDir(captureID)).source, .absent)
    }

    // MARK: the first mark

    /// One tap, three effects: the frame-0 `bn` opener, the tap's own marker at the
    /// current frame, and `multiVoice: true` in the sidecar. Frame order == seq order,
    /// so the opener is appended BEFORE the tap.
    func testFirstVoiceMarkWritesOpenerThenMarkAndSetsMultiVoice() async throws {
        try writeJournals([journal("J1", "1987")])
        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()

        let captureID = try await startRecording(model, recorder)
        recorder.feed(frames: 4_800)          // advance the clock so the tap is not at 0
        model.markVoice(StructureMarker.Voice.littleNico)

        await waitForSidecar(captureID, "multiVoice never reached entry.json") { $0.multiVoice }

        let loaded = MarkerLogReader.load(captureDirectory: captureDir(captureID))
        XCTAssertEqual(loaded.markers.map(\.seq), [0, 1])
        XCTAssertEqual(loaded.markers.map(\.kind), [.voice, .voice])
        XCTAssertEqual(loaded.markers.map(\.voice),
                       [StructureMarker.Voice.bigNico, StructureMarker.Voice.littleNico])
        XCTAssertEqual(loaded.markers.first?.frame, 0, "the opener is at the literal frame 0")
        XCTAssertGreaterThan(loaded.markers[1].frame, 0, "the tap lands on the live clock")
        XCTAssertEqual(model.coordinator.currentVoice, StructureMarker.Voice.littleNico)
        await model.done()
    }

    /// The opener is once per capture — `CaptureCoordinator.didWriteOpeningVoice` — so
    /// a second tap appends exactly one marker, and the sidecar is not rewritten.
    func testSecondVoiceMarkDoesNotDuplicateTheOpener() async throws {
        try writeJournals([journal("J1", "1987")])
        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()

        let captureID = try await startRecording(model, recorder)
        recorder.feed(frames: 4_800)
        model.markVoice(StructureMarker.Voice.littleNico)
        recorder.feed(frames: 4_800)
        model.markVoice(StructureMarker.Voice.bigNico)
        await waitForSidecar(captureID, "multiVoice never landed") { $0.multiVoice }

        let loaded = MarkerLogReader.load(captureDirectory: captureDir(captureID))
        XCTAssertEqual(loaded.markers.count, 3, "opener + two taps, no second opener")
        XCTAssertEqual(loaded.markers.filter { $0.frame == 0 }.count, 1)
        await model.done()
    }

    /// Marking is live-only: outside `.recording` there is no frame to anchor to, and the
    /// model must not write `multiVoice` for a capture that has none.
    func testMarkVoiceOutsideRecordingIsANoOp() async throws {
        try writeJournals([journal("J1", "1987")])
        let model = makeModel()
        await model.bootstrap()
        XCTAssertEqual(model.coordinator.phase, .idle)

        model.markVoice(StructureMarker.Voice.littleNico)

        XCTAssertNil(model.coordinator.currentVoice, "an idle tap must not change the voice")
        XCTAssertEqual(model.coordinator.markerCount, 0)
    }

    // MARK: sidecar sharing

    /// A mid-capture journal switch runs `syncActiveEntryMetadata`, which shares the
    /// sidecar writer with the mark path. It must move the entry without touching
    /// `multiVoice` (nil-defaulted parameter — "leave it alone").
    func testMidCaptureJournalSwitchKeepsMultiVoice() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "1991")])
        let recorder = MultiVoiceFakeRecorder()
        let model = makeModel(recorder: recorder)
        await model.bootstrap()
        model.selectJournal("J1")

        let captureID = try await startRecording(model, recorder)
        recorder.feed(frames: 4_800)
        model.markVoice(StructureMarker.Voice.littleNico)
        await waitForSidecar(captureID, "multiVoice never landed") { $0.multiVoice }

        model.selectJournal("J2")
        await waitForSidecar(captureID, "the journal switch never reached the live sidecar") {
            $0.journalID == "J2"
        }
        try await Task.sleep(for: .milliseconds(200))
        let after = try EntryMetadataStore.read(
            url: SegmentLayout.entryMetadataURL(captureDirectory: captureDir(captureID)))
        XCTAssertTrue(after.multiVoice, "a mid-capture journal switch rewrote multiVoice")
        XCTAssertEqual(after.journalID, "J2")
        await model.done()
    }
}
```

If `StructureMarker.Voice.littleNico` is not the constant's name, grep
`Raconte/Capture/StructureMarker.swift` for the `Voice` enum and use its second case;
the tests in this file already use `bigNico`.

`model.coordinator.markerCount` and `currentVoice` exist (they drive `RecordControlsRow`).

- [ ] **Step 5: Regenerate the project and run the unit target to see the new tests fail**

```bash
xcodegen generate
```

Run the macOS unit-test command. Expected: compile errors — `CaptureScreenModel` has no `markVoice(_:)`, and `MultiVoiceFakeRecorder.feed` is fine. Note the compile also fails in `CaptureView.swift:30` (`multiVoice:` argument) — that is expected and fixed in Step 6.

- [ ] **Step 6: Remove the gate from `CaptureScreenModel` and add `markVoice`**

In `Raconte/Capture/UI/CaptureScreenModel.swift`:

a. Delete the property at ~line 180: `private var multiVoiceOverrides: [String: Bool] = [:]`.

b. Add, next to `pendingDiscardID`:

```swift
    /// Whether this capture's sidecar already carries `multiVoice: true` — set on the
    /// first live voice mark, reset when the coordinator is replaced. A latch, not a
    /// re-read of the sidecar: the write is asynchronous and a second tap in the same
    /// beat must not enqueue a duplicate.
    private var wroteMultiVoiceForActiveCapture = false
```

Reset it where the coordinator is respawned after a capture ends — `coordinator = spawn()` at ~line 874 — with `wroteMultiVoiceForActiveCapture = false` on the line after. (The other `self.coordinator = spawn()` at ~line 233 is the initializer; the property's default covers it.)

c. In `handlePhase()` (lines ~560-576), delete the multi-voice snapshot and the opener call. The body becomes:

```swift
    func handlePhase() {
        guard coordinator.phase == .recording, let id = coordinator.activeCaptureID else { return }
        if let transcription, let format = coordinator.activeFormat {
            transcription.activate(captureID: id, inputFormat: format)
        }
        // Journal + backdate only. `multiVoice` is no longer decided at record time
        // (#118 §4): the first live voice mark writes it, see `markVoice`.
        enqueueEntryMetadataWrite(for: id)
    }
```

Update the doc comment above `handlePhase` to drop the sentence about the opener.

d. Delete `multiVoiceEnabled` and `setMultiVoiceEnabled` (lines ~690-705) including their doc comments.

e. Add, near `done()` / `resume()`:

```swift
    /// A live voice mark (#118 §4). The ONLY route from the view to `markVoice` on the
    /// coordinator, because a mark has two side effects the coordinator does not own:
    ///
    /// 1. The frame-0 `bn` opener is written first, if this capture has none yet. The
    ///    coordinator's `didWriteOpeningVoice` latch makes that idempotent, and it writes
    ///    at the literal frame 0, so seq order stays frame order.
    /// 2. The first mark of a capture writes `multiVoice: true` to the sidecar, through
    ///    the same chained `enqueueEntryMetadataWrite` every other sidecar write uses.
    ///
    /// Outside `.recording` the coordinator refuses the mark (`canMark`), and this method
    /// must refuse the sidecar write for the same reason — hence the phase guard.
    func markVoice(_ voice: String) {
        guard coordinator.phase == .recording, let id = coordinator.activeCaptureID else { return }
        coordinator.markOpeningVoice()
        coordinator.markVoice(voice)
        if !wroteMultiVoiceForActiveCapture {
            wroteMultiVoiceForActiveCapture = true
            enqueueEntryMetadataWrite(for: id, multiVoice: true)
        }
    }
```

f. In the doc comment of `enqueueEntryMetadataWrite` (~line 1025-1035), replace "Only `handlePhase`'s `.recording` path passes a value; carry-over chooses the next capture's mode, never a running one's." with "Only `markVoice` passes a value, and only `true`, on the first live voice mark of a capture."

- [ ] **Step 7: Delete `MultiVoiceField` and the toggle role; route the view's tap through the model**

In `Raconte/Capture/UI/CaptureView.swift`:

a. Lines 28-31, `markers`:

```swift
    private var markers: MarkerControlsModel {
        MarkerControlsModel.make(phase: model.coordinator.phase)
    }
```

b. Delete the whole `MultiVoiceField` struct and its doc comment (the block beginning `/// Whether this is a two-voice reading (T6 §14, design §5)` through the closing brace, ~lines 680-720). Also delete the three lines in `setupRegion` that mount it (`if layout.showsMultiVoiceField { MultiVoiceField(model: model) }`). The `showsMultiVoiceField` flag itself survives until Task 2 — it is now read by nothing, which is exactly the state Task 2 deletes.

   Deleting `CaptureLabel.multiVoiceToggle` (below) is not optional: `CaptureLabelTests.testEveryLabelCaseIsActuallyAppliedToAView` scans `Raconte/Capture/UI` for `.captureLabel(.<case>)` and fails on a case no view applies.

c. In `RecordControlsRow.body`, the voice button's action (line ~853): `model.coordinator.markVoice(otherVoice)` → `model.markVoice(otherVoice)`.

In `Raconte/Capture/UI/CaptureSurface.swift`: delete `case multiVoiceToggle` from `CaptureLabel` and remove `.multiVoiceToggle` from the three `case` lists in `labelColor` and `textSize(on:)` (lines ~219, 241, 252).

In `Raconte/Library/LibraryScreenModel.swift`: delete `lastMultiVoice(forJournal:)` and its doc comment (lines ~345-357). Keep `mostRecentlyCaptured`.

- [ ] **Step 8: Grep for stragglers, then build**

```bash
grep -rn "multiVoiceEnabled\|setMultiVoiceEnabled\|multiVoiceOverrides\|MultiVoiceField\|lastMultiVoice\|multiVoiceToggle" Raconte RaconteTests
```

Expected: zero hits in `Raconte/` and `RaconteTests/`. (`RaconteUITests` still has `capture.multiVoiceToggle` — Task 5 owns those.) Then run the macOS unit-test command.

Expected: green. Count: baseline 2057 − 8 MarkerControlsModelTests + 4 − 8 MultiVoiceCarryOverTests + 5 = **2050** (1 skipped). If the count differs, list the test methods in both files and account for every delta before continuing.

Also run the iOS compile check.

- [ ] **Step 9: Commit**

```bash
git add -A Raconte RaconteTests
git commit -m "feat(capture): voice switch in every recording, Two-voices toggle removed (#118 §4)"
```

---

### Task 2: The Ready band (design §3 Ready, §6)

**Files:**
- Modify: `Raconte/Capture/UI/CaptureLayoutModel.swift`
- Modify: `Raconte/Capture/UI/CaptureView.swift` (`setupRegion` ~145-190, `lastEntrySection` ~350-365, delete `BackdateField` ~599-626)
- Modify: `Raconte/Capture/UI/CaptureSurface.swift` (delete `.recentHeader`)
- Modify: `RaconteTests/CaptureLayoutModelTests.swift`

**Interfaces:**
- Consumes: Task 1 removed `MultiVoiceField`.
- Produces: `CaptureLayoutModel` with `Mode.ready` (renamed from `.setup`) and WITHOUT `showsLastEntry`, `showsMultiVoiceField`, `showsRecoveryBanners`, `usesCompactBackdateField`. Remaining fields: `mode`, `showsLiveTranscript`, `showsReceipt`, `showsDiscardButton`, `transcriptFillsAvailableHeight`.
- Removes: `lastEntrySection`, `BackdateField` (the sheet's `BackdateEditorContent` stays), `CaptureLabel.recentHeader`, the `RecoveryBanner` loop in capture (Home renders them).

Why four flags and not the design's three: §6 puts the compact backdate line on Ready as well as Recording, which makes `usesCompactBackdateField` permanently true — the same "dead flags are the #74 complaint" rule §3 applies to the other three. Disclosed deviation; reviewer should confirm it and not treat it as scope creep.

- [ ] **Step 1: Rewrite `CaptureLayoutModelTests`**

Delete these tests: `testLastEntryIsHiddenWhileCapturing`, `testMultiVoiceFieldIsHiddenWhileCapturing`, `testBackdateFieldIsCompactWhileCapturing`, `testRecoveryBannersAreHiddenWhileCapturing`.

Replace `testIdleShowsTheLandingLayout` with:

```swift
    /// #118 §3: Ready is journal + backdate + the bar, nothing else. Ready and Recording
    /// differ ONLY in the middle band (empty vs transcript) — the flags that used to
    /// distinguish them (last entry, two voices, recovery banners, full backdate field)
    /// are gone, not pinned false.
    func testReadyIsTheBareLayout() {
        let ready = layout(.idle)
        XCTAssertEqual(ready.mode, .ready)
        XCTAssertFalse(ready.showsLiveTranscript, "nothing is being transcribed")
        XCTAssertFalse(ready.showsReceipt)
        XCTAssertFalse(ready.showsDiscardButton)
        XCTAssertFalse(ready.transcriptFillsAvailableHeight,
                       "no transcript, so nothing to give the height to")
    }
```

In `testReceiptReplacesTheLandingControls`, delete the two assertions on `showsLastEntry` and `showsMultiVoiceField`; keep `XCTAssertTrue(receipt.showsReceipt)`. Rename it `testReceiptOwnsTheMiddleBand`.

In `testLayoutDoesNotChangeAcrossAnInterruption`, delete the four `XCTAssertEqual` lines for `showsLastEntry`, `showsMultiVoiceField`, `usesCompactBackdateField`, `showsRecoveryBanners`.

Add:

```swift
    /// Every remaining flag is exercised by at least one phase in each direction — a flag
    /// that reads the same in every phase is the dead flag #74 complained about.
    func testNoRemainingFlagIsConstant() {
        let all = CaptureState.allCases.flatMap { phase in
            [CaptureLayoutModel.make(phase: phase, hasReceipt: false),
             CaptureLayoutModel.make(phase: phase, hasReceipt: true)]
        }
        XCTAssertTrue(all.contains { $0.showsLiveTranscript } && all.contains { !$0.showsLiveTranscript })
        XCTAssertTrue(all.contains { $0.showsReceipt } && all.contains { !$0.showsReceipt })
        XCTAssertTrue(all.contains { $0.showsDiscardButton } && all.contains { !$0.showsDiscardButton })
        XCTAssertTrue(all.contains { $0.transcriptFillsAvailableHeight }
                      && all.contains { !$0.transcriptFillsAvailableHeight })
    }
```

- [ ] **Step 2: Run the unit target to see it fail**

Expected: compile errors — `.ready` does not exist; `init` still requires the deleted flags.

- [ ] **Step 3: Cut `CaptureLayoutModel` down**

Replace `Raconte/Capture/UI/CaptureLayoutModel.swift` from `enum Mode` to the end of the file with:

```swift
    enum Mode: Equatable, Sendable {
        /// Between readings: journal, backdate, the bar. Nothing else (#118 §3). Home
        /// carries the recovery banners and the last entry; About carries the build stamp.
        case ready
        /// A capture is under way.
        case capturing
        /// A capture just finished and its receipt is up, awaiting dismissal.
        case receipt
    }

    var mode: Mode

    /// Whether the LIVE transcript band is on screen at all.
    ///
    /// Only ever during a capture. It used to linger after one, because the coordinator
    /// deliberately holds the finished text (so the panel doesn't blank the instant you
    /// stop) and nothing cleared it until the next recording began — which left the words
    /// stranded on the landing screen as loose, untappable text. The finished transcript
    /// now belongs to the receipt, which is a different thing in a different place.
    var showsLiveTranscript: Bool

    /// Whether the receipt owns the middle of the screen.
    var showsReceipt: Bool

    /// Whether the one-tap Discard is on screen (record-flow plan, Task 1).
    ///
    /// Option 1 makes the library's floating record button start recording on arrival, so
    /// a mis-tap now produces audio rather than a screen change. Discard is what makes that
    /// cheap. Offered only in `.recording` and `.interrupted` — the phases where the owner
    /// is the one holding the capture open. The machine-busy phases
    /// (`.preparing`/`.resuming`/`.stopping`) already disable the primary control, and a
    /// Discard racing a start or a stop is a defect, not an affordance.
    var showsDiscardButton: Bool

    /// Whether the transcript fills the height available above the control bar (with its
    /// own scroll) instead of being capped.
    ///
    /// The cap existed to stop the transcript shoving the controls down. With the controls
    /// pinned, that pressure is gone and the cap only wastes screen: the transcript is the
    /// one thing worth looking at while reading aloud.
    var transcriptFillsAvailableHeight: Bool

    /// `hasReceipt` is the screen's own state, not the machine's: a capture that has
    /// finalized leaves the coordinator `.idle` (a fresh one is spawned), so the phase
    /// alone cannot distinguish "just finished a reading" from "opened the app".
    static func make(phase: CaptureState, hasReceipt: Bool = false) -> CaptureLayoutModel {
        switch phase {
        // A capture is under way — including the phases either side of an interruption,
        // which must NOT change the layout, or the screen would reflow exactly when the
        // owner is trying to get back to reading.
        //
        // Checked BEFORE `hasReceipt` on purpose: a live capture always outranks a
        // leftover receipt. If a stale receipt could survive into a recording it would
        // cover the live transcript with the previous entry's words, which is a worse
        // version of the bug this whole state exists to fix.
        case .preparing, .recording, .interrupted, .resuming, .stopping:
            return .init(mode: .capturing,
                         showsLiveTranscript: true,
                         showsReceipt: false,
                         showsDiscardButton: phase == .recording || phase == .interrupted,
                         transcriptFillsAvailableHeight: true)

        case .idle, .captured, .finalizing, .complete:
            // Just stopped. The receipt takes the middle; nothing here is about the NEXT
            // reading until this one is dismissed — by the bar's own record button, or by
            // opening the entry. Backdating is not lost: the entry's date is editable on
            // the detail screen, which is built for it.
            if hasReceipt {
                return .init(mode: .receipt,
                             showsLiveTranscript: false,
                             showsReceipt: true,
                             showsDiscardButton: false,
                             transcriptFillsAvailableHeight: false)
            }
            return .init(mode: .ready,
                         showsLiveTranscript: false,
                         showsReceipt: false,
                         showsDiscardButton: false,
                         transcriptFillsAvailableHeight: false)
        }
    }
}
```

Keep the file's leading doc comment on the struct; trim its mention of "which parts … are on screen" if you like, but do not rewrite history in it.

- [ ] **Step 4: Cut the view**

In `Raconte/Capture/UI/CaptureView.swift`:

a. Replace `setupRegion` (the `@ViewBuilder private var setupRegion` and its doc comment, ~lines 138-190) with:

```swift
    /// Journal and backdate — the two things that describe the reading, in every mode
    /// that is not the receipt. Bounded content, so it never scrolls (approach 2 of the
    /// 2026-08-16 IA discussion: "I would rather have none, especially during the
    /// recording"). #118 §3 made Ready the same band as Recording: the last-entry card,
    /// the Two-voices toggle and the recovery banners left for Home, and the full inline
    /// backdate field left for the compact summary's sheet (§6 — backdate "whenever,
    /// basically", so the same one-line summary is on Ready and Recording alike).
    private var setupRegion: some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalHeaderView(model: model, showingJournalPicker: $showingJournalPicker)
            CompactBackdateSummary(model: model)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

b. Delete `lastEntrySection` (the `@ViewBuilder private var lastEntrySection` and its doc comment, ~lines 340-365).

c. Delete the `BackdateField` struct and its doc comment (~lines 596-626: `/// Optional backdate — off by default …` through the struct's closing brace). `BackdateEditorContent` (used by `CompactBackdateSummary`'s sheet) and `CompactBackdateSummary` stay. In `CompactBackdateSummary`'s doc comment, change "One-line, non-scrolling stand-in for `BackdateField` while capturing" to "The one-line backdate summary, on Ready and Recording alike (#118 §6)".

d. Comments across the repo cite `BackdateField` by name for its colour-scheme reasoning. Retarget each to `CompactBackdateSummary` (the same `.environment(\.colorScheme, .dark)` pin, still on this screen) or, where the comment is about the toggle + picker content, to `BackdateEditorContent`. Grep repo-wide, not just this file:

```bash
grep -rn "BackdateField\b" Raconte RaconteTests --include='*.swift'
```

Known sites: `CaptureView.swift` (`JournalHeaderView`, `RecordControlsRow`, `receiptRegion`), `CaptureScreenModel.swift:~1036`, `CaptureSurface.swift:~173`, `PrecisionDatePicker.swift:~79`, `JournalEditorView.swift:~13`, `CompactBackdateSummaryTests.swift:~7`, `PrecisionDatePickerTests.swift:~13, ~232`. Expected after: zero hits. (`usesCompactBackdateField` disappears with Step 3.)

e. Update the `CaptureView` type doc comment (lines 3-5): "The capture screen: journal + backdate on top, the live transcript or the receipt in the middle, the control bar pinned to the bottom (#118)."

In `Raconte/Capture/UI/CaptureSurface.swift`: delete `case recentHeader` and its entries in `labelColor` (`.recentHeader` in the 0.78 grey list) and both `textSize` switches (`case .recentHeader: .headline` / `.title2`).

- [ ] **Step 5: Grep for stragglers, build, test**

```bash
grep -rn "showsLastEntry\|showsMultiVoiceField\|showsRecoveryBanners\|usesCompactBackdateField\|lastEntrySection\|recentHeader\|\.setup\b" Raconte RaconteTests | grep -v "TranscriptionSetup\|setUp"
```

Expected: zero hits. Also `grep -n "RecoveryBanner(" Raconte/Capture/UI/CaptureView.swift` → zero (Home still uses `RecoveryBanner`; do not delete the type).

Run the macOS unit-test command. Expected green; count **2050 − 4 + 1 = 2047** (1 skipped). Run the iOS compile check.

- [ ] **Step 6: Commit**

```bash
git add -A Raconte RaconteTests
git commit -m "feat(capture): Ready is journal + backdate + the bar; four dead layout flags deleted (#118 §3, §6)"
```

---

### Task 3: The receipt card (design §3 Receipt)

**Files:**
- Modify: `Raconte/Capture/UI/CaptureView.swift` (`receiptRegion` ~365-415, `receiptProse` ~420-465)
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift:60-68` (doc comment on `dismissReceipt`)

**Interfaces:**
- Consumes: `RecordControlModel.make(phase: .idle)` → `.action == .record`; `CaptureScreenModel.record()` already sets `receipt = nil` before starting. So the bar's record button ALREADY "dismisses the receipt and starts the next reading in one tap" — nothing to build there, only the duplicate to delete.
- Produces: the receipt's header + prose become ONE `NavigationLink(value: LibraryDestination.entry(receipt.captureID))` carrying `accessibilityIdentifier("capture.receipt.open")`. `capture.receipt.dismiss` no longer exists. `capture.receipt.date`, `capture.receipt.summary`, `capture.receipt.prose` stay as identifiers on their leaf views (they are inside the link and therefore not independently queryable — same as today for `.prose`; the UI tests only query `.date` today, and Task 5 moves that query to the link's label).

- [ ] **Step 1: Rewrite `receiptRegion`**

Replace the `receiptRegion(_:)` function body:

```swift
    private func receiptRegion(_ receipt: CaptureReceipt) -> some View {
        // One scroll view, OUTSIDE the link: long prose scrolls, and a tap anywhere on
        // the card opens the entry. A `ScrollView` inside a link's label loses one of
        // the two gestures on macOS.
        ScrollView {
            NavigationLink(value: LibraryDestination.entry(receipt.captureID)) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(receipt.dateText)
                                .captureLabel(.receiptDate)
                                .accessibilityIdentifier("capture.receipt.date")
                            Spacer()
                            Text("Saved")
                                .captureLabel(.receiptSavedChip)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.green.opacity(0.22)))
                        }
                        Text(receipt.summaryLine)
                            .captureLabel(.receiptSummary)
                            .monospacedDigit()
                            .accessibilityIdentifier("capture.receipt.summary")
                    }

                    receiptProse(receipt)

                    // The card's own caption, not a separate button: owner at smoke —
                    // "Open isn't super clear here… show the entry in a box that's clearly
                    // 'click to open'-able or (view/edit)."
                    HStack(spacing: 4) {
                        Spacer()
                        Text("View / edit")
                            .captureLabel(.receiptSummary)
                        Image(systemName: "chevron.right")
                            .captureLabel(.receiptSummary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            // Dismissed on the way out, not on the way back: returning from the entry
            // you were just reading to a receipt about it is a loop with no exit that
            // feels like progress. (`reconcileReceipt` covers the trash path if this
            // gesture does not fire — #62.)
            .simultaneousGesture(TapGesture().onEnded { model.dismissReceipt() })
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Open entry from \(receipt.dateText)")
            .accessibilityIdentifier("capture.receipt.open")
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
```

The two `Color.white.opacity(…)` literals and `Color.green.opacity(0.22)` are moved into `InkTone` in Task 4; leave them literal here so this task's diff is about structure.

Update the function's doc comment: replace "and have two doors out of them" with "and the whole block is the door to the entry (#118 §3: 'Record another' is gone — the bar's own record button starts the next reading, so the screen offers one record control in one position)".

- [ ] **Step 2: Make `receiptProse` non-scrolling and non-selecting**

In `receiptProse(_:)`, the `else` branch: remove the `ScrollView { … }` wrapper (the outer scroll view now scrolls) and remove `.textSelection(.enabled)` (a selectable text inside a tap target eats the tap). Keep the `VStack`, the `switch`, the serif font, and `.accessibilityIdentifier("capture.receipt.prose")` on the `VStack`. Remove the `Spacer(minLength: 0)` after the unavailable-text case (the card sizes to its content now).

- [ ] **Step 3: Update `dismissReceipt`'s doc comment**

`Raconte/Capture/UI/CaptureScreenModel.swift` ~line 64-68: replace `The "Record another" action, and also what "Open" does on its way to the entry` with `What opening the entry from the receipt does on its way out (#118 §3 deleted "Record another"; the bar's record button retires the receipt through `record()`)`.

- [ ] **Step 4: Grep, build, unit test**

```bash
grep -rn "Record another\|receipt.dismiss" Raconte
```

Expected: zero hits in `Raconte/`. Run the macOS unit-test command (count unchanged at 2047) and the iOS compile check. `CaptureLabelTests.testNoLabelOverridesTheColourCaptureLabelJustGaveIt` scans this file: no `.captureLabel(` line may be immediately followed by a `.foregroundStyle(` line — the card code above respects that; keep it so.

- [ ] **Step 5: Manual look in the simulator (not a test)**

Build and run on `iPhone 17` simulator, record 3 seconds, stop. Confirm: the card has a visible ground and border; "View / edit ›" sits bottom-right; the bar's record button reads "Record"; tapping the card pushes the entry; coming back to Capture via the sidebar shows Ready, not the receipt. Then run on macOS (nocloud entitlements, `build` not `test`) and repeat — the click must open the entry there too.

- [ ] **Step 6: Commit**

```bash
git add -A Raconte
git commit -m "feat(capture): the receipt's entry is a tappable card; Record another removed (#118 §3)"
```

---

### Task 4: Token pass (design §8)

**Files:**
- Modify: `Raconte/Library/UI/InkSurface.swift` (add cases)
- Modify: `Raconte/Library/UI/InkSurface+SwiftUI.swift` (`darkColor` switch)
- Modify: `Raconte/Capture/UI/CaptureView.swift` (every `.white` / `Color.green` / `Color.white` literal)
- Modify: `RaconteTests/InkSurfaceTests.swift`

**Interfaces:**
- Produces: `InkTone.studioInk` (full white on studio), `InkTone.studioInkDim` (the dimmed hypothesis tone — Task 7 consumes it), `InkTone.studioCard` (the receipt card ground), `InkTone.studioHairline` (the card border), `InkTone.studioSaved` (the "Saved" chip ground). All appearance-invariant like `.studio`.

- [ ] **Step 1: Write the failing tests**

Append to `RaconteTests/InkSurfaceTests.swift`:

```swift
    // MARK: #118 §8 — the capture screen's own tones

    /// Text on studio clears the same 7.0:1 floor `CaptureLabel` enforces; the dim tone
    /// is the live transcript's provisional text (#118 §5) and must still be readable,
    /// just visibly weaker than full ink.
    func testStudioTextTonesClearTheCaptureFloor() {
        XCTAssertGreaterThanOrEqual(
            CaptureSurface.contrastOnSurface(InkTone.studioInk.lightColor),
            CaptureSurface.minimumControlContrast)
        XCTAssertGreaterThanOrEqual(
            CaptureSurface.contrastOnSurface(InkTone.studioInkDim.lightColor),
            CaptureSurface.minimumControlContrast)
        XCTAssertLessThan(
            CaptureSurface.relativeLuminance(InkTone.studioInkDim.lightColor),
            CaptureSurface.relativeLuminance(InkTone.studioInk.lightColor) * 0.5,
            "dim must be unmistakably dimmer than ink, not a near-white")
    }

    /// The card and its border are decoration: no WCAG floor, but each must differ from
    /// the studio ground and from each other, or the card disappears.
    func testStudioCardTonesAreDistinct() {
        XCTAssertNotEqual(InkTone.studioCard.lightColor, InkTone.studio.lightColor)
        XCTAssertNotEqual(InkTone.studioHairline.lightColor, InkTone.studio.lightColor)
        XCTAssertNotEqual(InkTone.studioHairline.lightColor, InkTone.studioCard.lightColor)
        XCTAssertNotEqual(InkTone.studioSaved.lightColor, InkTone.studio.lightColor)
    }

    /// Capture tones do not follow the system appearance — the screen is pinned dark.
    func testStudioTonesAreAppearanceInvariant() {
        for tone in [InkTone.studioInk, .studioInkDim, .studioCard, .studioHairline, .studioSaved] {
            XCTAssertEqual(tone.darkColor, tone.lightColor, "\(tone)")
        }
    }
```

- [ ] **Step 2: Run to see them fail**

Expected: compile errors, the cases do not exist.

- [ ] **Step 3: Add the tones**

In `Raconte/Library/UI/InkSurface.swift`, after `case studio`:

```swift
    /// Text on the studio ground — the capture screen's full white (#118 §8; was a
    /// `.white` literal in `CaptureView`).
    case studioInk
    /// The live transcript's provisional text (#118 §5): readable, unmistakably weaker
    /// than `studioInk`. Clears the 7.0:1 capture floor with a little to spare.
    case studioInkDim
    /// The receipt card's ground on studio (#118 §3).
    case studioCard
    /// The receipt card's border on studio.
    case studioHairline
    /// The "Saved" chip's ground — system green at 22% over studio, flattened to a
    /// constant so it can be checked.
    case studioSaved
```

In `lightColor`, add:

```swift
        case .studioInk: .grey(1.0)
        case .studioInkDim: .grey(0.62)
        case .studioCard: .grey(0.11)
        case .studioHairline: .grey(0.17)
        case .studioSaved: CaptureLabelColor(red: 0.08, green: 0.21, blue: 0.12)
```

In `Raconte/Library/UI/InkSurface+SwiftUI.swift`, `darkColor`: change `case .record, .studio: lightColor` to
`case .record, .studio, .studioInk, .studioInkDim, .studioCard, .studioHairline, .studioSaved: lightColor`.

Run the unit target: the three new tests pass. If `testStudioTextTonesClearTheCaptureFloor` fails on the dim tone, raise 0.62 in steps of 0.01 until it clears 7.0 and re-run — do not lower the floor.

- [ ] **Step 4: Replace the literals in `CaptureView`**

```bash
grep -n "\.white\|Color\.green\|Color\.white" Raconte/Capture/UI/CaptureView.swift
```

For each hit that is code (not a comment):
- `.foregroundStyle(.white)` (the body-level one at ~line 96, `JournalHeaderView`'s label, `CompactBackdateSummary`'s) → `.foregroundStyle(InkTone.studioInk.color)`
- `.tint(.white)` → `.tint(InkTone.studioInk.color)`
- `RecordControlsRow`'s flash overlay `.fill(.white)` → `.fill(InkTone.studioInk.color)`
- Receipt card: `Color.white.opacity(0.06)` → `InkTone.studioCard.color`; `Color.white.opacity(0.12)` → `InkTone.studioHairline.color`; `Color.green.opacity(0.22)` → `InkTone.studioSaved.color`
- `.tint(.red)` on the Done button (~line 293) → `.tint(InkTone.record.color)`

Comments that mention `.white` may keep the word where they describe history; update the one at ~line 122 that explains the alert text field ("`CaptureView`, which sets `.foregroundStyle(.white)`") to say `InkTone.studioInk`.

Expected after: `grep -n "\.white\b\|Color\.green\|Color\.white\|\.red\b" Raconte/Capture/UI/CaptureView.swift | grep -v "//"` → zero hits.

- [ ] **Step 5: Build both platforms, run the unit target**

Unit count: **2047 + 3 = 2050** (1 skipped). `CaptureLabelTests.testCaptureViewDoesNotReintroduceTheRawRedErrorBanner` and `…TheDimGreyLiterals…` scan this file — the replacements above satisfy both. Run the iOS compile check. Run the app once on the simulator and eyeball: nothing on the capture screen changed colour visibly (the tones are the literals' values, flattened).

- [ ] **Step 6: Commit**

```bash
git add -A Raconte RaconteTests
git commit -m "refactor(capture): colour literals move into InkTone studio tones (#118 §8)"
```

---

### Task 5: UI test migration and the PR

**Files:**
- Modify: `RaconteUITests/CaptureUITests.swift`
- Modify: `RaconteUITests/CaptureControlsUITests.swift`
- Modify: `RaconteUITests/NavigationUITests.swift`
- Modify: `RaconteUITests/JournalEditorUITests.swift`
- Modify: `RaconteUITests/TranscriptEditorUITests.swift`
- Modify: `RaconteUITests/UITestNavigation.swift` (one new shared helper)

**Interfaces:**
- Consumes: `capture.receipt.open` is a `NavigationLink` with a combined accessibility label that begins with "Open entry from"; `capture.receipt.dismiss`, `capture.recentRow`, `capture.multiVoiceToggle` no longer exist; `capture.backdateSummary` exists on Ready as well as Recording.
- Produces: shared `openReceiptEntry(_:)` and `finishReceipt(_:)` in `UITestNavigation.swift`, replacing the per-class copies.

Two tests are deleted and two added in their place, so the UI count stays at **62**. Every other change is a route change inside an existing test; count parity plus a green run with `continueAfterFailure = false` is the verification.

- [ ] **Step 1: Add the shared helpers**

Append to `RaconteUITests/UITestNavigation.swift`:

```swift
/// Wait for the post-stop receipt and open its entry.
///
/// #118 §3 deleted "Record another", so the receipt has two exits: the bar's record
/// button (which starts the next reading) and the entry card (which pushes the detail
/// screen and retires the receipt on the way). Tests want the second. The receipt
/// appearing is the completion signal — it is built only after the finalizer, the
/// transcript ref and the rescan have all run — so this also replaces the old
/// "recent row appeared" wait.
///
/// `app.descendants(matching: .any)`, not `app.buttons`: a `NavigationLink` is reported
/// as a button on iOS and as a generic element on macOS.
func openReceiptEntry(_ app: XCUIApplication, _ what: String = "recording",
                      file: StaticString = #filePath, line: UInt = #line) {
    let card = app.descendants(matching: .any).matching(identifier: "capture.receipt.open").firstMatch
    guard card.waitForExistence(timeout: 30) else {
        XCTFail("\(what): the post-stop receipt never appeared", file: file, line: line)
        return
    }
    #if os(macOS)
    card.click()
    #else
    card.tap()
    #endif
    XCTAssertTrue(app.buttons["detail.moreButton"].firstMatch.waitForExistence(timeout: 15),
                  "\(what): opening the receipt did not reach the entry", file: file, line: line)
}

/// Finish a recording the way the old "Record another" did — back on Capture, Ready,
/// no receipt. Opens the entry (retiring the receipt) and returns via the sidebar.
func finishReceipt(_ app: XCUIApplication, _ what: String = "recording",
                   file: StaticString = #filePath, line: UInt = #line) {
    openReceiptEntry(app, what, file: file, line: line)
    openCapture(app, file: file, line: line)
    XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 15),
                  "\(what): did not get back to the capture screen", file: file, line: line)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "capture.receipt.open")
                    .firstMatch.exists,
                   "\(what): the receipt survived opening its entry", file: file, line: line)
}
```

Delete the private `finishReceipt` in `CaptureUITests`, `NavigationUITests`, `JournalEditorUITests`. Delete the private `recentRows` helpers in `CaptureUITests` and `NavigationUITests`.

- [ ] **Step 2: `CaptureUITests`**

Per test:

- `testRecordStopProducesFinishedEntry`: after `press(record)` (stop) replace the three lines `finishReceipt … recentRows … record.label` and the `row` assertion with:

```swift
        finishReceipt(app)
        openPlace(app, "sidebar.allEntries")
        let duration = app.staticTexts["library.row.duration"].firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 15), "the finished entry shows no duration")
        XCTAssertNotNil(Self.seconds(duration.label), "duration is not m:ss: \(duration.label)")
```

(`library.row.duration` is the identifier on `LibraryView.swift:~700`; `EntryDetailView` has no duration identifier.) Delete `durationSeconds(in:)` — this was its last caller.

- `testIdleRelaunchShowsNoBannerAndKeepsEntry`: replace `finishReceipt(app); waitUntil(… recentRows == 1)` with `finishReceipt(app)`. After relaunch, replace `openCapture(relaunched); let rows = recentRows(relaunched); waitUntil { rows.count == 1 }` with:

```swift
        openPlace(relaunched, "sidebar.allEntries")
        waitUntil(20, "entry lost across relaunch") { self.libraryRows(relaunched).count == 1 }
```

- `testRepeatedRecordStopCyclesProduceSeparateEntries`: unchanged (it already counts in the library; `finishReceipt` is now the shared one).
- `testScrubbingAFinishedEntryMovesThePosition`: replace `finishReceipt(app); waitUntil(recentRows == 1); … press(recentRow)` (the whole block through `press(recentRow)`) with `openReceiptEntry(app)`.
- `testTrashAndRestoreAnEntry`, `testDeleteNowPermanentlyRemovesEntry`, `testMoveToTrashWhilePlaybackIsRunningStillTrashesTheEntry`: replace `finishReceipt(app); waitUntil(recentRows == 1); waitUntil(Record); press(recentRows.firstMatch)` with `openReceiptEntry(app)`. Replace each `waitUntil(20, "trashed entry still in Recent") { recentRows.count == 0 }` with:

```swift
        openPlace(app, "sidebar.allEntries")
        waitUntil(20, "trashed entry still in the library") { self.libraryRows(app).count == 0 }
```

  In `testDeleteNowPermanentlyRemovesEntry`'s relaunch tail, replace `openCapture(relaunched); XCTAssertTrue(capture.record …); XCTAssertEqual(recentRows(relaunched).count, 0 …)` with `openPlace(relaunched, "sidebar.allEntries")` and `XCTAssertEqual(libraryRows(relaunched).count, 0, "permanently-deleted entry reappeared after relaunch")`.
- `testTrashingTheReceiptsEntryRetiresTheReceipt`: replace the `open` lookup + `press(open)` with `openReceiptEntry(app)`. Replace the final two `waitUntil`s with one:

```swift
        waitUntil(15, "the receipt still names the trashed entry") {
            app.descendants(matching: .any).matching(identifier: "capture.receipt.open").firstMatch.exists == false
        }
```

- `testEmptyTrashPermanentlyRemovesAllTrashedEntries`: inside the loop, first line becomes `waitUntil(15, "record button not ready") { record.label == "Record" && record.isEnabled }` then `press(record)`; replace the receipt/recent block with `openReceiptEntry(app)`; after `press(confirmTrash)` replace the recent-count wait with `openCapture(app)` (the loop needs to be back on Capture for the next press). Relaunch tail: drop the `openCapture(relaunched)` + `capture.record` assertion; go straight to `openPlace(relaunched, "sidebar.trash")`.
- `testVoiceControlsFollowTheMultiVoiceToggle`: **delete**, and delete `setToggle`. Add in its place:

```swift
    // MARK: #118 §4 — the voice switch is in every recording

    /// There is no Two-voices toggle any more. A recording opens with both marker
    /// controls present, the voice switch reading the main voice, and a tap on it flips
    /// the label — that tap is what makes the entry two-voice.
    func testVoiceSwitchIsPresentInEveryRecording() {
        let app = launchApp()
        openCapture(app)
        let record = recordButton(app)
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")
        XCTAssertFalse(app.switches["capture.multiVoiceToggle"].firstMatch.exists,
                       "the Two-voices toggle is gone (#118 §4)")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }

        let voiceSwitch = app.buttons["capture.voiceSwitch"].firstMatch
        let paragraph = app.buttons["capture.paragraph"].firstMatch
        XCTAssertTrue(voiceSwitch.waitForExistence(timeout: 10), "no voice switch while recording")
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10), "no paragraph button while recording")
        XCTAssertEqual(voiceSwitch.label, "BN", "a recording opens in the main voice")

        Thread.sleep(forTimeInterval: 1)
        press(voiceSwitch)
        waitUntil(10, "the voice never flipped") { voiceSwitch.label == "LN" }

        Thread.sleep(forTimeInterval: 1)
        press(record)
        finishReceipt(app)
    }
```

  Keep the `recoveryBanner` helper and `libraryRows` — both still used.

- [ ] **Step 3: `CaptureControlsUITests`**

- `testScrollingThePageDoesNotMoveTheRecordButton`: Ready has no scroll view now. Replace the two `app.scrollViews.firstMatch.swipeUp()` with `app.swipeUp()` twice and update the doc comment: "Ready has no scroll view at all (#118 §3); a page swipe must still leave the bar where it was."
- `testVoiceSwitchStaysPutAndHittableWhileRecording`, `testControlBarTakesAtMostAThirdOfTheScreenWhileRecording`, `testMarkingAVoiceDoesNotMoveTheRecordButtonSideways`: delete the `multiVoice` lookup / `XCTSkip` / `press(multiVoice)` lines. The voice switch is always there; the rest of each test stands. Remove `throws` from the two that only threw for the skip if nothing else throws.
- `testStoppingRaisesAReceiptAndClearsTheLiveTranscript`: replace `dismiss` with the card: `let card = app.descendants(matching: .any).matching(identifier: "capture.receipt.open").firstMatch` and `XCTAssertTrue(card.waitForExistence(timeout: 30), …)`. The `capture.receipt.date` assertion becomes `XCTAssertTrue(card.label.hasPrefix("Open entry from"), "the receipt does not say which entry it is about: \(card.label)")` (the date text is merged into the link's label). Delete the `capture.recentRow` assertion. Replace the tail from `press(dismiss)` to the end with:

```swift
        finishReceipt(app)
        XCTAssertFalse(app.descendants(matching: .any)
                        .matching(identifier: "capture.transcript").firstMatch.exists,
                       "the finished transcript came back on Ready")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "capture.journalHeader")
                        .firstMatch.waitForExistence(timeout: 15),
                      "Ready did not come back")
```

- `testLandingScreenShowsExactlyOneRecentEntryAndAReachableLibrary`: **delete**. Add in its place:

```swift
    /// #118 §3: Ready is journal + backdate + the bar. Nothing that Home already shows is
    /// duplicated here — no last-entry card, no Two-voices toggle — and the backdate is
    /// the same one-line summary Recording shows (§6: "back date whenever, basically").
    func testReadyShowsOnlyJournalAndBackdateAboveTheBar() {
        let app = launchApp()
        openCapture(app)
        let record = app.buttons["capture.record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15), "record button never appeared")

        press(record)
        waitUntil(10, "never entered recording") { record.label == "Stop" }
        Thread.sleep(forTimeInterval: 1)
        press(record)
        finishReceipt(app)

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "capture.journalHeader")
                        .firstMatch.waitForExistence(timeout: 15), "no journal header on Ready")
        XCTAssertTrue(app.buttons["capture.backdateSummary"].firstMatch.exists,
                      "the compact backdate summary must be on Ready too (#118 §6)")
        XCTAssertFalse(app.switches["capture.backdateToggle"].firstMatch.exists,
                       "the full inline backdate field is back on Ready")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "capture.recentRow").count, 0,
                       "the last-entry card is back — Home owns it now")
        XCTAssertFalse(app.switches["capture.multiVoiceToggle"].firstMatch.exists,
                       "the Two-voices toggle is back")
        XCTAssertEqual(app.scrollViews.count, 0, "Ready has nothing to scroll")

        // Everything else is one sidebar tap away.
        openPlace(app, "sidebar.allEntries")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library.list")
                        .firstMatch.waitForExistence(timeout: 15))
    }
```

  Also fix the stale sentence in `testRecordButtonDoesNotMoveWhenRecordingStarts`'s doc comment ("the Two-voices toggle and the Recent list are removed") → "the transcript band appears".

- [ ] **Step 4: `NavigationUITests`, `JournalEditorUITests`, `TranscriptEditorUITests`**

- `NavigationUITests.testTheSidebarIsReachableWhileAReceiptIsUp`: `app.buttons["capture.receipt.dismiss"]` → `app.descendants(matching: .any).matching(identifier: "capture.receipt.open").firstMatch`.
- `NavigationUITests.testSelectingAJournalPlaceScopesTheEntryList`: replace `let dismiss = …; XCTAssertTrue(dismiss.waitForExistence…); press(dismiss)` with `finishReceipt(app)`. The following `capture.journalHeader` query works on Ready.
- `NavigationUITests.testARecordingSurvivesNavigatingAwayAndComingBack`: replace `finishReceipt(app); XCTAssertEqual(recentRows(app).count, 1, …)` with:

```swift
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "capture.receipt.open")
                        .firstMatch.waitForExistence(timeout: 30),
                      "the recording did not commit — no receipt")
```

  Delete the stale doc comment at ~line 62-65 with the helper.
- `JournalEditorUITests.testAJournalWithAnEntryShowsTheDisabledDeleteAffordance`: `finishReceipt(app)` now resolves to the shared helper; nothing else changes. Delete the local copy (Step 1).
- `TranscriptEditorUITests.openSeededEntry`: replace the body with the library route `VoiceMarkingUITests` already uses:

```swift
    private func openSeededEntry(_ app: XCUIApplication) {
        openPlace(app, "sidebar.allEntries")
        let row = app.descendants(matching: .any).matching(identifier: "library.entryLink").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded entry never appeared")
        press(row)
    }
```

- [ ] **Step 5: Grep for stragglers**

```bash
grep -rn "receipt.dismiss\|capture.recentRow\|multiVoiceToggle\|recentRows(" RaconteUITests
```

Expected: only the two deliberate negative assertions in `testReadyShowsOnlyJournalAndBackdateAboveTheBar` and `testVoiceSwitchIsPresentInEveryRecording`, plus comments. Delete comments that describe `capture.recentRow` as a live thing (e.g. `VoiceMarkingUITests` ~line 64: change "the same flattening `capture.recentRow` exists to work around" to "the same flattening every `NavigationLink` row has").

- [ ] **Step 6: Run the UI classes one at a time, foreground**

Run each of these as its own invocation (each under 10 minutes):

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/CaptureUITests test
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/CaptureControlsUITests test
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/NavigationUITests test
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/JournalEditorUITests -only-testing:RaconteUITests/TranscriptEditorUITests -only-testing:RaconteUITests/VoiceMarkingUITests test
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/AboutUITests -only-testing:RaconteUITests/BulkSelectUITests -only-testing:RaconteUITests/EntryDetailSheetUITests -only-testing:RaconteUITests/EntryPagingUITests -only-testing:RaconteUITests/HomeUITests -only-testing:RaconteUITests/ImageCaptureUITests test
```

Per-class counts on main today: Capture 11, CaptureControls 10, Navigation 14, JournalEditor 10, TranscriptEditor 2, VoiceMarking 3, About 1, BulkSelect 1, EntryDetailSheet 2, EntryPaging 3, Home 2, ImageCapture 3. Sum the `Executed N tests` lines: expected **62**, all green. A failure that blames `capture.receipt.open` not being found on a tap is the identifier landing on an inner element — check the `.accessibilityElement(children: .combine)` from Task 3 is on the `NavigationLink`, not the `VStack`.

- [ ] **Step 7: Prove one test RED for the right reason (stash probe)**

`testReadyShowsOnlyJournalAndBackdateAboveTheBar` must fail against the pre-#118 view. Do:

```bash
git stash push Raconte/Capture/UI/CaptureView.swift Raconte/Capture/UI/CaptureLayoutModel.swift
```

Expected: does not compile (Task 1 removed things the old view calls). That is itself acceptable evidence that the test cannot pass vacuously against old code — record it in the PR body. Then `git stash pop`.

- [ ] **Step 8: Commit and open PR A**

```bash
git add -A RaconteUITests
git commit -m "test(ui): migrate off receipt.dismiss and capture.recentRow; voice switch and Ready tests (#118)"
git push -u origin feat/118-capture-reskin
```

Write the PR body to a file and open it with `gh pr create --body-file` (heredocs get mangled). Body: the four sections landed (§3, §4, §6, §8), the disclosed deviation (four flags, not three), the unit and UI counts against the baseline, the stash-probe note, and "Refs #118" — NOT "Closes #118", because PR B is still to come.

---

## PR B — the live transcript

### Task 6: `TranscriptConsolidator.runs`, plumbing, and the timing instrument (design §5, pure half)

**Files:**
- Modify: `Raconte/Transcription/TranscriptConsolidator.swift`
- Modify: `Raconte/Transcription/TranscriptionSession.swift:152-155, 475-480`
- Modify: `Raconte/Transcription/LiveTranscription.swift:58, 90-105, 178-183`
- Modify: `RaconteTests/TranscriptConsolidatorTests.swift`

**Interfaces:**
- Produces:

```swift
struct ConsolidatedTranscriptRun: Equatable, Sendable {
    var text: String
    var range: FrameRange
    var isProvisional: Bool
}
extension TranscriptConsolidator { var runs: [ConsolidatedTranscriptRun] { get } }   // frame-ordered
// TranscriptionSession: var runs: [ConsolidatedTranscriptRun]
// LiveTranscriptionRun:  private(set) var runs: [ConsolidatedTranscriptRun]
// LiveTranscriptionCoordinator: var runs: [ConsolidatedTranscriptRun]
```

  `displayText` everywhere becomes `TranscriptText.join(runs.map(\.text))` so the two cannot drift.
- Produces: `Logger(subsystem: "org.pianohouseproject.raconte", category: "transcript-timing")` lines from `TranscriptionSession.apply`, one per hypothesis settling, carrying `provisionalMs=<n>`.

**The trap the tests must catch.** A hypothesis is NOT reliably a trailing suffix — the
consolidator merges by frame position because results arrive out of order. A fixture
that feeds results in frame order passes a "dim the tail" implementation. The
proof-of-RED step below feeds a provisional run whose frame range PRECEDES committed
text and asserts it is dim in the middle, not at the end.

- [ ] **Step 1: Write the failing tests**

Append to `RaconteTests/TranscriptConsolidatorTests.swift`:

```swift
    // MARK: #118 §5 — runs with a provisional flag

    /// The seam the live transcript dims on is committed vs provisional — not "the tail".
    /// A hypothesis whose frames PRECEDE committed text sits in the middle of the ordered
    /// runs, flagged, with committed text after it. An implementation that dims the last
    /// run fails here; one that appends provisional after committed fails here.
    func testRunsFlagAProvisionalRunThatLandsMidText() {
        var c = TranscriptConsolidator()
        c.apply(result("later", 1_000, 2_000))
        c.apply(result("earlier", 0, 500, volatile: true))
        c.apply(result("last", 2_000, 3_000))
        XCTAssertEqual(c.runs.map(\.text), ["earlier", "later", "last"])
        XCTAssertEqual(c.runs.map(\.isProvisional), [true, false, false],
                       "the hypothesis is FIRST, not last — dimming the tail is wrong")
    }

    /// The ordinary shape too, so the flag is proven in both positions.
    func testRunsFlagATrailingHypothesis() {
        var c = TranscriptConsolidator()
        c.apply(result("settled", 0, 100))
        c.apply(result("guessing", 100, 200, volatile: true))
        XCTAssertEqual(c.runs.map(\.text), ["settled", "guessing"])
        XCTAssertEqual(c.runs.map(\.isProvisional), [false, true])
    }

    /// `displayText` is derived from `runs`, not computed alongside it — same words, same
    /// order, or the screen and the model disagree.
    func testDisplayTextIsTheJoinedRuns() {
        var c = TranscriptConsolidator()
        c.apply(result("later", 1_000, 2_000))
        c.apply(result("earlier", 0, 500, volatile: true))
        c.apply(result("", 300, 400, volatile: true))   // revokes "earlier"
        c.apply(result("middle", 500, 1_000, volatile: true))
        XCTAssertEqual(c.displayText, TranscriptText.join(c.runs.map(\.text)))
        XCTAssertEqual(c.runs.map(\.text), ["middle", "later"])
        XCTAssertEqual(c.runs.map(\.isProvisional), [true, false])
    }

    /// Promotion flips the flag without moving the run — and leaves a still-provisional
    /// run sitting BETWEEN two committed ones.
    ///
    /// The marker rides on a final result over a far range, not a zero-length one at a
    /// boundary: `FrameRange.supersededBy` treats a zero-length range at a neighbour's
    /// endpoint as contained, so a `[200,200)` final would evict `second` instead of
    /// leaving it provisional.
    func testPromotionFlipsTheFlagInPlace() {
        var c = TranscriptConsolidator()
        c.apply(result("first", 0, 100, volatile: true))
        c.apply(result("second", 100, 200, volatile: true))
        var third = result("third", 300, 400)
        third.finalizedThroughFrame = 100
        c.apply(third)
        XCTAssertEqual(c.runs.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(c.runs.map(\.isProvisional), [false, true, false],
                       "first was promoted, second is still a hypothesis, third arrived final")
    }
```

`TranscriptResult.finalizedThroughFrame` is a `var` with a nil default, so assigning it on the helper's result is fine (`TranscriptPromotionTests.swift:21` passes it through the initializer instead; either works).

- [ ] **Step 2: Run to see them fail**

Expected: compile error — `runs` and `ConsolidatedTranscriptRun` do not exist.

- [ ] **Step 3: Implement `runs`**

In `Raconte/Transcription/TranscriptConsolidator.swift`, before `struct TranscriptConsolidator`:

```swift
/// One span of the live transcript, in frame order, with the one distinction the screen
/// can honestly draw (#118 §5): committed text is what the transcriber stands behind;
/// provisional is the hypothesis it may still revise. Sentence boundaries are not tracked
/// anywhere in the pipeline, so "current sentence vs earlier" is unbuildable — this is
/// the real seam.
struct ConsolidatedTranscriptRun: Equatable, Sendable {
    var text: String
    var range: FrameRange
    var isProvisional: Bool
}
```

Replace `displayText` (lines ~115-124) with:

```swift
    /// Committed and provisional runs merged by FRAME POSITION, not arrival order, and
    /// not "committed then provisional". Results arrive out of order often enough that a
    /// hypothesis can precede committed text; appending it after would render it in the
    /// wrong place — visibly, the moment it happens. The screen dims on `isProvisional`,
    /// never on position, for the same reason.
    var runs: [ConsolidatedTranscriptRun] {
        let all = committed.map { ConsolidatedTranscriptRun(text: $0.text, range: $0.range, isProvisional: false) }
                + provisional.map { ConsolidatedTranscriptRun(text: $0.text, range: $0.range, isProvisional: true) }
        return all.sorted { $0.range.start < $1.range.start }
    }

    /// Committed text plus the live hypothesis — the capture screen's ghost text. Derived
    /// from `runs` so the two cannot drift. Never persist this.
    var displayText: String { TranscriptText.join(runs.map(\.text)) }
```

Run the unit target: the four new tests pass, the thirteen old ones still pass.

- [ ] **Step 4: Plumb `runs` to the coordinator**

`Raconte/Transcription/TranscriptionSession.swift` line ~153, add beside `displayText`:

```swift
    var runs: [ConsolidatedTranscriptRun] { consolidator.runs }
```

`Raconte/Transcription/LiveTranscription.swift`:

- `LiveTranscriptionRun`: add `private(set) var runs: [ConsolidatedTranscriptRun] = []` beside `displayText`. In the ticker (lines ~90-96):

```swift
                while !Task.isCancelled {
                    let runs = await session.runs
                    await MainActor.run {
                        self?.runs = runs
                        self?.displayText = TranscriptText.join(runs.map(\.text))
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
```

  After `consume` returns (lines ~98-104): set `self?.runs = final.isEmpty ? [] : [ConsolidatedTranscriptRun(text: final, range: FrameRange(start: 0, end: 0), isProvisional: false)]` beside `displayText = final`.
- `LiveTranscriptionCoordinator`: add beside `displayText`:

```swift
    /// The active run's runs; outside a capture, the last completed text as one
    /// committed run (the receipt covers this on the ordinary path — see `displayText`).
    var runs: [ConsolidatedTranscriptRun] {
        if let id = activeCaptureID, let run = runs[id] { return run.runs }
        return lastCompletedText.isEmpty
            ? [] : [ConsolidatedTranscriptRun(text: lastCompletedText, range: FrameRange(start: 0, end: 0), isProvisional: false)]
    }
```

  Rename the private dictionary `runs: [String: LiveTranscriptionRun]` to `liveRuns` first (it collides), updating its five or so uses in the file.

Build both platforms. Unit target still green.

- [ ] **Step 5: The timing instrument**

In `Raconte/Transcription/TranscriptionSession.swift`, add `import os` if absent, and to the actor:

```swift
    /// #118 §5 "check first": wall-clock first-seen time per provisional range start, so
    /// the owner can read how long text stays provisional in real speech before the
    /// dimmed-hypothesis view is built. Diagnostic only; nothing reads it.
    private var provisionalFirstSeen: [Int64: ContinuousClock.Instant] = [:]
    private let timing = Logger(subsystem: "org.pianohouseproject.raconte", category: "transcript-timing")
```

Replace `apply(_:)` (line ~475):

```swift
    private func apply(_ result: TranscriptResult) {
        let now = ContinuousClock.now
        if result.isVolatile, !result.text.isEmpty, provisionalFirstSeen[result.range.start] == nil {
            provisionalFirstSeen[result.range.start] = now
        }
        let before = Set(consolidator.provisional.map(\.range.start))
        for logged in consolidator.apply(result) {
            persist(logged)
        }
        let after = Set(consolidator.provisional.map(\.range.start))
        for start in before.subtracting(after) {
            guard let seen = provisionalFirstSeen.removeValue(forKey: start) else { continue }
            let ms = (now - seen).components.attoseconds / 1_000_000_000_000_000
                + (now - seen).components.seconds * 1_000
            let how = result.isVolatile ? "superseded" : "settled"
            timing.info("\(how, privacy: .public) start=\(start, privacy: .public) provisionalMs=\(ms, privacy: .public)")
        }
    }
```

A range that leaves `provisional` did so by promotion, by a final superseding it, or by
a new volatile replacing it (`superseded`). The owner reads the `settled` lines for the
window and the `superseded` ones for churn.

Build both platforms. This is diagnostic code with no test; the PR body says so.

- [ ] **Step 6: Commit and push the branch (no PR yet)**

```bash
git add -A Raconte RaconteTests
git commit -m "feat(transcription): TranscriptConsolidator.runs with a provisional flag; provisional-window timing log (#118 §5)"
git push -u origin feat/118-live-transcript
```

Then STOP. Tell the owner the branch is up and hand over the measurement steps from "The measurement gate" above, restated in full.

---

### Task 7: The dimmed-hypothesis view (design §5, view half) — GATED

**Do not start until (a) the owner has reported the provisional window from Task 6's
log, and (b) PR A is merged and this branch is rebased onto main.** If the window came
back short (median under ~1.5 s), stop and re-plan this task with the owner instead of
building it as written.

**Files:**
- Create: `Raconte/Capture/UI/LiveTranscriptText.swift`
- Modify: `Raconte/Capture/UI/CaptureView.swift` (`transcriptRegion`, ~192-216 after PR A)
- Create: `RaconteTests/LiveTranscriptTextTests.swift`

**Interfaces:**
- Consumes: `LiveTranscriptionCoordinator.runs: [ConsolidatedTranscriptRun]`; `InkTone.studioInk`, `InkTone.studioInkDim` (PR A Task 4).
- Produces: `LiveTranscriptText.attributed(_ runs: [ConsolidatedTranscriptRun], ink: Color, dim: Color) -> AttributedString` (pure, tested) and a `LiveTranscriptText` view.

- [ ] **Step 1: Write the failing tests**

`RaconteTests/LiveTranscriptTextTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Raconte

/// #118 §5. The live transcript dims the HYPOTHESIS, wherever it sits — never "the tail".
final class LiveTranscriptTextTests: XCTestCase {

    private func run(_ text: String, _ start: Int64, provisional: Bool) -> ConsolidatedTranscriptRun {
        ConsolidatedTranscriptRun(text: text, range: FrameRange(start: start, end: start + 100), isProvisional: provisional)
    }

    private func colours(_ s: AttributedString) -> [(String, Color?)] {
        s.runs.map { (String(s[$0.range].characters), $0.foregroundColor) }
    }

    /// The trap: a provisional run that precedes committed text is dim in the MIDDLE.
    func testAMidTextHypothesisIsDimAndTheTailIsNot() {
        let runs = [run("earlier", 0, provisional: true),
                    run("later", 1_000, provisional: false),
                    run("last", 2_000, provisional: false)]
        let s = LiveTranscriptText.attributed(runs, ink: .white, dim: .gray)
        XCTAssertEqual(String(s.characters), "earlier later last")
        let c = colours(s)
        XCTAssertEqual(c.first?.1, .gray, "the hypothesis is dim")
        XCTAssertEqual(c.last?.1, .white, "the committed tail is NOT dim")
    }

    func testCommittedIsInkAndProvisionalIsDim() {
        let runs = [run("settled", 0, provisional: false), run("guessing", 100, provisional: true)]
        let c = colours(LiveTranscriptText.attributed(runs, ink: .white, dim: .gray))
        XCTAssertEqual(c.map(\.1), [.white, .gray])
        XCTAssertEqual(c.map(\.0), ["settled ", "guessing"])
    }

    func testEmptyRunsIsEmptyText() {
        XCTAssertEqual(String(LiveTranscriptText.attributed([], ink: .white, dim: .gray).characters), "")
    }

    /// Adjacent runs of the same kind may merge into one attributed run; the words and
    /// the separator must survive that.
    func testWordsAreSeparatedBySingleSpaces() {
        let runs = [run("a", 0, provisional: false), run("b", 100, provisional: false),
                    run("c", 200, provisional: true)]
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, ink: .white, dim: .gray).characters), "a b c")
    }
}
```

- [ ] **Step 2: Regenerate and run to see them fail**

```bash
xcodegen generate
```

Expected: compile error, `LiveTranscriptText` does not exist.

- [ ] **Step 3: Implement**

`Raconte/Capture/UI/LiveTranscriptText.swift`:

```swift
import SwiftUI

/// The live transcript (#118 §5): committed text at full strength, the hypothesis dimmed,
/// merged by frame position. Dims on `isProvisional`, never on position — the consolidator
/// merges out-of-order results, so a hypothesis can land mid-text, and "dim the tail" is
/// wrong on exactly the case the consolidator exists to handle.
///
/// Serif, matching the receipt: the same words in the same face from the moment they
/// appear. `CaptureProse.font` is shared with `receiptProse` for that reason.
struct LiveTranscriptText: View {
    let runs: [ConsolidatedTranscriptRun]

    var body: some View {
        Text(Self.attributed(runs, ink: InkTone.studioInk.color, dim: InkTone.studioInkDim.color))
            .font(CaptureProse.font)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pure, so the dim-in-the-middle rule is testable without a renderer. Runs are joined
    /// with single spaces; the separator takes the colour of the run before it.
    static func attributed(_ runs: [ConsolidatedTranscriptRun], ink: Color, dim: Color) -> AttributedString {
        var out = AttributedString()
        for run in runs where !run.text.isEmpty {
            var piece = AttributedString(run.text)
            piece.foregroundColor = run.isProvisional ? dim : ink
            if !out.characters.isEmpty {
                var space = AttributedString(" ")
                space.foregroundColor = out.runs.last?.foregroundColor
                out.append(space)
            }
            out.append(piece)
        }
        return out
    }
}

/// The one reading face on the capture screen — receipt prose and live transcript.
enum CaptureProse {
    static let font: Font = .system(.callout, design: .serif)
}
```

In `CaptureView.receiptProse`, replace `.font(.system(.callout, design: .serif))` with `.font(CaptureProse.font)`.

Replace the body of `transcriptRegion`'s `if` branch:

```swift
        if layout.showsLiveTranscript,
           let transcription = model.transcription, !transcription.runs.isEmpty {
            ScrollView {
                LiveTranscriptText(runs: transcription.runs)
            }
            .frame(maxHeight: layout.transcriptFillsAvailableHeight ? .infinity : 160)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("capture.transcript")
        }
```

Keep the doc comment about `showsLiveTranscript` FIRST (the stranded-text bug).

- [ ] **Step 4: Run the unit target; UI classes that touch the transcript**

Unit: the four new tests pass; count = post-PR-A baseline + 4 (read it off main's CI after PR A merges). UI: run `CaptureControlsUITests` foreground — `testOnlyOneScrollableRegionExistsWhileRecording` and `testStoppingRaisesAReceiptAndClearsTheLiveTranscript` are the ones that see the transcript band.

- [ ] **Step 5: Manual look on the Mac (owner-smoke build) and simulator**

Record 20 seconds of speech on the Mac build. Confirm the hypothesis is visibly dimmer and settles to full white without the whole band flashing. If the band flickers continuously, stop: that is the §5 concern realised, and the fix is a design decision (a minimum-provisional-age before dimming), not a tweak here.

- [ ] **Step 6: Commit and open PR B**

```bash
git add -A Raconte RaconteTests
git commit -m "feat(capture): live transcript dims the hypothesis, not the tail (#118 §5)"
git push
```

PR body via `--body-file`: the measured provisional window (median / max, from the owner), the trap and the test that pins it, the counts, and **"Closes #118"** — this is the PR that finishes the issue.

---

## Traps (read before each task)

- **`multiVoice` on the sidecar is a synced LWW field.** Task 1 changes WHEN it is written, never what it means. Touch nothing in `Raconte/Sync/`.
- **`CaptureCoordinator.markOpeningVoice` writes at frame 0 by construction**, so a late opener still sorts first. Do not "fix" it to use the clock.
- **Deleting a `CaptureLabel` case** is safe: every `CaptureLabelTests` assertion quantifies over `allCases`. `PrecisionDatePickerTests:130` pins `.backdateDateButton` by name — that case stays.
- **`RecoveryBanner` the type stays.** Home renders it. Task 2 deletes only capture's loop.
- **The receipt card identifier goes on the `NavigationLink`** with `.accessibilityElement(children: .combine)`. Put it on the inner `VStack` and `capture.receipt.open` is unqueryable — the exact #65 failure.
- **`app.scrollViews.count == 0` on Ready** (Task 5's new test) will fail if anyone re-wraps the setup band in a `ScrollView`. That is the test doing its job.
- **`testStoppingRaisesAReceiptAndClearsTheLiveTranscript`'s `card.label` check** depends on the accessibility label `"Open entry from …"` from Task 3. Change one, change both.
- **PR B Task 7 edits `CaptureView.swift`.** Rebase onto main after PR A merges, before starting it.
- **Do not run the whole UI suite in one Bash call.** It exceeds the tool's 10-minute cap and reads exactly like a hang.
- **Three unit tests scan `CaptureView.swift` / `Raconte/Capture/UI` as SOURCE:** `CaptureLabelTests` (every `CaptureLabel` case must be applied somewhere; no `.captureLabel(` line followed by `.foregroundStyle(`; no `.foregroundStyle(.red)`; no `Color(white: 0.55/0.6/0.7)`), `JournalHeaderSourceTests` (`selectJournal`, `New Journal`, `dateLine(forJournal:` must stay; `JournalCoverThumbnail` must not appear), `LibraryRescanObserverTests` (comment only). A failure in one of these after a view edit is the scan doing its job — fix the view, not the test.

## Out of scope (design §9)

Back destination from an entry (#86); time of day on rows (#125, shipped); whether the
record button should be red; `transcriptFillsAvailableHeight` (now only ever true when
the band is shown — a vestigial flag, but the design did not name it and deleting it is a
separate one-line PR if the reviewer wants it).
