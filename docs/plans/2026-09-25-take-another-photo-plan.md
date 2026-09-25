# Take another photo (2026-09-25) Implementation Plan — repeated camera capture for one entry (#134)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One PR from `main` so that after a camera shot lands on an entry, the image picker
sheet stays up showing how many photos landed, offers "Take Another…", and dismisses on
"Done", instead of closing after every shot.

**Architecture:** A pure `ImageCaptureBatch` value (new `Raconte/Library/ImageCaptureBatch.swift`)
holds the running count and the copy rules: the camera row's title ("Take Photo…" →
"Take Another…"), the dismiss button's title ("Cancel" → "Done"), and the tally line ("1 photo
added" / "N photos added"). `ImageCapturePickerSheet` keeps one `@State var batch` and, on a
successful camera shot, records it instead of calling `dismiss()`. The library picker and the
macOS file importer already add many images in one trip and keep dismissing after the batch;
they are untouched. The journal cover sheet is a single image and is untouched. The write path
(`EntryDetailView.addPickedImage` → `LibraryScreenModel.addImage`) does not change.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency, XcodeGen
project, XCTest + XCUITest.

**Spec:** Issue #134 (`gh issue view 134`) plus the rulings under Global Constraints. The sheet:
`Raconte/Library/UI/ImageCapturePickerSheet.swift`. Its presenter:
`Raconte/Library/UI/EntryDetailView.swift:766-770`. Precedent for a pure copy/state value with
a view reading it: `Raconte/Library/ImageDropSource.swift` + `RaconteTests/ImageDropSourceTests.swift`.

## Global Constraints

- Branch `feat/134-take-another` from `main` at or after `6b2c7100`. Work in a worktree
  (`../raconte-wt-134`); the main checkout stays on `main`. Run `xcodegen generate` in the
  worktree before the first build.
- **Do not run `xcodebuild test` until the orchestrator has said the owner's Mac app is
  quit.** The macOS unit suite launches `Raconte.app` as its test host under the same bundle
  id, which kills a running smoke build. Compile checks (`build`) are always fine.
- **Rulings (owner, 2026-09-25; do not re-open):**
  1. Camera only. The library picker (iOS) and the file importer (macOS) already multi-select
     in one trip; their dismiss-after-batch behaviour stays exactly as it is.
  2. After each shot the sheet returns with a count and "Take Another…" / "Done". It does not
     drop straight back into the camera.
  3. The journal cover sheet (`JournalCoverPickerSheet`) is not touched — a cover is one image.
  4. No duplication: one camera row whose title changes, one toolbar button whose title
     changes. Do not add a second camera button or a second dismiss button.
- Photos land in the order taken (already true: each shot goes through `onPick` in turn).
- Paper screens take a `TypeRole`, never a bare text style or size literal. The sheet file is
  NOT on `TypeScaleTests.paperScreenFiles`, but follow the rule anyway: the tally line uses
  `.font(TypeRole.footnote.font)` and `.foregroundStyle(InkTone.inkSecondary.color)` (the same
  pair `Raconte/App/ExportConfirmationSheet.swift:50` uses).
- Accessibility identifiers go on the control itself. Keep `imageCapture.takePhoto` on the
  camera row across both titles, and keep the toolbar button's LABEL "Cancel" before any shot
  lands: `RaconteUITests/ImageCaptureUITests.swift:118` queries `app.buttons["Cancel"]`.
