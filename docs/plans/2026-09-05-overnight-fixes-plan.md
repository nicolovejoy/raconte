# Overnight Fixes (2026-09-05) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the owner-approved overnight slate as five independent PRs, each branched
from `main`, each ending at an open PR for the owner to merge in order: #140 + #122 + #130
(capture screen), #139 + #75 + #77 + #47 + #105 (small fixes), #141 (build numbering),
#43 + #51 + #70 (core hardening), #136 (live paragraph break, stretch).

**Architecture:** Every task is a bounded change to code that already exists. Pure-core
work is test-first (`PartialDate`, `TranscriptChain`, `AtomicFile`, `Journal`'s coder,
`LiveTranscriptText.attributed`). View work is pinned by the smallest honest test: a pure
static rule with a unit test, a source scan, or one UI test class. Nothing here touches
`CaptureMachine`, sync ingest, or the capture phase dispatch except Task 2's one-line
queue consumption.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency,
XcodeGen project, XCTest + XCUITest.

**Spec:** The owner's rulings in the 2026-09-05 evening session, restated per task
below (there is no separate design doc; each issue body is the spec, plus the ruling).
Owner rulings, verbatim in substance:
1. PR #138 is merged; everything branches from `main` at or after `4fa98f8f`.
2. Grouped PRs by area, merged in the order listed above, "Update branch" between merges.
3. #140: delete the WHOLE discard path (model logic, tests, plumbing), not just the button.
   #123 closes as moot.
4. #141: N is `CFBundleVersion`, bumped for every build the owner is handed (smoke or
   TestFlight), starting at 14. Row reads `build 14: <date>`. List lives in
   `docs/builds.md`. "Build 18" was a guess.
5. The recording lost on 2026-09-05 was test input; no Trash check needed.
6. Stretch: #136 only.

## Global Constraints

- **Branch per PR, from `main`.** Five branches: `feat/140-capture-discard-removal`,
  `feat/small-fixes-2026-09`, `feat/141-build-number`, `feat/core-hardening-2026-09`,
  `feat/136-live-paragraph`. Each PR's body uses `Closes #N` only for issues it fully
  resolves. PR bodies via `--body-file`, never a heredoc. **Merges are the owner's.**
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
- **Baseline from main's latest code-carrying CI run** (PR #138 merge, 2026-09-05):
  unit **2060** (1 skipped), UI **62**. Each task states its expected delta. Verify the
  main run at https://github.com/nicolovejoy/raconte/actions/runs/34010380697 reports
  these before trusting them.
- **Straggler grep covers all three targets**: `grep -rn <token> Raconte RaconteTests
  RaconteUITests docs CLAUDE.md` for every deleted symbol/identifier/test name, and drive
  present-tense hits to zero. For prose, grep a single word that cannot wrap.
- Source-scanning tests strip comments before matching (repo memory).
- Every test written here must be shown RED first (run it before the production change,
  or stash the production change and run it), and the RED reason must be the right one.
- Prefer `.notice` over `.info` for any log the owner may read back.
- No `Image` in a macOS `Menu` label; `.sheet` only on a screen's outer view.
- Commit messages end with the session attribution trailer the harness supplies.

---

## PR 1 — capture screen: `feat/140-capture-discard-removal`

Branch from `main`. Closes #140, #123 (moot), #122, #130.

### Task 1: Remove the Discard path entirely (#140, closes #123 as moot)

**Files:**
- Modify: `Raconte/Capture/UI/CaptureView.swift` (lines ~72-93 notice, ~164-167 comment, ~262-281 button)
- Modify: `Raconte/Capture/UI/CaptureLayoutModel.swift` (lines 51-59, 86, 98, 104)
- Modify: `Raconte/Capture/UI/CaptureSurface.swift` (cases `discardNotice`, `discardButton` at ~181-193, 218, 241, 251)
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift` (lines 39-61, 69, 421-423, 495-563, 767-782, 821-857, 868-879)
- Modify: `RaconteTests/CaptureLayoutModelTests.swift` (lines 143-171, and the `showsDiscardButton` line in `testNoRemainingFlagIsConstant`)
- Modify: `RaconteTests/CaptureScreenModelTests.swift` (delete lines 490-765, the six `Discard` tests)
- Modify: `RaconteTests/CaptureLabelTests.swift` (doc comment at 188-200 references the discard notice as history; reword to past tense, keep the test)
- Modify: `RaconteUITests/NavigationUITests.swift` (delete `testDiscardEndsTheCaptureAndLeavesNoReceipt`, lines 440-460)
- Modify: `docs/plans/2026-08-29-record-flow.md` (one superseded note at the top of its Discard section)

**Interfaces:**
- Consumes: nothing new.
- Produces: `CaptureLayoutModel` without `showsDiscardButton`; `CaptureScreenModel` without
  `discardNotice`, `discardCurrentCapture()`, `pendingDiscardID`. Task 2 edits the same
  `finishCurrentCapture` afterwards and assumes this shape.

- [ ] **Step 1: Delete the tests first, so the suite is RED on the missing symbols**

Delete from `RaconteTests/CaptureLayoutModelTests.swift`: the `// MARK: Discard button`
block — `testDiscardIsOfferedWhileRecording`, `testDiscardIsOfferedWhileInterrupted`,
`testDiscardIsHiddenInMachineBusyPhases`, `testDiscardIsHiddenWhenNothingIsInFlight` —
and this one line inside `testNoRemainingFlagIsConstant`:

```swift
        XCTAssertTrue(all.contains { $0.showsDiscardButton } && all.contains { !$0.showsDiscardButton })
```

Delete from `RaconteTests/CaptureScreenModelTests.swift` the whole `// MARK: Discard
(record-flow plan, Task 2)` section: `testDiscardFinalizesTheCaptureAndThenTrashesIt`,
`testDiscardTrashesTheCaptureTheOwnerDiscardedNotARecoveredBacklog`,
`testDiscardLeavesNoReceipt`, `testTheCaptureAfterADiscardIsKeptNormally`,
`testADiscardWhoseStopNeverTookDoesNotTrashTheReadingThatFollows`,
`testDiscardFromIdleIsANoOp`. **Keep a copy of
`testDiscardTrashesTheCaptureTheOwnerDiscardedNotARecoveredBacklog`'s recovered-backlog
fixture (the manifest + m4a planting, lines 544-572) in a scratch file** — Task 2 reuses
it verbatim.

Delete from `RaconteUITests/NavigationUITests.swift`:
`testDiscardEndsTheCaptureAndLeavesNoReceipt` and its doc comment.

- [ ] **Step 2: Remove the production code**

`CaptureView.swift`: delete the `if let notice = model.discardNotice { … }` block and its
comment, the `.animation(.easeInOut, value: model.discardNotice)` modifier and its
comment, and the `if layout.showsDiscardButton { Button("Discard") … }` block with its
"Quiet, not red" comment. Rewrite the `transcriptRegion` comment that says "Discard sets
`receipt = nil`, which uncovered it" to:

```swift
        // `layout.showsLiveTranscript` FIRST, not just "is there text". The transcription
        // session deliberately holds the finished text after a capture ends (so the panel
        // doesn't blank the instant you stop) and a fresh coordinator does not clear it —
        // it belongs to the session, not the coordinator. Anything that clears `receipt`
        // in a non-capturing phase would otherwise strand the previous reading's words on
        // the landing screen (#53); asking the layout, not the text, is what prevents it.
```

`CaptureLayoutModel.swift`: delete the `showsDiscardButton` property and its doc comment,
and the `showsDiscardButton:` argument at all three `.init(` sites.

`CaptureSurface.swift`: delete cases `discardNotice` and `discardButton` (with doc
comments) and remove them from the three `switch` lists (`labelColor`, both `textSize`
branches).

`CaptureScreenModel.swift`:
- delete `discardNotice`, `pendingDiscardID` (with its long doc comment), `discardNoticeTask`;
- in `record()`, delete the three lines `discardNoticeTask?.cancel()`, `discardNotice = nil`, `pendingDiscardID = nil`;
- delete `discardCurrentCapture()` and its doc comment;
- in `finishCurrentCapture()`, delete the snapshot block (`let discardingID = pendingDiscardID` / `pendingDiscardID = nil` and the comment above it), and replace the whole `if let discardingID { … } else { await buildReceipt(for: transcribed) }` block with:

```swift
        await buildReceipt(for: transcribed)
```

- delete `showDiscardNotice()`.

`CaptureLabelTests.swift` lines 188-200: keep `testNoLabelOverridesTheColourCaptureLabelJustGaveIt`; reword its comment's present-tense references so it reads as history ("the discard notice, since removed by #140, did exactly that…") and drop the sentence "The fix is a case of its own (`discardNotice`), not an override."

`docs/plans/2026-08-29-record-flow.md`: at the first heading that introduces Discard, insert:

```markdown
> **Superseded 2026-09-05 (#140):** the Discard button and the whole discard path were
> removed — the owner hit it by accident and lost a recording. Deliberate deletion is the
> library's trash flow. #123 closed as moot with it.
```

- [ ] **Step 3: Straggler grep to zero**

Run:

```
grep -rn "discardNotice\|discardButton\|pendingDiscardID\|discardCurrentCapture\|showsDiscardButton\|capture\.discard\|Discarded to Trash\|showDiscardNotice\|discardingID" Raconte RaconteTests RaconteUITests CLAUDE.md
```

Expected: zero hits. Then grep the single word `Discard` (capital D) in the same paths and
review each hit: hits must be either about `.discardEngine`/`.discardFinalPart`/
`discardParkedState` (unrelated machine effects) or past-tense history. Fix any
present-tense claim that the capture screen offers Discard.

- [ ] **Step 4: Build and run the affected unit classes**

Run the macOS unit command with `-only-testing:RaconteTests/CaptureLayoutModelTests -only-testing:RaconteTests/CaptureScreenModelTests -only-testing:RaconteTests/CaptureLabelTests`.
Expected: green. Then the full macOS unit suite: expected **2050** executed (2060 − 10), 1 skipped.
Then the iOS compile check: expected `BUILD SUCCEEDED`.

- [ ] **Step 5: Run the affected UI class**

`-only-testing:RaconteUITests/NavigationUITests` on the iPhone 17 simulator. Expected: green, one fewer test than the class had (verify with `grep -c "func test" RaconteUITests/NavigationUITests.swift` before and after).

- [ ] **Step 6: Commit**

```bash
git add -A Raconte RaconteTests RaconteUITests docs/plans/2026-08-29-record-flow.md
git commit -m "feat(capture): remove the Discard button and the whole discard path (#140)

The owner hit Discard by accident during the #138 smoke and lost a recording.
Audio is ground truth; a one-tap path that trashes it does not belong on the
recording surface. Deliberate deletion is the library's trash flow. Removes
the button, the notice, the layout flag, the two surface label cases, the
model's discard intent and its six tests, and the UI round trip. #123 is moot."
```

- [ ] **Step 7: Delete `selectedJournalCover` (#130) in the same PR**

In `Raconte/Capture/UI/CaptureScreenModel.swift` delete the property and its doc comment:

```swift
    /// Cover image for the currently selected journal, sourced from `library` —
    /// the same store/scan the Library screen reads (M3's one-data-path rule, applied
    /// to covers too).
    var selectedJournalCover: Data? {
        selectedJournalID.flatMap { library.journalCovers[$0] }
    }
```

Grep `selectedJournalCover` across `Raconte RaconteTests RaconteUITests` → zero. Build
(macOS unit command, `-only-testing:RaconteTests/CaptureScreenModelTests`) → green, count unchanged. Commit:

```bash
git commit -am "chore(capture): delete CaptureScreenModel.selectedJournalCover (#130)

Zero references in all three targets; its doc comment asserted a one-data-path
policy the capture screen no longer participates in. #118's ratified design has
no cover affordance on the capture screen."
```

### Task 2: Consume the launch-recovery backlog so a phase flip cannot drain it (#122)

**Files:**
- Modify: `Raconte/Capture/CaptureCoordinator.swift` (near `enqueueFinalize`, line ~712)
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift` (`performBootstrap`, lines ~352-375; `handleFinalizeQueue` doc comment, lines ~564-573)
- Test: `RaconteTests/CaptureScreenModelTests.swift` (new test after `testLaunchRecoveryQueueDoesNotRespawnCoordinator`)

**Interfaces:**
- Produces: `CaptureCoordinator.consumeFinalized(_ ids: [String])` — removes those ids from `finalizeQueue`; no-op for ids not present.

**Why this shape, not the issue's first suggestion.** `send()` publishes `phase` before
`realize` on purpose: the DEBUG transition gate sits between them and `handlePhase` is
keyed off `.recording` landing early. Moving the publish would touch every phase handler.
The actual defect is narrower: `finalizeQueue` is append-only, so after `bootstrap` has
drained the recovered ids they sit in the live coordinator's queue forever, and the first
`.captured` flip of a real capture finds a non-empty queue and finishes the wrong thing.
Consuming the drained ids makes the queue mean "committed and not yet finished", which is
the meaning `handleFinalizeQueue` already assumes.

- [ ] **Step 1: Write the failing test**

Add to `RaconteTests/CaptureScreenModelTests.swift` right after
`testLaunchRecoveryQueueDoesNotRespawnCoordinator`:

```swift
    /// #122: a launch that healed an orphaned capture leaves that capture's id in the live
    /// coordinator's `finalizeQueue`. The next real capture's phase flips to `.captured`
    /// BEFORE `enqueueFinalize` runs, and `handleFinalizeQueue` then drains the stale
    /// backlog, spawns a fresh coordinator, and orphans the one the real capture is about
    /// to enqueue on — so the real capture never finalizes until the next launch.
    func testACaptureAfterALaunchRecoveredBacklogStillFinalizesInSession() async throws {
        // Same orphan fixture as the launch-healed sync test above: a capture killed at
        // `.finalizing` with its m4a already on disk, which recovery hands to the finalizer.
        let recoveredID = "01J000000000000000000122"
        let dir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: recoveredID)
        try FileManager.default.createDirectory(
            at: SegmentLayout.finalDirectory(captureDirectory: dir), withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02, 0x03]).write(
            to: SegmentLayout.finalRecordingURL(captureDirectory: dir))
        let manifestFmt = AudioFormatDescriptor(sampleRate: 48000, channels: 1,
                                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let manifest = Manifest(captureID: recoveredID, createdAt: Date(timeIntervalSince1970: 0),
                                state: .finalizing, stateSeq: 7,
                                stateUpdatedAt: Date(timeIntervalSince1970: 0),
                                format: manifestFmt, segmentCount: 3,
                                lastKnownFrameOffset: 2500)
        try AtomicFile.replace(at: SegmentLayout.manifestURL(captureDirectory: dir),
                               writing: CaptureCoding.encoder().encode(manifest))

        let recorder = ModelFakeRecorder()
        let encoder = FakeAudioEncoder()
        encoder.verifyOverride = VerifyResult(decodable: true, decodedFrameCount: 2500, nonSilent: true)
        let model = CaptureScreenModel(
            capturesRoot: root,
            makeSession: { ModelFakeSession() },
            makeRecorder: { recorder },
            encoder: encoder)
        await model.bootstrap()

        let live = model.coordinator
        XCTAssertTrue(live.finalizeQueue.isEmpty,
                      "after bootstrap has drained the recovered backlog, nothing may be left "
                      + "in the live coordinator's queue for a later phase flip to act on")

        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        let liveID = try XCTUnwrap(live.activeCaptureID)
        XCTAssertNotEqual(liveID, recoveredID)
        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "no coordinator reset")

        let liveDir = SegmentLayout.captureDirectory(capturesRoot: root, captureID: liveID)
        await waitUntil({
            FileManager.default.fileExists(atPath: SegmentLayout.finalRecordingURL(captureDirectory: liveDir).path)
        }, timeout: 10, "the real capture was stranded — its m4a never appeared in-session")
        XCTAssertEqual(Set(model.library.items.map(\.captureID)), [recoveredID, liveID],
                       "both the healed backlog and the real capture must be in the library")
    }
```

- [ ] **Step 2: Run it to verify it fails for the right reason**

Run the macOS unit command with `-only-testing:RaconteTests/CaptureScreenModelTests/testACaptureAfterALaunchRecoveredBacklogStillFinalizesInSession`.
Expected: FAIL on the first assertion ("nothing may be left in the live coordinator's
queue"). Then temporarily comment that assertion out and re-run: expected FAIL on "the
real capture was stranded" — that is the #122 race reproduced. Restore the assertion.

- [ ] **Step 3: Implement**

`CaptureCoordinator.swift`, directly under `enqueueFinalize`:

```swift
    /// The launch-recovery counterpart of `enqueueFinalize` (#122). `finalizeQueue` is
    /// the hand-off surface for "committed, not yet finished"; `recoverAtLaunch()` fills
    /// it and `CaptureScreenModel.bootstrap()` drains it in place, WITHOUT respawning
    /// this coordinator. Without this call the drained ids stay queued forever, and the
    /// first real capture's `.captured` flip — which the machine publishes before
    /// `enqueueFinalize` has run for that capture — finds a non-empty queue, finishes
    /// the stale backlog, spawns a fresh coordinator, and orphans this one with the real
    /// capture still on it. Ids not present are ignored.
    func consumeFinalized(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let consumed = Set(ids)
        finalizeQueue.removeAll { consumed.contains($0) }
    }
```

`CaptureScreenModel.performBootstrap()`: immediately before `await library.rescan()`
(after the `FinalizeArtifactPush.push` loop), add:

```swift
        // #122: the backlog is finished; take it off the live coordinator's queue so the
        // next real capture's early `.captured` flip finds nothing to drain.
        coordinator.consumeFinalized(recoveredQueue)
```

Update `handleFinalizeQueue`'s doc comment's last sentence to:

```swift
    /// The phase guard skips launch-recovery fills (`bootstrap` drains those itself and
    /// then `consumeFinalized` takes them off the queue — #122).