- New SOURCE files and new TEST files both need `xcodegen generate` before they compile.
- Test-count baseline (main run 34497525407, the #174 merge, last green CODE run):
  **unit 2229, 1 skipped; UI 67.** Every task reports the executed count. Bash
  `timeout: 600000` on every xcodebuild.
- macOS unit test command (sandbox kept; never `CODE_SIGNING_ALLOWED=NO`). Narrow with
  `-only-testing:RaconteTests/<Class>` for the fast loop; run the whole unit suite once in
  Task 3:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

- iOS compile check (must pass on every task; the camera path is `#if os(iOS)` so a macOS
  build alone proves nothing about it):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "BUILD|error:" | tail -3
```

- UI tests run on the simulator only, one class per invocation. **On the laptop the simulator is
  currently unavailable** (macOS 27.0 with an older CoreSimulator; `xcodebuild` prints
  `CoreSimulator is out of date … Simulator device support disabled`). If that line appears,
  do not retry or recreate simulators: record the line, skip the UI run, and say in the report
  and the PR body that CI runs the class.

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/ImageCaptureUITests test 2>&1 | grep -E "Executed|error:|failed|passed" | tail -8
```

- **The camera cannot be driven in the simulator** (`UIImagePickerController.isSourceTypeAvailable(.camera)`
  is false there, and the row is not even shown). So the loop is pinned at the model level
  (`ImageCaptureBatch`) and the existing `ImageCaptureUITests` class is re-run unchanged to
  prove the pre-shot sheet (labels, Cancel) did not move, where a simulator is available (else CI). Do not add a UI test that pretends to
  take a photo. The owner smoke at the end is the only end-to-end proof; say so in the PR.
- Commit after each task with the trailer:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
```

## Review Focus

1. A shot that FAILS to land (`onPick` returns false) must not count and must still show the
   existing alert; the tally stays where it was. Pinned in Task 1
   (`testAFailedShotDoesNotCount`) and wired in Task 2 (the failure branch is unchanged).
2. Cancelling the camera (no data) must not count either. Task 2 keeps the `if let data`
   guard, so a cancel returns to the sheet with the tally unchanged.
3. The tally copy at 1 vs 2+ ("1 photo added", "2 photos added"). Pinned in Task 1
   (`testSummaryPluralises`).
4. The pre-shot sheet is byte-for-byte the old one: "Take Photo…", "Cancel". Pinned in
   Task 1 (`testFreshBatchShowsTheOriginalCopy`) and by re-running `ImageCaptureUITests` in
   Task 3.
5. The EXIF backdate suggestion (`EntryDetailView.addPickedImage` sets
   `showingBackdatePicker = true`) now fires while the picker sheet is still presented. SwiftUI
   presents that second sheet once the picker dismisses on Done, which is the same shape the
   multi-select library path has today. No code change; the owner smoke step 5 checks it.

---

### Task 1: `ImageCaptureBatch`, pure and unit-pinned

**Files:**
- Create: `Raconte/Library/ImageCaptureBatch.swift`
- Create: `RaconteTests/ImageCaptureBatchTests.swift`
- Modify: none (then `xcodegen generate` — both files are new)

**Interfaces:**
- Consumes: nothing from the codebase.
- Produces, used by Task 2:

```swift
struct ImageCaptureBatch: Equatable, Sendable {
    private(set) var added: Int          // starts at 0
    mutating func recordLanded()         // one successful camera shot
    var hasLanded: Bool                  // added > 0
    var cameraButtonTitle: String        // "Take Photo…" / "Take Another…"
    var dismissButtonTitle: String       // "Cancel" / "Done"
    var summary: String                  // "1 photo added" / "N photos added"
}
```

- [ ] **Step 1: Write the failing tests**

Create `RaconteTests/ImageCaptureBatchTests.swift`:

```swift
import XCTest
@testable import Raconte

/// #134: the tally behind the camera's take-another loop in `ImageCapturePickerSheet`.
/// Pure — the simulator has no camera, so the loop's rules are pinned here, not in a UI test.
final class ImageCaptureBatchTests: XCTestCase {

    /// Before any shot the sheet is the old one: same camera row title, same Cancel.
    func testFreshBatchShowsTheOriginalCopy() {
        let batch = ImageCaptureBatch()
        XCTAssertEqual(batch.added, 0)
        XCTAssertFalse(batch.hasLanded)
        XCTAssertEqual(batch.cameraButtonTitle, "Take Photo…")
        XCTAssertEqual(batch.dismissButtonTitle, "Cancel")
    }

    /// One landed shot flips both titles: the camera row now reads as "another", and the
    /// toolbar button no longer says Cancel over a photo that is already saved.
    func testALandedShotFlipsTheCopy() {
        var batch = ImageCaptureBatch()
        batch.recordLanded()
        XCTAssertEqual(batch.added, 1)
        XCTAssertTrue(batch.hasLanded)
        XCTAssertEqual(batch.cameraButtonTitle, "Take Another…")
        XCTAssertEqual(batch.dismissButtonTitle, "Done")
    }

    func testSummaryPluralises() {
        var batch = ImageCaptureBatch()
        batch.recordLanded()
        XCTAssertEqual(batch.summary, "1 photo added")
        batch.recordLanded()
        XCTAssertEqual(batch.summary, "2 photos added")
        batch.recordLanded()
        XCTAssertEqual(batch.summary, "3 photos added")
    }

    /// Only the caller decides what landed; a failed or cancelled shot never calls
    /// `recordLanded()`, so the tally has no "failed" path of its own to get wrong.
    func testAFailedShotDoesNotCount() {
        var batch = ImageCaptureBatch()
        batch.recordLanded()
        let before = batch
        // The sheet's failure branch (Task 2) does not touch the batch at all.
        XCTAssertEqual(batch, before)
        XCTAssertEqual(batch.added, 1)
    }
}
```

- [ ] **Step 2: Create the source file with a stub so the tests compile, then verify RED**

Create `Raconte/Library/ImageCaptureBatch.swift`:

```swift
import Foundation

struct ImageCaptureBatch: Equatable, Sendable {
    private(set) var added = 0
    mutating func recordLanded() {}
    var hasLanded: Bool { false }
    var cameraButtonTitle: String { "" }
    var dismissButtonTitle: String { "" }
    var summary: String { "" }
}
```

Run `xcodegen generate`, then:

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements \
  -only-testing:RaconteTests/ImageCaptureBatchTests test 2>&1 | grep -E "Executed|error:|failed" | tail -8
```

Expected: `Executed 4 tests` with 3 failures (`testFreshBatchShowsTheOriginalCopy`,
`testALandedShotFlipsTheCopy`, `testSummaryPluralises` fail on the empty strings and the
non-incrementing count). `testAFailedShotDoesNotCount` passes against the stub because the
stub never increments; that is fine, it is a guard on Task 2's wiring, not on this type.

- [ ] **Step 3: Implement the value**

Replace the body of `Raconte/Library/ImageCaptureBatch.swift`:

```swift
import Foundation

/// #134: the running tally behind the camera's take-another loop in
/// `ImageCapturePickerSheet`. Photographing several pages of a journal for one entry used
/// to be one trip through the sheet per page; now a landed shot returns to the sheet with
/// this count, the camera row re-titled, and the toolbar button turned from Cancel into
/// Done (a photo that has already landed cannot be cancelled from here).
///
/// Only successful shots are recorded: the sheet's failure and cancel branches never call
/// `recordLanded()`, so there is no failed-state to keep consistent. Pure, so the copy rules
/// are pinned in `ImageCaptureBatchTests` — the simulator has no camera to drive.
struct ImageCaptureBatch: Equatable, Sendable {
    private(set) var added = 0

    mutating func recordLanded() { added += 1 }

    var hasLanded: Bool { added > 0 }

    var cameraButtonTitle: String { hasLanded ? "Take Another…" : "Take Photo…" }

    var dismissButtonTitle: String { hasLanded ? "Done" : "Cancel" }

    var summary: String { added == 1 ? "1 photo added" : "\(added) photos added" }
}
```

- [ ] **Step 4: Run the class again and verify GREEN**

Same command as Step 2. Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: iOS compile check, then commit**

iOS compile check from Global Constraints: `BUILD SUCCEEDED`.

```bash
git add Raconte/Library/ImageCaptureBatch.swift RaconteTests/ImageCaptureBatchTests.swift
git commit -m "feat(#134): ImageCaptureBatch — tally and copy rules for the take-another loop

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: The sheet stays up after a camera shot

**Files:**
- Modify: `Raconte/Library/UI/ImageCapturePickerSheet.swift` (doc comment `:8-23`, state
  `:30-41`, `List` body `:44-70`, camera completion `:83-92`)

**Interfaces:**
- Consumes: `ImageCaptureBatch` from Task 1. `onPick: (Data, UTType) async -> Bool` is
  unchanged, so `EntryDetailView.imagePickerSheet` (`:766-770`) needs no edit.
- Produces: nothing new for other tasks. New accessibility identifiers:
  `imageCapture.summary` (the tally `Text`), `imageCapture.dismiss` (the toolbar button;
  its label is still "Cancel" before any shot).

- [ ] **Step 1: Add the state and the doc comment**

In `ImageCapturePickerSheet`, after `@State private var pickError = false` (`:33`) add:

```swift
    /// #134: how many camera shots have landed this presentation. The library picker and
    /// the file importer add whole batches in one trip and dismiss afterwards as before;
    /// only the camera loops through here.
    @State private var batch = ImageCaptureBatch()
```

In the type's doc comment, after the paragraph ending `so there is no "current image"/"remove"
affordance in here to mirror the cover sheet's.` add a paragraph:

```
/// A camera shot that lands does NOT dismiss (#134): the sheet comes back with a tally
/// ("2 photos added"), the camera row re-titled "Take Another…" and the toolbar button
/// turned into "Done", so a run of page photos is one trip. `ImageCaptureBatch` holds the
/// rules; `ImageCaptureBatchTests` pins them, since the simulator has no camera.
```

- [ ] **Step 2: Rewrite the iOS camera row and the toolbar button**

Replace (`:47-51`)

```swift
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo…") { showingCamera = true }
                        .accessibilityIdentifier("imageCapture.takePhoto")
                }
```

with

```swift
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button(batch.cameraButtonTitle) { showingCamera = true }
                        .accessibilityIdentifier("imageCapture.takePhoto")
                }
                if batch.hasLanded {
                    Text(batch.summary)
                        .font(TypeRole.footnote.font)
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .accessibilityIdentifier("imageCapture.summary")
                }
```

Replace the toolbar (`:62-66`)

```swift
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
```

with

```swift
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(batch.dismissButtonTitle) { dismiss() }
                        .accessibilityIdentifier("imageCapture.dismiss")
                }
            }
```

(The toolbar is outside the `#if os(iOS)` block; on macOS `batch` never leaves its fresh
state, so the button reads "Cancel" there always. That is intended: macOS has no camera loop.)

- [ ] **Step 3: Make a landed shot record instead of dismiss**

Replace the camera completion (`:83-92`)

```swift
            CameraCapture { data in
                showingCamera = false
                if let data {
                    Task {
                        if await onPick(data, .jpeg) { dismiss() } else { pendingCameraError = true }
                    }
                }
            }
```

with

```swift
            CameraCapture { data in
                showingCamera = false
                if let data {
                    Task {
                        // Landed: stay up for the next shot (#134). Failed: the same
                        // deferred alert as before; the tally is untouched.
                        if await onPick(data, .jpeg) { batch.recordLanded() } else { pendingCameraError = true }
                    }
                }
            }
```

- [ ] **Step 4: iOS compile check and the pre-shot UI test**

iOS compile check from Global Constraints: `BUILD SUCCEEDED`. Then the UI class:

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/ImageCaptureUITests test 2>&1 | grep -E "Executed|error:|failed|passed" | tail -8
```

Expected: the class's existing 3 tests pass (`Executed 3 tests, with 0 failures`). If the
simulator is unavailable on this machine (see Global Constraints), record the CoreSimulator line
and move on; CI runs the class. If `testCapturingAnImageOpensTheRealPickerSheet`
fails on `app.buttons["Cancel"]`, the dismiss title was flipped before any shot; fix
`dismissButtonTitle`'s use, not the test.

- [ ] **Step 5: Straggler grep, commit**

```
grep -rn '"Take Photo…"\|"Cancel") { dismiss() }' Raconte/Library/UI/ImageCapturePickerSheet.swift
```

Expected: zero hits (both literals now come from the batch). `JournalCoverPickerSheet.swift`
still has its own; leave it (ruling 3).

```bash
git add Raconte/Library/UI/ImageCapturePickerSheet.swift
git commit -m "feat(#134): image picker sheet stays up after a camera shot — tally, Take Another…, Done

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Whole unit suite, PR

**Files:**
- Modify: none.

- [ ] **Step 1: Run the whole macOS unit suite**

Run the full unit command from Global Constraints (no `-only-testing`).
Expected: `Executed 2233 tests, with 1 test skipped and 0 failures` — the baseline 2229 plus
4 (Task 1). On the laptop (macOS 27.0) nine SpeechAnalyzer tests crash the test host
(`[SpeechFramework] Failed precondition: Audio sample data must be 16-bit signed integers`;
verified identical on plain main), xcodebuild restarts mid-suite and no single `Executed` line
exists: report the started and passed counts from the log instead (expected 2233 started, 2224
passed, those 9 crashed) and name the nine; they are the environment, not this branch. If the number is 2229, `xcodegen generate` was skipped and the new test file never
ran. (If this branch is being run after `feat/175-backdate-seed` merged, the baseline is 2243
and the expected count 2247; take the baseline from main's latest CI run, never from this
sentence.)

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/134-take-another
```

Write the PR body to a file, then `gh pr create --title "feat(#134): take another photo — the camera loops inside the image picker sheet" --body-file <file>`. The body states: rulings 1–4, the executed counts (unit and the `ImageCaptureUITests` class count), that the camera loop has no UI test and why (simulator has no camera; the loop's rules are pinned in `ImageCaptureBatchTests`), and the owner smoke below. It ends with the line
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do NOT merge; the merge is the owner's.

Owner smoke to put in the PR body (iPhone only — the loop is camera-only; build number to be
filled in by the orchestrator):

1. About → App → Build shows the new number.
2. Open any entry → ⋯ → Add Image… → Take Photo…. Take a photo and tap Use Photo. Pass: the
   sheet is back, reads "1 photo added", the row now says "Take Another…", and the top button
   says "Done". Fail: the sheet closed.
3. Tap Take Another…, take a second photo. Pass: "2 photos added".
4. Tap Done. Pass: the entry shows both photos in the order taken.
5. If the entry had no backdate and the photos carry a date, the backdate suggestion sheet
   appears once after Done, not once per photo. Pass: once or not at all. Fail: it appears
   twice, or the second photo could not be taken because a sheet was in the way.
6. Add Image… → Choose from Library…, pick two photos. Pass: both land and the sheet closes
   by itself, as before.