```

- [ ] **Step 4: Run the class, then the full unit suite**

`-only-testing:RaconteTests/CaptureScreenModelTests` → green, the new test passes.
Grep the tests for any other assertion on `finalizeQueue` after `bootstrap()` (`grep -n "finalizeQueue" RaconteTests/*.swift`) and fix any that expected the recovered ids to remain. Full macOS unit suite: expected **2051** executed (2050 + 1). iOS compile check green.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Capture/CaptureCoordinator.swift Raconte/Capture/UI/CaptureScreenModel.swift RaconteTests/CaptureScreenModelTests.swift
git commit -m "fix(capture): consume the launch-recovered finalize backlog after bootstrap (#122)

finalizeQueue was append-only, so the ids bootstrap had already finished stayed
queued on the live coordinator. The next capture's .captured flip is published
before enqueueFinalize runs, so handleFinalizeQueue drained the stale backlog,
respawned the coordinator and orphaned the real capture. Regression test plants
the orphan fixture, records, stops, and asserts the m4a lands in-session."
```

### Task 3: Open PR 1

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feat/140-capture-discard-removal
```

Write the body to a scratch file, then `gh pr create --title "Capture: remove Discard; finish captures after a recovered backlog (#140, #122, #130)" --body-file <file>`. The body: what changed per commit, "Closes #140, closes #122, closes #130, closes #123 (moot — the discard path no longer exists)", the unit count 2051 against main's 2060 (−10 deleted discard tests, +1 regression), UI 61 against 62 (−1), which UI class was run locally, and the smoke step for the owner: on the Mac, open Capture, record, confirm there is no Discard control anywhere on the screen, stop, confirm the receipt appears.

---

## PR 2 — small fixes: `feat/small-fixes-2026-09`

Branch from `main` (NOT from PR 1 — file sets are disjoint except `CaptureView.swift`
line 115, which Task 5 touches only in a line PR 1 does not).
Closes #139, #75, #77, #47, #105.

### Task 4: Indent the sidebar's journal rows (#139)

**Files:**
- Modify: `Raconte/App/SidebarView.swift` (`SidebarRowView.titleGroup`, line ~115)
- Create: `RaconteTests/SidebarRowInsetTests.swift` (then `xcodegen generate`)

**Interfaces:**
- Produces: `SidebarRowView.leadingInset(isJournal: Bool) -> CGFloat` — 14 for journal rows, 0 otherwise.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Raconte

/// #139: journal rows sit under Capture as children of the list, and the owner wants
/// the hierarchy to read at a glance — an indent on the journal rows only.
final class SidebarRowInsetTests: XCTestCase {
    func testJournalRowsAreIndentedAndSystemRowsAreNot() {
        XCTAssertGreaterThan(SidebarRowView.leadingInset(isJournal: true), 0)
        XCTAssertEqual(SidebarRowView.leadingInset(isJournal: false), 0)
    }

    /// The rule must actually be applied to the row, or the test above pins nothing.
    func testTheRowAppliesTheInsetRule() throws {
        let source = try String(contentsOfFile: SourcePaths.file("Raconte/App/SidebarView.swift"), encoding: .utf8)
        let code = SourceScan.strippingComments(source)
        XCTAssertTrue(code.contains("leadingInset(isJournal: row.journalID != nil)"),
                      "SidebarRowView must pad its title group by leadingInset(isJournal:)")
    }
}
```

Before writing this, check what source-scan helpers already exist (`grep -rn "strippingComments\|func captureUISources\|SourcePaths" RaconteTests | head`). Use the existing helper names in place of `SourcePaths.file` / `SourceScan.strippingComments`; if none exists that strips comments, add a tiny one to this test file:

```swift
private func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            if let range = line.range(of: "//") { return String(line[..<range.lowerBound]) }
            return String(line)
        }
        .joined(separator: "\n")
}
```

and locate the file relative to `#filePath` the way `CaptureLabelTests.captureUISources()` does.

- [ ] **Step 2: `xcodegen generate`, run, verify RED**

Expected: compile error, `leadingInset` undefined.

- [ ] **Step 3: Implement**

In `SidebarRowView`:

```swift
    /// #139: journal rows are the children of this list — Capture and the system rows
    /// are its spine — so they take one indent step and nothing else does.
    static func leadingInset(isJournal: Bool) -> CGFloat { isJournal ? 14 : 0 }
```

and in `titleGroup`, on the outer `HStack(spacing: 10) { … }`, add `.padding(.leading, Self.leadingInset(isJournal: row.journalID != nil))`.

- [ ] **Step 4: Run and verify GREEN; run `NavigationUITests` on the simulator** (the sidebar journal query `label BEGINSWITH … AND identifier BEGINSWITH 'sidebar.journal.'` must still resolve). Full unit count expected **2062** (2060 + 2).

- [ ] **Step 5: Commit**

```bash
git add Raconte/App/SidebarView.swift RaconteTests/SidebarRowInsetTests.swift
git commit -m "feat(sidebar): indent journal rows under the list's spine (#139)"
```

### Task 5: One rule for a journal's entry count (#75)

**Files:**
- Modify: `Raconte/Library/LibraryScreenModel.swift` (next to `dateLine(forJournal:)`, line ~328)
- Modify: `Raconte/Library/UI/LibraryView.swift:377`, `Raconte/Library/UI/JournalEditorView.swift:38-40`, `Raconte/Library/UI/EntryDetailView.swift:318`, `Raconte/Capture/UI/CaptureView.swift:115`
- Test: `RaconteTests/LibraryScreenModelTests.swift`, `RaconteTests/JournalHeaderSourceTests.swift`

**Interfaces:**
- Produces: `LibraryScreenModel.entryCount(forJournal journalID: String) -> Int` — live (non-trashed) entries filed under the journal, independent of `journalScope`.

- [ ] **Step 1: Failing model test** (after `testDateRangeIsIndependentOfJournalScope`):

```swift
    /// #75: the header card read `items.count` (scope-filtered) while the editor counted
    /// `allEntries` — 40 vs 6 for the same journal in the frames before a rescan landed.
    func testEntryCountIsIndependentOfJournalScope() async throws {
        try writeJournals([journal("J1", "1987"), journal("J2", "Trip")])
        try writeCapture(idA, capturedAt: 1_000, journalID: "J1")
        try writeCapture(idB, capturedAt: 2_000, journalID: "J1")
        try writeCapture(idC, capturedAt: 3_000, journalID: "J2")

        let model = model()
        await model.selectJournalScope(.journal("J2"))
        XCTAssertEqual(model.items.count, 1, "precondition: the scope narrows items")
        XCTAssertEqual(model.entryCount(forJournal: "J1"), 2)
        XCTAssertEqual(model.entryCount(forJournal: "J2"), 1)
        XCTAssertEqual(model.entryCount(forJournal: "nope"), 0)
    }
```

- [ ] **Step 2: Failing source pin** in `JournalHeaderSourceTests` (follow the file's existing style for reading `LibraryView.swift`): assert the LibraryView source contains `entryCount(forJournal:` and does NOT contain `entryCount: model.items.count`.

- [ ] **Step 3: Run both → RED** (compile error on `entryCount(forJournal:)`; source pin fails).

- [ ] **Step 4: Implement**

```swift
    /// The one entry-count rule for a journal (#75): live entries filed under it, from
    /// `allEntries` — never `items`, which is scope-filtered and lags a scope change by
    /// one async rescan. `dateLine(forJournal:)` above is the same rule for the date.
    func entryCount(forJournal journalID: String) -> Int {
        allEntries.filter { $0.journalID == journalID }.count
    }
```

Call sites: `LibraryView.swift:377` → `entryCount: model.entryCount(forJournal: journal.id)`; `JournalEditorView.swift` private `entryCount` → `model.entryCount(forJournal: journalID)`; `EntryDetailView.swift:318` → `entryCount: { model.entryCount(forJournal: $0) }`; `CaptureView.swift:115` → `entryCount: { model.library.entryCount(forJournal: $0) }`.

- [ ] **Step 5: Run `LibraryScreenModelTests`, `JournalHeaderSourceTests` → GREEN. Full unit expected 2062 + 1 (model) + 1 (source pin, if written as its own test) = up to 2064.** Commit:

```bash
git commit -am "fix(library): one entryCount(forJournal:) rule for header, editor, picker and capture (#75)"
```

### Task 6: Pin the PartialDate → picker → JournalSpan round trip (#77)

**Files:**
- Test: `RaconteTests/JournalSpanEditorTests.swift`

- [ ] **Step 1: Write the property test**

```swift
    /// #77: the seam nothing composed. A `.year` value anchors to 1 Jan; re-reading that
    /// anchor at `.day` precision would silently promote "1998" to "1 Jan 1998". The round
    /// trip must be the identity at every precision.
    func testPartialDateSurvivesTheAnchorThenPickerThenSpanRoundTripAtEveryPrecision() throws {
        let calendar = Calendar.gregorianCurrent
        let originals = [PartialDate(year: 1998),
                         PartialDate(year: 1998, month: 3),
                         PartialDate(year: 1998, month: 3, day: 4)]
        for original in originals {
            let pickerDate = original.anchorDate(calendar: calendar)
            let span = try XCTUnwrap(JournalSpanEditorModel.span(
                startDate: pickerDate, startPrecision: original.precision,
                endDate: pickerDate, endPrecision: original.precision,
                isOpenEnded: false, calendar: calendar))
            XCTAssertEqual(span.start, original, "\(original) did not survive as start")
            XCTAssertEqual(span.end, original, "\(original) did not survive as end")
        }
    }
```

- [ ] **Step 2: Run → GREEN (it is a pin). Prove it can fail:** temporarily change `startPrecision: original.precision` to `startPrecision: .day` and run → FAIL on the `.year` and `.yearMonth` cases. Revert.

- [ ] **Step 3: Commit** — `git commit -am "test(journal): pin the PartialDate→picker→JournalSpan round trip at every precision (#77)"`. Unit count +1.

### Task 7: Backdate pre-fill advances to the next day (#47)

**Files:**
- Modify: `Raconte/Library/PartialDate.swift` (new `nextDay(calendar:)`)
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift` (`finishCurrentCapture`, after `await buildReceipt(for: transcribed)`; helper near `rememberBackdate`)
- Test: `RaconteTests/PartialDateTests.swift`, `RaconteTests/BackdateCarryOverTests.swift`

**Design (answers to the issue's four questions):**
1. "Recent" = this session: `carriedBackdates` is in-memory, so the rule cannot reach across launches by construction.
2. Increment ONLY at `.day` precision; `.yearMonth` / `.year` carry unchanged.
3. Precedence with spoken-date detection is unchanged: the advanced value is written as a manual backdate at record time exactly as a carried one is today. The owner opened the field; the app pre-filled it. If detection should outrank a pre-fill, that is a separate `backdateOrigin` change (see `docs/plans/2026-08-03-backdate-precedence-ux.md` §4) and out of scope here.
4. Never a future date: if the next day would be future (`PartialDate.isFuture`), keep the same day.
The advance happens when a capture COMMITS (end of `finishCurrentCapture`), so the dial the owner sees for the next reading already says the next day, and the just-finished entry's sidecar (written at record time) is untouched.

- [ ] **Step 1: Failing `PartialDate` tests**

```swift
    func testNextDayAdvancesADayPrecisionValue() {
        XCTAssertEqual(PartialDate(year: 1987, month: 6, day: 12).nextDay(calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertEqual(PartialDate(year: 1987, month: 12, day: 31).nextDay(calendar: .gregorianCurrent),
                       PartialDate(year: 1988, month: 1, day: 1))
    }

    func testNextDayIsNilBelowDayPrecision() {
        XCTAssertNil(PartialDate(year: 1987, month: 6).nextDay(calendar: .gregorianCurrent))
        XCTAssertNil(PartialDate(year: 1987).nextDay(calendar: .gregorianCurrent))
    }
```

- [ ] **Step 2: Failing model test** in `BackdateCarryOverTests` (use the file's `makeModel()` and `date(_:_:_:)` helpers; feed frames through a `CarryOverFakeRecorder` instance you keep a reference to — mirror how `CaptureScreenModelTests` keeps `recorder`):

```swift
    /// #47: consecutive pages are usually consecutive days. Once a day-precision backdated
    /// capture commits, the dial for the next one reads the day after.
    func testADayPrecisionBackdateAdvancesToTheNextDayAfterACaptureCommits() async throws {
        let recorder = CarryOverFakeRecorder()
        let model = CaptureScreenModel(capturesRoot: root,
                                       makeSession: { CarryOverFakeSession() },
                                       makeRecorder: { recorder },
                                       encoder: FakeAudioEncoder())
        await model.bootstrap()
        model.setBackdateEnabled(true)
        model.setBackdatePrecision(.day)
        model.setBackdateDate(date(1987, 6, 12))

        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")

        XCTAssertEqual(PartialDate(from: model.backdateDate, precision: model.backdatePrecision,
                                   calendar: .gregorianCurrent),
                       PartialDate(year: 1987, month: 6, day: 13))
        XCTAssertEqual(model.carriedBackdate(), PartialDate(year: 1987, month: 6, day: 13),
                       "the carry-over is the NEXT entry's date, so toggling off and on pre-fills the advanced day")
    }

    /// Only `.day` advances — a journal covering 1998 does not turn a page per year.
    func testAYearMonthBackdateDoesNotAdvance() async throws {
        let recorder = CarryOverFakeRecorder()
        let model = CaptureScreenModel(capturesRoot: root,
                                       makeSession: { CarryOverFakeSession() },
                                       makeRecorder: { recorder },
                                       encoder: FakeAudioEncoder())
        await model.bootstrap()
        model.setBackdateEnabled(true)
        model.setBackdatePrecision(.yearMonth)
        model.setBackdateDate(date(1987, 6, 12))

        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")

        XCTAssertEqual(model.carriedBackdate(), PartialDate(year: 1987, month: 6))
        XCTAssertEqual(model.backdatePrecision, .yearMonth)
    }

    /// Never into the future: a backdate of today stays today.
    func testABackdateOfTodayDoesNotAdvanceIntoTheFuture() async throws {
        let recorder = CarryOverFakeRecorder()
        let model = CaptureScreenModel(capturesRoot: root,
                                       makeSession: { CarryOverFakeSession() },
                                       makeRecorder: { recorder },
                                       encoder: FakeAudioEncoder())
        await model.bootstrap()
        let today = PartialDate(from: Date(), precision: .day, calendar: .gregorianCurrent)
        model.setBackdateEnabled(true)
        model.setBackdatePrecision(.day)
        model.setBackdateDate(today.anchorDate(calendar: .gregorianCurrent))

        let live = model.coordinator
        await model.record()
        await waitUntil({ live.phase == .recording }, "never started recording")
        recorder.feed(frames: 48_000)
        await model.done()
        await waitUntil({ model.coordinator !== live }, timeout: 10, "capture never finished")

        XCTAssertEqual(model.carriedBackdate(), today, "tomorrow would be refused at the sidecar — keep today")
    }
```

`CarryOverFakeRecorder` needs a `feed(frames:)` — copy `ModelFakeRecorder`'s `lock`/`sink`/`feed` implementation from `CaptureScreenModelTests.swift` lines 15-33 into it. `waitUntil` — copy the helper from `CaptureScreenModelTests.swift` lines 50-60.

- [ ] **Step 3: Run → RED** (`nextDay` undefined; model tests fail on the unchanged date once it compiles — check that reason by stubbing `nextDay` first).

- [ ] **Step 4: Implement**

`PartialDate.swift`:

```swift
    /// The following calendar day, at `.day` precision only (#47). `nil` below day
    /// precision: a journal covering 1998 does not advance a year per page.
    func nextDay(calendar: Calendar) -> PartialDate? {
        guard precision == .day else { return nil }
        guard let next = calendar.date(byAdding: .day, value: 1, to: anchorDate(calendar: calendar)) else { return nil }
        return PartialDate(from: next, precision: .day, calendar: calendar)
    }
```

`CaptureScreenModel.swift`, next to `rememberBackdate()`:

```swift
    /// #47: after a day-precision backdated capture commits, pre-fill the NEXT reading
    /// with the following day — consecutive pages of a paper journal are usually
    /// consecutive days. Only `.day` advances; never into the future (the field would
    /// then be silently refused at `EntryMetadata.setOriginalDate`). Sets the properties
    /// directly rather than through `setBackdateDate`, which would try to sync a sidecar
    /// for a capture that has already finished.
    private func advanceBackdateForNextEntry(now: Date = Date()) {
        guard backdateEnabled, backdatePrecision == .day else { return }
        let current = PartialDate(from: backdateDate, precision: .day, calendar: .gregorianCurrent)
        guard let next = current.nextDay(calendar: .gregorianCurrent),
              !next.isFuture(now: now) else { return }
        backdateDate = next.anchorDate(calendar: .gregorianCurrent)
        rememberBackdate()
    }
```

and in `finishCurrentCapture()`, immediately after `await buildReceipt(for: transcribed)`: `advanceBackdateForNextEntry()`.

- [ ] **Step 5: Run `PartialDateTests`, `BackdateCarryOverTests`, `JournalCaptureContextTests` → GREEN. Full unit: +5. Commit:**

```bash
git commit -am "feat(capture): day-precision backdate pre-fills the next day after a capture commits (#47)"
```

### Task 8: Copy an entry's whole transcript (#105)

**Files:**
- Create: `Raconte/App/Clipboard.swift`
- Modify: `Raconte/Library/EntryTranscript.swift` (new `copyText`)
- Modify: `Raconte/Library/UI/EntryInfoSheet.swift` (new optional row), `Raconte/Library/UI/EntryDetailView.swift` (action case + dispatch)
- Create: `RaconteTests/EntryTranscriptCopyTextTests.swift`
- Modify: `RaconteUITests/EntryDetailSheetUITests.swift`
- Then `xcodegen generate`.

**Interfaces:**
- Produces: `Clipboard.copy(_ text: String)`; `EntryTranscript.copyText: String?`; `EntryInfoSheet.onCopyTranscript: (() -> Void)?` (nil hides the row); identifier `detail.copyTranscriptButton`.

- [ ] **Step 1: Failing pure test**

```swift
import XCTest
@testable import Raconte

/// #105: one action copies the whole transcript. Paragraph structure (voice/¶ markers)
/// is kept as blank-line breaks, so what lands on the clipboard reads like the screen.
final class EntryTranscriptCopyTextTests: XCTestCase {
    func testPlainTextCopiesVerbatim() {
        let t = EntryTranscript(state: .present, text: "one two", degradations: [])
        XCTAssertEqual(t.copyText, "one two")
    }

    func testAttributedParagraphsAreJoinedWithBlankLines() {
        var t = EntryTranscript(state: .present, text: "one two three", degradations: [])
        t.paragraphs = [
            TranscriptAttribution.Paragraph(voice: "bn", text: "one two", approximateBoundary: false),
            TranscriptAttribution.Paragraph(voice: "ln", text: "three", approximateBoundary: false),
        ]
        XCTAssertEqual(t.copyText, "one two\n\nthree")
    }

    func testNothingToCopyIsNil() {
        XCTAssertNil(EntryTranscript(state: .absent, text: nil, degradations: []).copyText)
        XCTAssertNil(EntryTranscript(state: .present, text: "", degradations: []).copyText)
    }
}
```

Check `TranscriptAttribution.Paragraph`'s real memberwise init (`sed -n 12,35p Raconte/Library/TranscriptAttribution.swift`) and use its actual labels.

- [ ] **Step 2: `xcodegen generate`, run → RED (no `copyText`).**

- [ ] **Step 3: Implement**

`EntryTranscript.swift`:

```swift
    /// #105: the whole transcript as one string for the clipboard. Paragraphs, when the
    /// entry has them, are separated by a blank line; otherwise the plain text verbatim.
    /// `nil` when there is nothing to copy.
    var copyText: String? {
        if let paragraphs, !paragraphs.isEmpty {
            let joined = paragraphs.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            return joined.isEmpty ? nil : joined
        }
        guard let text, !text.isEmpty else { return nil }
        return text
    }
```

`Raconte/App/Clipboard.swift`:

```swift
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The one clipboard write in the app (#105). Platform-split here so no view carries an
/// `#if` for it.
enum Clipboard {
    @MainActor
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
```

`EntryInfoSheet.swift`: add `let onCopyTranscript: (() -> Void)?` after `onEditTranscript`, and between the "Edit transcript" row and "Mark voices" row:

```swift
                if let onCopyTranscript {
                    hairline
                    row(systemImage: "doc.on.doc", label: "Copy transcript",
                        trailingValue: nil,
                        identifier: "detail.copyTranscriptButton", action: onCopyTranscript)
                }
```

`EntryDetailView.swift`: add `case copyTranscript` to `InfoSheetAction`; at the `EntryInfoSheet(` call site add `onCopyTranscript: transcript.copyText == nil ? nil : { pendingInfoAction = .copyTranscript; showingInfoSheet = false }`; in `performPendingInfoAction` add `case .copyTranscript: if let text = transcript.copyText { Clipboard.copy(text) }`.

- [ ] **Step 4: UI test** in `EntryDetailSheetUITests` (read the class's existing seeding + sheet-open steps at lines 1-60 and follow them exactly):

```swift
    /// #105: one action copies the whole transcript. The simulator shares one pasteboard
    /// with the test runner, so the copied text can be read back here.
    func testCopyTranscriptPutsTheWholeTextOnThePasteboard() {
        // The class's own `launchApp()` seeds a marker entry (RACONTE_UITEST_SEED_MARKER_ENTRY)
        // with transcript text; `openFirstEntry` is its existing helper.
        let app = launchApp()
        openFirstEntry(app)
        let more = app.buttons["detail.moreButton"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "`⋯` toolbar button missing on detail")
        more.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "detail.infoSheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "info sheet did not present")
        let copy = app.buttons["detail.copyTranscriptButton"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "copy row missing on an entry with a transcript")
        copy.tap()
        let expected = app.descendants(matching: .any).matching(identifier: "detail.transcript.text").firstMatch.label
        let deadline = Date().addingTimeInterval(5)
        while (UIPasteboard.general.string ?? "").isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertFalse((UIPasteboard.general.string ?? "").isEmpty, "nothing landed on the pasteboard")
        XCTAssertTrue(expected.contains(UIPasteboard.general.string!.prefix(20)) || UIPasteboard.general.string!.contains(expected.prefix(20)),
                      "pasteboard text does not match the transcript on screen")
    }
```

`UIPasteboard` needs `import UIKit` in the UI test file (it is iOS-only; the RaconteUI scheme runs on the simulator only). If the seeded entry in that class has no transcript text, seed one the way the class's fixtures do, or pick the fixture the edit test uses.

- [ ] **Step 5: Run unit (`EntryTranscriptCopyTextTests`, `EntryInfoSheetTests`) → GREEN; `EntryDetailSheetUITests` on the simulator → GREEN with the new test executed; iOS compile + macOS build both green (the `#if canImport` split is the thing to prove). Unit +3, UI +1. Commit:**

```bash
git commit -am "feat(detail): copy the whole transcript from the entry's info sheet (#105)"
```

Then push and open PR 2 (`Closes #139, #75, #77, #47, #105`), body via `--body-file`, counts against the baseline, and a Mac smoke: sidebar journal rows visibly indented; on an entry, ⋯ → Copy transcript → paste into TextEdit.

---

## PR 3 — build numbering: `feat/141-build-number`

Branch from `main`. Closes #141.

### Task 9: `build N: <date>` in About, `docs/builds.md`, bump to 14

**Files:**
- Modify: `Raconte/App/BuildInfo.swift`
- Modify: `project.yml` (line 51-52)
- Create: `docs/builds.md`
- Modify: `scripts/upload_testflight.sh` (the header comment and the final `echo`)
- Modify: `CLAUDE.md` (the "Owner-smoke app build" recipe: one sentence)
- Create: `RaconteTests/BuildInfoTests.swift` (then `xcodegen generate`)
- `RaconteUITests/AboutUITests.swift` stays as is (the row identifier does not change).

**Interfaces:**
- Produces: `BuildInfo.stampText(build: String?, builtAt: Date?) -> String` (pure); `BuildInfo.stamp` becomes `stampText(build: <CFBundleVersion>, builtAt: builtAt)`.

- [ ] **Step 1: Failing pure tests**

```swift
import XCTest
@testable import Raconte

/// #141: the About row reads `build N: <date>` — N is CFBundleVersion, bumped for every
/// build the owner is handed, and the date is the link time in Pacific.
final class BuildInfoTests: XCTestCase {
    private let sep5 = ISO8601DateFormatter().date(from: "2026-09-05T17:26:00Z")!  // 10:26 AM PDT

    func testNumberAndDateRenderAsBuildNColonDate() {
        XCTAssertEqual(BuildInfo.stampText(build: "14", builtAt: sep5), "build 14: Sep 5, 10:26 AM PT")
    }

    func testMissingNumberFallsBackToTheOldBuiltForm() {
        XCTAssertEqual(BuildInfo.stampText(build: nil, builtAt: sep5), "built Sep 5, 10:26 AM PT")
        XCTAssertEqual(BuildInfo.stampText(build: "", builtAt: sep5), "built Sep 5, 10:26 AM PT")
    }

    func testMissingDateStillShowsTheNumber() {
        XCTAssertEqual(BuildInfo.stampText(build: "14", builtAt: nil), "build 14: date unavailable")
        XCTAssertEqual(BuildInfo.stampText(build: nil, builtAt: nil), "build date unavailable")
    }

    /// The bundle really carries the number the row shows — the pin against a stale
    /// project.yml comment or an Info.plist that lost the key.
    func testTheLiveStampCarriesTheBundlesBuildNumber() throws {
        let build = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertTrue(BuildInfo.stamp.hasPrefix("build \(build): "), BuildInfo.stamp)
    }
}
```

- [ ] **Step 2: `xcodegen generate`, run → RED (`stampText` undefined).**

- [ ] **Step 3: Implement** — replace `BuildInfo.stamp`:

```swift
    /// `build N: <date>` (#141). N is `CFBundleVersion`, bumped in project.yml for every
    /// build the owner is handed — smoke or TestFlight — and described in
    /// `docs/builds.md`. The date keeps the link-time stamp: two builds can share N only
    /// by mistake, and when they do the time is what tells them apart.
    static func stampText(build: String?, builtAt: Date?) -> String {
        let number = build.flatMap { $0.isEmpty ? nil : $0 }
        let dateText: String? = builtAt.map { date in
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
            formatter.dateFormat = "MMM d, h:mm a"
            return "\(formatter.string(from: date)) PT"
        }
        switch (number, dateText) {
        case let (n?, d?): return "build \(n): \(d)"
        case let (n?, nil): return "build \(n): date unavailable"
        case let (nil, d?): return "built \(d)"
        case (nil, nil): return "build date unavailable"
        }
    }

    static let stamp: String = stampText(
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        builtAt: builtAt)
```

Keep `builtAt` and the "Always Pacific" comment. Set the formatter's `locale` to `Locale(identifier: "en_US_POSIX")` so the test's expected string is stable on any machine.

`project.yml`: `CFBundleVersion: "14"` and the comment above it → `# Bump CFBundleVersion for EVERY owner-facing build (smoke or TestFlight) and append docs/builds.md (#141).`

`docs/builds.md`:

```markdown
# Builds

One line per build the owner is handed, smoke or TestFlight. `N` is `CFBundleVersion`
in `project.yml`; About → App → Build shows `build N: <link date>`. Bump N and add a
line here in the same commit as the build. Not retroactive — starts at 14 (#141).

| N | date | branch / SHA | what it is |
|---|------|--------------|------------|
| 14 | (pending) | `feat/141-build-number` | first numbered build; #140 Discard removal, #122 finalize fix, #139/#75/#77/#47/#105 small fixes, #141 this row |
```

(Fill the date and SHA when the build is actually made; leave `(pending)` until then.)

`scripts/upload_testflight.sh`: in the header comment add `# Bump CFBundleVersion in project.yml AND append docs/builds.md before running (#141).`; change the final echo to `echo "== Done: build $BUILD ($PLATFORM) uploaded — add build $BUILD to docs/builds.md if not already there"`.

`CLAUDE.md`, in the "Owner-smoke app build (macOS)" paragraph, add one sentence: "Bump `CFBundleVersion` and append `docs/builds.md` first — About shows `build N: <date>` (#141)."

- [ ] **Step 4: Run `BuildInfoTests` → GREEN; `AboutUITests` on the simulator → GREEN (row still present). Full unit +4. Commit:**

```bash
git add -A Raconte/App/BuildInfo.swift RaconteTests/BuildInfoTests.swift project.yml docs/builds.md scripts/upload_testflight.sh CLAUDE.md
git commit -m "feat(about): Build row reads 'build N: <date>'; docs/builds.md; bump to 14 (#141)"
```

Push and open PR 3 (`Closes #141`).

---

## PR 4 — core hardening: `feat/core-hardening-2026-09`

Branch from `main`. Closes #43, #51, #70.

### Task 10: Unique staging name for `AtomicFile.createExclusively` (#43, first half)

**Files:**
- Modify: `Raconte/Capture/AtomicFile.swift` (`createExclusively`)
- Modify: `Raconte/Capture/SegmentLayout.swift` (new `exclusiveStagingURL(for:)` next to `partURL`)
- Test: `RaconteTests/AtomicFileTests.swift`

**Interfaces:**
- Produces: `SegmentLayout.exclusiveStagingURL(for url: URL) -> URL` = `<name>.<uuid>.part`; `createExclusively(at:writing:beforeRename:)` gains the same optional seam `replace` has.

- [ ] **Step 1: Failing test**

```swift
    /// #43: two concurrent creates of the same target used to share ONE `.part` path, so
    /// the EEXIST loser's `unlink` deleted the winner's staging file mid-write. Each call
    /// now stages under its own name. Modelled with the `beforeRename` seam: call 1 is
    /// parked (throws) with its staging file written; call 2 must not truncate or remove
    /// it on its way to the target.
    func testEachCreateStagesUnderItsOwnNameSoALoserCannotClobberAWinner() throws {
        let target = dir.appendingPathComponent("head.json")
        struct Parked: Error {}
        XCTAssertThrowsError(try AtomicFile.createExclusively(at: target, writing: Data("A".utf8),
                                                              beforeRename: { throw Parked() }))
        let staged = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(staged.count, 1, "the parked call must leave exactly its own staging file")
        let parkedURL = dir.appendingPathComponent(staged[0])
        XCTAssertEqual(try read(parkedURL), Data("A".utf8))

        try AtomicFile.createExclusively(at: target, writing: Data("B".utf8))

        XCTAssertEqual(try read(target), Data("B".utf8))
        XCTAssertEqual(try read(parkedURL), Data("A".utf8),
                       "the second create must stage under a different name — the parked writer's bytes are untouched")
    }
```

Also update `testCreateExclusivelyWritesFullContentWithNoStrayPart` and `testCreateExclusivelyCleansUpPartAfterEEXIST` to assert "no file in `dir` ends with `.part`" instead of checking `SegmentLayout.partURL(for: target)`.

- [ ] **Step 2: Run → RED** (no `beforeRename` parameter; once stubbed, the parked file is truncated/renamed by call 2 under the shared name).

- [ ] **Step 3: Implement**

`SegmentLayout.swift`:

```swift
    /// A per-call staging sibling for `AtomicFile.createExclusively` (#43):
    /// `head.json` -> `head.json.<uuid>.part`. Distinct from `partURL(for:)` so two
    /// concurrent creates of one target never share a staging file. Still ends in
    /// `.part`, so every "ignore stray parts" rule in the scanners applies unchanged.
    static func exclusiveStagingURL(for url: URL) -> URL {
        url.appendingPathExtension(UUID().uuidString.lowercased()).appendingPathExtension(partExtension)
    }
```

`AtomicFile.createExclusively`: signature `static func createExclusively(at url: URL, writing data: Data, beforeRename: (() throws -> Void)? = nil) throws`; `let partURL = SegmentLayout.exclusiveStagingURL(for: url)`; call `try beforeRename?()` after the `close` guard, before `renamex_np`, exactly as `replace` does. Update the doc comment: "stages `data` at a per-call `<url>.<uuid>.part`".

Confirm the chain listing ignores the new name: `SegmentLayout.canonicalRevision(fromFileName:)` requires the `.json` suffix, so `canonical-3.json.<uuid>.part` is skipped. Grep `hasSuffix(".part")` and `partURL(for:` across `Raconte` to confirm no reader constructs the exclusive staging path from `partURL`.

- [ ] **Step 4: Run `AtomicFileTests`, `TranscriptRevisionStoreTests`, `TranscriptDraftLifecycleTests` → GREEN. Unit +1. Commit:**

```bash
git commit -am "fix(atomicfile): per-call staging name for createExclusively (#43)"
```

### Task 11: Deterministic revision mint instants (#43 second half, #51)

**Files:**
- Modify: `Raconte/Transcription/TranscriptChain.swift` (new `mintInstant`)
- Modify: `Raconte/Transcription/TranscriptRevisionStore.swift` (the three mint sites: `closeDraft` ~line 948-961, `revert…` ~1073, `promoteIfNeeded` ~1159)
- Test: `RaconteTests/TranscriptChainTests.swift`, `RaconteTests/TranscriptDraftLifecycleTests.swift`

**Interfaces:**
- Produces: `TranscriptChain.mintInstant(now: Date, after ordered: [TranscriptRevision]) -> Date` — `now` truncated to the encoder's millisecond precision, bumped to `tip.createdAt + 1 ms` if that is not strictly later than the chain's last revision.

- [ ] **Step 1: Failing chain tests**

```swift
    /// #43: `createdAt` is encoded at millisecond precision, so a mint must already be at
    /// that precision or the in-memory chain and its re-decoded self can order differently.
    func testMintInstantTruncatesToMilliseconds() {
        let now = Date(timeIntervalSince1970: 1_000.123_456_789)
        XCTAssertEqual(TranscriptChain.mintInstant(now: now, after: []).timeIntervalSince1970,
                       1_000.123, accuracy: 0.000_000_1)
    }

    /// #51: two mints inside one millisecond tied on `createdAt` and fell to a random
    /// ULID suffix, so `current` could land on the earlier one. A mint is always strictly
    /// after the chain's last revision.
    func testMintInstantIsStrictlyAfterTheChainTipUnderAFrozenClock() {
        let frozen = Date(timeIntervalSince1970: 2_000)
        let tip = TranscriptRevision(id: ULID.make(now: frozen), source: .userEdit, createdAt: frozen, spans: [])
        let minted = TranscriptChain.mintInstant(now: frozen, after: TranscriptChain.ordered([tip]))
        XCTAssertGreaterThan(minted, tip.createdAt)
        XCTAssertEqual(minted.timeIntervalSince(tip.createdAt), 0.001, accuracy: 0.000_000_1)
    }

    func testMintInstantLeavesALaterClockAlone() {
        let tip = TranscriptRevision(id: "01J0000000000000000000T1", source: .userEdit,
                                     createdAt: Date(timeIntervalSince1970: 2_000), spans: [])
        let later = Date(timeIntervalSince1970: 2_005)
        XCTAssertEqual(TranscriptChain.mintInstant(now: later, after: [tip]), later)
    }
```

- [ ] **Step 2: Failing store test** in `TranscriptDraftLifecycleTests` (use that file's store/fixture helpers — read `testCloseDraftWithChangedTextMintsUserEditRevisionWithCorrectParentage` and copy its setup; the store takes an injectable `now` clock — pass a frozen one):

```swift
    /// #51, reproduced at the store: under a frozen clock two consecutive edits used to
    /// tie on `createdAt`, and `current` landed on whichever ULID suffix sorted last —
    /// a coin flip. Twenty rounds, zero tolerance.
    func testTwoEditsUnderAFrozenClockAlwaysMakeTheSecondOneCurrent() async throws {
        for round in 0..<20 {
            let captureID = try plantCapture()           // the file's own fixture helper
            let frozen = Date(timeIntervalSince1970: 3_000)
            let store = makeStore(now: { frozen })       // the file's own factory
            try await store.openDraft(captureID: captureID)
            try await store.writeDraft(captureID: captureID, text: "first \(round)")
            let first = try XCTUnwrap(try await store.closeDraft(captureID: captureID, reason: .userDone))
            try await store.openDraft(captureID: captureID)
            try await store.writeDraft(captureID: captureID, text: "second \(round)")
            let second = try XCTUnwrap(try await store.closeDraft(captureID: captureID, reason: .userDone))
            let chain = try await store.loadChain(captureID: captureID)
            XCTAssertEqual(TranscriptChain.current(chain.revisions)?.id, second,
                           "round \(round): the second edit must be current, not \(first)")
        }
    }
```

Adapt the exact API names (`openDraft`/`writeDraft`/`closeDraft`/`loadChain`, the reason enum) to what the file already calls; the shape is what matters. Run 20 rounds: expected RED in at least one round before the fix (the tie is a coin flip per round).

- [ ] **Step 3: Implement**

`TranscriptChain.swift`:

```swift
    /// The instant a new revision is minted at (#43, #51). Two rules, both about the total
    /// order `(createdAt, id)` staying deterministic:
    /// - truncated to the encoder's millisecond precision, so an in-memory revision and
    ///   its re-decoded self never order differently;
    /// - strictly later than the chain's last revision — a wall clock that has not moved
    ///   a millisecond (or moved backwards) gets `tip + 1 ms`, so two mints can never tie
    ///   and fall to the random half of a ULID.
    static func mintInstant(now: Date, after ordered: [TranscriptRevision]) -> Date {
        let truncated = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        guard let tip = ordered.last else { return truncated }
        return truncated > tip.createdAt ? truncated : tip.createdAt.addingTimeInterval(0.001)
    }
```

`TranscriptRevisionStore.swift`: in `closeDraft`, replace `let newID = ULID.make(now: now)` with `let mintedAt = TranscriptChain.mintInstant(now: now, after: ordered)` / `let newID = ULID.make(now: mintedAt)` and pass `createdAt: mintedAt` (and use `mintedAt` in the hour-cap comparison's place of `now` ONLY if that comparison is against `draft.openedAt` — it is; leave it on `now`). In the revert path: `let mintedAt = TranscriptChain.mintInstant(now: now, after: ordered)` and use it for both `id:` and `createdAt:`. In `promoteIfNeeded` the chain is empty by construction (`.skippedAlreadyPromoted` above), so `let mintedAt = TranscriptChain.mintInstant(now: now, after: [])` for `id:` and `createdAt:`.

- [ ] **Step 4: Run `TranscriptChainTests`, `TranscriptDraftLifecycleTests`, `TranscriptRevisionStoreTests`, `RevisionHistoryModelTests`, `TranscriptEditorModelTests` → GREEN. Unit +4. Commit:**

```bash
git commit -am "fix(revisions): mint instants are ms-truncated and strictly after the chain tip (#43, #51)"
```

### Task 12: Preserve unknown keys through the Journal and EntryMetadata coders (#70)

**Files:**
- Create: `Raconte/Library/JSONValue.swift`
- Modify: `Raconte/Library/Journal.swift` (`Journal` coder), `Raconte/Library/EntryMetadata.swift` (coder)
- Test: `RaconteTests/JournalStoreTests.swift` (replace `testDecoderIgnoresUnknownKeysFromANewerBuild`), `RaconteTests/EntryMetadataStoreTests.swift` (new test), `RaconteTests/JSONValueTests.swift` (new)
- Then `xcodegen generate`.

**Interfaces:**
- Produces: `enum JSONValue: Codable, Hashable, Sendable { case null, bool(Bool), number(Decimal), string(String), array([JSONValue]), object([String: JSONValue]) }`; `struct AnyCodingKey: CodingKey`; `Journal.unknownFields: [String: JSONValue]` and `EntryMetadata.unknownFields: [String: JSONValue]`, both defaulting to `[:]`, decoded from every key not in `CodingKeys`, re-emitted on encode.

**Design.** Direction 1 from the issue (preserve), because this project degrades rather
than refuses. A newer build's field round-trips through an older build byte-for-byte:
`.sortedKeys` places it where the newer build would, and `Decimal` keeps integers as
integers. Known keys keep their existing strict/lenient rules exactly. `unknownFields`
participates in `Equatable`/`Hashable` (synthesized) — two journals that differ only in
a field this build cannot read are, correctly, not equal.

- [ ] **Step 1: Failing tests**

`RaconteTests/JSONValueTests.swift`:

```swift
import XCTest
@testable import Raconte

final class JSONValueTests: XCTestCase {
    func testRoundTripsEveryShapeByteForByteUnderSortedKeys() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"b":{"c":false},"d":"s","e":123456789012345678}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(value), as: UTF8.self), text)
    }
}
```

`JournalStoreTests`: replace `testDecoderIgnoresUnknownKeysFromANewerBuild` with:

```swift
    /// #70: a field written by a newer build must survive this build re-encoding the
    /// journal for an unrelated reason — under M4 sync the older device's write is
    /// genuinely newer, so no per-field LWW stamp can notice the loss.
    func testUnknownKeysFromANewerBuildSurviveARoundTrip() throws {
        let registry = try JournalStore.load(url: writeRegistry(
            #"{"journals":[{"color":"red","createdAt":"1970-01-01T00:00:00.000Z","id":"A","name":"N","pages":{"count":12}}]}"#))
        XCTAssertEqual(registry.journals.map(\.id), ["A"])
        XCTAssertEqual(registry.journals[0].unknownFields["color"], .string("red"))
        let text = String(decoding: try JournalStore.encode(registry), as: UTF8.self)
        XCTAssertEqual(text,
            #"{"journals":[{"color":"red","createdAt":"1970-01-01T00:00:00.000Z","id":"A","name":"N","pages":{"count":12}}]}"#)
    }

    func testARenameKeepsTheUnknownKeys() throws {
        var registry = try JournalStore.load(url: writeRegistry(
            #"{"journals":[{"color":"red","createdAt":"1970-01-01T00:00:00.000Z","id":"A","name":"N"}]}"#))
        try registry.rename(id: "A", to: "M", now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(registry.journals[0].unknownFields["color"], .string("red"))
    }
```

(Adapt `registry.rename`'s real signature from the file.) Keep `testEncodedShapeIsSingleLineWithSortedKeysAndISO8601Dates` untouched — it is the byte pin that proves an untouched journal's bytes do not change.

`EntryMetadataStoreTests`: add the mirror test — write `{"journalID":"J","mood":"calm"}` to a sidecar URL, `EntryMetadataStore.read(url:)`, assert `unknownFields["mood"] == .string("calm")`, `EntryMetadataStore.write(_:url:)`, re-read the bytes and assert they equal `{"journalID":"J","mood":"calm"}`. Also assert an untouched `EntryMetadata()` still encodes as exactly `{}`.

- [ ] **Step 2: `xcodegen generate`; run → RED (`JSONValue` undefined).**

- [ ] **Step 3: Implement**

`Raconte/Library/JSONValue.swift`:

```swift
import Foundation

/// A JSON document fragment this build does not understand, kept so it can be written
/// back untouched (#70). `Decimal`, not `Double`, so `12` stays `12` and an id-sized
/// integer keeps every digit.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let b = try? single.decode(Bool.self) { self = .bool(b); return }
        if let s = try? single.decode(String.self) { self = .string(s); return }
        if let n = try? single.decode(Decimal.self) { self = .number(n); return }
        if let a = try? single.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? single.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "not a JSON value"))
    }

    func encode(to encoder: any Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let b): try single.encode(b)
        case .number(let n): try single.encode(n)
        case .string(let s): try single.encode(s)
        case .array(let a): try single.encode(a)
        case .object(let o): try single.encode(o)
        }
    }
}

/// Any key at all — for reading the keys a typed `CodingKeys` does not name.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// Every key not claimed by `known`, decoded as raw JSON. A value that fails to decode
    /// (cannot happen for well-formed JSON) is dropped rather than failing the record.
    func unknownFields<Known: CodingKey & CaseIterable>(except known: Known.Type) -> [String: JSONValue] {
        let claimed = Set(Known.allCases.map(\.stringValue))
        var out: [String: JSONValue] = [:]
        for key in allKeys where !claimed.contains(key.stringValue) {
            if let value = try? decode(JSONValue.self, forKey: key) { out[key.stringValue] = value }
        }
        return out
    }
}

extension KeyedEncodingContainer where Key == AnyCodingKey {
    mutating func encodeUnknownFields(_ fields: [String: JSONValue]) throws {
        for (name, value) in fields { try encode(value, forKey: AnyCodingKey(name)) }
    }
}
```

`Journal.swift`: add `var unknownFields: [String: JSONValue]` (memberwise init gains `unknownFields: [String: JSONValue] = [:]` as the LAST parameter, so every existing call site compiles unchanged); make `CodingKeys` `CaseIterable`; at the end of `init(from:)`: `unknownFields = try decoder.container(keyedBy: AnyCodingKey.self).unknownFields(except: CodingKeys.self)`; at the end of `encode(to:)`: `var extra = encoder.container(keyedBy: AnyCodingKey.self); try extra.encodeUnknownFields(unknownFields)`. Verify with the byte-pin test that asking the same encoder for a second keyed container appends into the same object (Foundation's JSONEncoder does; if it asserts, encode every known key through one `AnyCodingKey` container instead — `container.encode(id, forKey: AnyCodingKey(CodingKeys.id.stringValue))` — and say so in the commit).

`EntryMetadata.swift`: identical treatment. `legacyPrecision` is a known key, so it is consumed and never re-emitted — exactly today's upgrade-in-place behaviour.

Update the two decoder doc comments: "Unknown keys are ignored" → "Unknown keys are preserved in `unknownFields` and written back (#70)".

- [ ] **Step 4: Run `JSONValueTests`, `JournalStoreTests`, `EntryMetadataStoreTests`, `SyncJournalIngestTests`, `SyncJournalRoundTripTests`, `SyncEntryMergeTests`, `JournalOrderingTests` → GREEN. Then the FULL macOS unit suite (the coders are everywhere). Unit: −1 +2 +1 +2 = +4 net. iOS compile green. Commit:**

```bash
git commit -am "fix(coders): Journal and EntryMetadata preserve unknown keys across a re-encode (#70)"
```

Push and open PR 4 (`Closes #43, #51, #70`).

---

## PR 5 — stretch: `feat/136-live-paragraph`

Branch from `main`. Closes #136. **Do this last; skip it if the four PRs above are not
all open and green-locally by then.**

### Task 13: Show the paragraph break live, at the marker's frame (#136)

**Files:**
- Modify: `Raconte/Capture/CaptureCoordinator.swift` (new `paragraphFrames`, appended in `appendMarker`, reset in `resetCaptureWiring`)
- Modify: `Raconte/Library/TranscriptAttribution.swift` (expose the nearer-edge cut rule over `[FrameRange]`)
- Modify: `Raconte/Capture/UI/LiveTranscriptText.swift` (`paragraphFrames` input)
- Modify: `Raconte/Capture/UI/CaptureView.swift:173` (pass the frames)
- Test: `RaconteTests/LiveTranscriptTextTests.swift`, `RaconteTests/CaptureCoordinatorTests.swift`, `RaconteTests/TranscriptAttributionLoadTests.swift` (existing cut tests must stay green)

**Interfaces:**
- Produces: `CaptureCoordinator.paragraphFrames: [Int64]` (private(set), per capture); `TranscriptAttribution.cutIndex(forFrame: Int64, ranges: [FrameRange]) -> Int` (internal, pure); `LiveTranscriptText(runs:paragraphFrames:)` and `LiveTranscriptText.attributed(_:paragraphFrames:ink:dim:)`.

**Design.** The break is keyed to the marker's FRAME, never a character offset, and is
recomputed on every render from `runs` — so a provisional run that gets re-ranged moves
the break with it. Live and post-hoc agree because both call the same nearer-edge rule:
a frame strictly inside a run cuts before or after it, whichever edge is nearer; a frame
on or between runs cuts before the first run whose start is ≥ the frame. A break at
index 0 or past the last run renders nothing. Breaks are rendered as `"\n\n"` in place of
the single-space separator, in the colour of the run before them, matching the detail
screen's paragraph spacing in spirit (a blank line) without introducing layout state.

- [ ] **Step 1: Failing view tests** (in `LiveTranscriptTextTests`, using the file's existing run fixtures and `String(attributed.characters)` to read text):

```swift
    /// #136: a ¶ tapped between two runs starts a new line where the words after it begin.
    func testAParagraphFrameBetweenRunsBecomesABlankLine() {
        let runs = [run("one two", 0..<100), run("three", 100..<200)]
        let text = String(LiveTranscriptText.attributed(runs, paragraphFrames: [100], ink: .white, dim: .gray).characters)
        XCTAssertEqual(text, "one two\n\nthree")
    }

    /// The same nearer-edge rule the detail screen uses — a frame inside a run cuts at the
    /// nearer edge, never mid-word.
    func testAParagraphFrameInsideARunCutsAtTheNearerEdge() {
        let runs = [run("one", 0..<100), run("two", 100..<200), run("three", 200..<300)]
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, paragraphFrames: [110], ink: .white, dim: .gray).characters), "one\n\ntwo three")
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, paragraphFrames: [190], ink: .white, dim: .gray).characters), "one two\n\nthree")
    }

    func testFramesAtTheEdgesRenderNoBreak() {
        let runs = [run("one", 0..<100), run("two", 100..<200)]
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, paragraphFrames: [0, 500], ink: .white, dim: .gray).characters), "one two")
    }

    func testTwoFramesInOneGapMakeOneBreak() {
        let runs = [run("one", 0..<100), run("two", 100..<200)]
        XCTAssertEqual(String(LiveTranscriptText.attributed(runs, paragraphFrames: [100, 100], ink: .white, dim: .gray).characters), "one\n\ntwo")
    }
```

`run(_:_:)` — add a file-private helper if the file has none: `ConsolidatedTranscriptRun(text:range: FrameRange(start:end:), isProvisional: false)`.

- [ ] **Step 2: Failing coordinator test** in `CaptureCoordinatorTests` next to `testMarkerAppendsCarryAtFromTheCoordinatorsInjectedClock` (copy its setup): after two `markParagraph()` calls at different clock frames, `coordinator.paragraphFrames` has two ascending frames; after `done()` and finish, it is empty.

- [ ] **Step 3: Run → RED (missing `paragraphFrames`, missing `attributed(_:paragraphFrames:…)`).**

- [ ] **Step 4: Implement**

`TranscriptAttribution.swift`: add an internal overload and make the private one call it:

```swift
    /// The one cut rule, shared with the live transcript (#136) so the break the owner
    /// watched lands where the receipt's paragraph does. A frame strictly inside a range
    /// cuts at the nearer edge — text is never torn mid-word; otherwise it cuts before
    /// the first range whose start is at or after the frame.
    static func cutIndex(forFrame frame: Int64, ranges: [FrameRange]) -> Int {
        if let inside = ranges.firstIndex(where: { $0.start < frame && frame < $0.end }) {
            let r = ranges[inside]
            return frame - r.start < r.end - frame ? inside : inside + 1
        }
        return ranges.firstIndex { $0.start >= frame } ?? ranges.count
    }
```

and rewrite the private `cutIndex(forFrame:pieces:)` to compute `structuralApprox` as before but take `index` from `cutIndex(forFrame:ranges: pieces.map { FrameRange(start: $0.start, end: $0.end) })`. Existing attribution tests must stay green — that is the proof the rule did not move.

`CaptureCoordinator.swift`: `private(set) var paragraphFrames: [Int64] = []` with a doc comment ("#136: the frames of this capture's ¶ taps, for the live transcript; reset with the wiring"); in `appendMarker` after `markerCount += 1`: `if case .paragraph = kind { paragraphFrames.append(frame) }`; in `resetCaptureWiring`: `paragraphFrames = []`.

`LiveTranscriptText.swift`:

```swift
struct LiveTranscriptText: View {
    let runs: [ConsolidatedTranscriptRun]
    var paragraphFrames: [Int64] = []

    var body: some View {
        Text(Self.attributed(runs, paragraphFrames: paragraphFrames,
                             ink: InkTone.studioInk.color, dim: InkTone.studioInkDim.color))
        …
    }

    static func attributed(_ runs: [ConsolidatedTranscriptRun], paragraphFrames: [Int64] = [],
                           ink: Color, dim: Color) -> AttributedString {
        let visible = runs.filter { !$0.text.isEmpty }
        let ranges = visible.map(\.range)
        let breaks = Set(paragraphFrames.map { TranscriptAttribution.cutIndex(forFrame: $0, ranges: ranges) })
        var out = AttributedString()
        for (index, run) in visible.enumerated() {
            var piece = AttributedString(run.text)
            piece.foregroundColor = run.isProvisional ? dim : ink
            if !out.characters.isEmpty {
                var separator = AttributedString(breaks.contains(index) ? "\n\n" : " ")
                separator.foregroundColor = out.runs.last?.foregroundColor
                out.append(separator)
            }
            out.append(piece)
        }
        return out
    }
}
```

`CaptureView.swift:173`: `LiveTranscriptText(runs: transcription.runs, paragraphFrames: model.coordinator.paragraphFrames)`.

- [ ] **Step 5: Run `LiveTranscriptTextTests`, `CaptureCoordinatorTests`, `TranscriptAttributionLoadTests`, `CaptureLabelTests` (the `studioInkDim` source pin) → GREEN. Full unit: +5. iOS compile green. Commit:**

```bash
git commit -am "feat(capture): live transcript shows the paragraph break at the ¶ tap's frame (#136)"
```

Push, open PR 5 (`Closes #136`). Body notes that the simulator has no speech, so the only
end-to-end check is the owner's: on the Mac, record, read a sentence, tap ¶, read another
sentence — the second sentence starts on a new line while still recording, and the receipt
shows the same break.

---

## Wrap-up (after the last PR is open)

- [ ] For each PR, confirm CI ran (`gh pr checks <n>`), record the executed counts from the job logs against the baseline, and fix anything red before ending the session.
- [ ] `/handoff`: CLAUDE.md latest-session block lists the five PRs with their URLs, their counts, the merge order (1 → 2 → 3 → 4 → 5 with "Update branch" between), and the owner smoke steps per PR; devlog entry; close nothing manually (the PR bodies carry the close keywords).
