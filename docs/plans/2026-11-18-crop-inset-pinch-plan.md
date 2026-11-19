# Crop: Inset Start and Pinch to Resize — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The crop screen opens a camera shot with the rectangle 10% in from each edge, and a pinch grows or shrinks the rectangle while keeping its shape.

**Architecture:** Three pure pieces, each pinned by unit tests, then one wiring task. The rectangle rules (`scaled`, the starting rectangle, rotate's reset) join the existing pure helpers. A small value type, `CropInteraction`, decides which gesture owns the rectangle. `ImageFramingView` takes the starting rectangle as a required parameter and gains one `MagnifyGesture`.

**Tech Stack:** SwiftUI (iOS 26, macOS 26), Swift 6 strict concurrency, XCTest, XCUITest, XcodeGen.

**Spec:** `docs/plans/2026-11-18-crop-inset-pinch-design.md`. Read it first.

## Global Constraints

- The camera inset is 10% per side: the starting rectangle is `CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)` in unit space. Library picks and the viewer's re-crop start at the full photo.
- The photo never moves or magnifies. Only the rectangle changes.
- Handles and the one-finger move drag behave exactly as today. `ImageFramingLayout` margins (#201) are untouched.
- No new controls, no new text, no new accessibility identifiers.
- New Swift files need `xcodegen generate` before they build or run. After adding a test file, confirm the executed test count went UP; a green run at the old count means the file is not in the project.
- Unit tests, macOS. Build into the checkout, never into `/tmp` (a `/private/tmp` build fails `BuildStamp`). One line, Bash `timeout: 600000`, foreground:
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' -derivedDataPath .superpowers/dd CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="$PWD/Raconte/Raconte-nocloud.entitlements" test`
  Add `-only-testing:RaconteTests/<Class>` for one class. Never `CODE_SIGNING_ALLOWED=NO` here.
- A local macOS test run needs the owner's Raconte app closed (same bundle id blocks the test host). Tell the owner before the first run; do not quit his app yourself.
- UI tests, iOS simulator only, foreground, Bash `timeout: 600000`, one class per invocation:
  `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .superpowers/dd-ui -only-testing:RaconteUITests/ImageCaptureUITests test`
  Never background a test run. Never delete or recreate a simulator. `Executed 0 tests` with `TEST FAILED` is an install failure, not a result: stop and report.
- Test-count baseline: read `Executed N tests` from the job log of main's most recent code-carrying CI run (`gh run list --branch main`, then `gh api repos/nicolovejoy/raconte/actions/jobs/<id>/logs`). Never from a commit message or PR body.
- Work in a worktree, `../raconte-wt-203`, on branch `feat/203-crop-inset-pinch`. End at an open PR. Merging is the owner's.
- Commit messages: `feat(#203): …`, ending with the `Co-Authored-By` line the session supplies.

## Review Focus

Conditions the spec implies that are most likely to bite, most likely first. Each names the task that pins it.

1. **A pinch that starts with both fingers on the rectangle.** The first finger begins a move drag. Expected: the rectangle scales, and does not jump or slide. Pinned in Task 2 (`testAPinchStartsFromTheLiveRectAndSilencesTheDrag`, `testBothFingersOfAPinchStayIgnoredAfterIt`) and Task 3 (the UI test pinches on the rectangle itself).
2. **One finger lifts, the other keeps moving.** The surviving drag still reports its translation from before the pinch. Expected: nothing moves until that finger lifts too. Pinned in Task 2 (`testTheDragThatLostToAPinchStaysIgnoredUntilItEnds`).
3. **A gesture that is cancelled, not ended** (a system alert, the app going to the background). `onEnded` does not fire. Expected: the next drag and the next pinch work normally. Pinned in Task 2 (`testADragThatNeverEndedBlocksNeitherTheNextDragNorTheNextPinch`) and by the `@GestureState` rule in Task 3.
4. **Pinching out against an edge, and pinching a long thin rectangle.** Expected: it slides to keep growing, stops when one side fills the photo, keeps its shape, and never drops below `ImageFraming.minimumSide`. Pinned in Task 1.
5. **Rotate on a camera shot.** Expected: the rectangle returns to the 10% inset, not to the full photo. The pure rule is pinned in Task 1. The view's use of it for a camera shot cannot be reached by a UI test (no camera in the simulator), so it is an owner-smoke item, listed in Task 3.

---

### Task 1: Rectangle rules

**Files:**
- Modify: `Raconte/Library/CropRectGesture.swift` (add `scaled`)
- Modify: `Raconte/Library/ImageFraming.swift` (add `cameraStartRect`, change `rotated`)
- Modify: `Raconte/Library/PendingFramingQueue.swift` (add `startingCropRect` to `PendingFramingItem`)
- Test: `RaconteTests/CropRectGestureTests.swift`, `RaconteTests/ImageFramingTests.swift`, `RaconteTests/PendingFramingQueueTests.swift`

**Interfaces:**
- Produces:
  - `CropRectGesture.scaled(_ rect: CGRect, by magnification: CGFloat) -> CGRect`
  - `ImageFraming.cameraStartRect: CGRect` (static let)
  - `ImageFraming.rotated(resettingTo rect: CGRect = ImageFraming.identity.cropRect) -> ImageFraming`
  - `PendingFramingItem.startingCropRect: CGRect` (computed)

- [ ] **Step 0: File the issue and make the worktree**

File one GitHub issue titled "Crop: start inset on camera shots, pinch to resize the rectangle", body pointing at the spec path. Use its number for the worktree and branch names (Global Constraints). Run `xcodegen generate` in the worktree. Copy both `docs/plans/2026-11-18-crop-inset-pinch-*.md` files into the worktree if they are not yet on `main`, and commit them first.

- [ ] **Step 1: Write the failing tests**

In `CropRectGestureTests` (it already has `quarter = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)`):

```swift
private func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                        file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(r.minX, x, accuracy: 1e-9, file: file, line: line)
    XCTAssertEqual(r.minY, y, accuracy: 1e-9, file: file, line: line)
    XCTAssertEqual(r.width, w, accuracy: 1e-9, file: file, line: line)
    XCTAssertEqual(r.height, h, accuracy: 1e-9, file: file, line: line)
}

func testPinchGrowsAndShrinksAroundTheCentre() {
    assertRect(CropRectGesture.scaled(quarter, by: 1.2), 0.2, 0.2, 0.6, 0.6)
    assertRect(CropRectGesture.scaled(quarter, by: 0.5), 0.375, 0.375, 0.25, 0.25)
}

func testPinchKeepsTheShapeOfANonSquareRectangle() {
    // 0.4 x 0.8 is 1:2. The height fills the photo at 1.25x, so growth stops there.
    assertRect(CropRectGesture.scaled(CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.8), by: 2),
               0.05, 0, 0.5, 1)
}

func testPinchOutStopsWhenASideFillsThePhoto() {
    assertRect(CropRectGesture.scaled(quarter, by: 10), 0, 0, 1, 1)
}

func testPinchOutAgainstAnEdgeSlidesToKeepGrowing() {
    assertRect(CropRectGesture.scaled(CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5), by: 1.5),
               0, 0.125, 0.75, 0.75)
}

func testPinchInStopsWhenTheShorterSideReachesTheMinimum() {
    assertRect(CropRectGesture.scaled(quarter, by: 0.01), 0.45, 0.45, 0.1, 0.1)
    // 0.2 x 0.6: the width reaches 0.1 at 0.5x, so the height stops at 0.3.
    assertRect(CropRectGesture.scaled(CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.6), by: 0.1),
               0.25, 0.35, 0.1, 0.3)
}

func testPinchWithANonsenseMagnificationChangesNothing() {
    for bad in [0, -1, CGFloat.nan, CGFloat.infinity] {
        XCTAssertEqual(CropRectGesture.scaled(quarter, by: bad), quarter, "\(bad)")
    }
}
```

In `ImageFramingTests`, next to `testRotatedAdvancesOneTurnAndResetsTheRect` (leave that test as it is; it pins the default):

```swift
func testRotatedResetsToTheRectItIsGiven() {
    let framing = ImageFraming(rotationQuarterTurns: 0, cropRect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2))
    let next = framing.rotated(resettingTo: ImageFraming.cameraStartRect)
    XCTAssertEqual(next.normalisedTurns, 1)
    XCTAssertEqual(next.cropRect, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
}

func testTheCameraStartRectIsNotIdentitySoAnUntouchedUseCrops() {
    let framing = ImageFraming(rotationQuarterTurns: 0, cropRect: ImageFraming.cameraStartRect)
    XCTAssertFalse(framing.isIdentity)
}
```

In `PendingFramingQueueTests`:

```swift
func testACameraShotStartsInsetAndALibraryPickStartsFull() {
    let shot = PendingFramingItem(id: UUID(), data: Data(), type: .jpeg, origin: .camera)
    let pick = PendingFramingItem(id: UUID(), data: Data(), type: .jpeg, origin: .library)
    XCTAssertEqual(shot.startingCropRect, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    XCTAssertEqual(pick.startingCropRect, CGRect(x: 0, y: 0, width: 1, height: 1))
}
```

- [ ] **Step 2: Run them to see them fail**

Run the unit command with `-only-testing:RaconteTests/CropRectGestureTests -only-testing:RaconteTests/ImageFramingTests -only-testing:RaconteTests/PendingFramingQueueTests`.
Expected: a BUILD failure naming `scaled`, `cameraStartRect`, `rotated(resettingTo:)` and `startingCropRect`.

- [ ] **Step 3: Implement**

`CropRectGesture.scaled`: clamp the input with `ImageFraming.clamped`. Return it unchanged when `magnification` is not finite or is `<= 0`. Otherwise clamp the factor to the range below, scale both sides by it about the rectangle's centre, then pull the origin inside the unit square (the same origin clamp `moved` uses):

```swift
let lower = max(ImageFraming.minimumSide / r.width, ImageFraming.minimumSide / r.height)
let upper = min(1 / r.width, 1 / r.height)
```

`ImageFraming.cameraStartRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)`, with a doc comment naming the spec and the 10%.

`rotated(resettingTo:)`: as today, but the new framing's `cropRect` is the argument. Update its doc comment.

`PendingFramingItem.startingCropRect`: `cameraStartRect` for `.camera`, `ImageFraming.identity.cropRect` for `.library`.

- [ ] **Step 4: Run the three classes again**

Expected: all pass, and the executed count is 9 higher than Step 2's classes had on `main` (6 + 2 + 1).

- [ ] **Step 5: Prove the shape test can fail**

Temporarily make `upper` use `max` instead of `min`. Expected: `testPinchKeepsTheShapeOfANonSquareRectangle` or `testPinchOutStopsWhenASideFillsThePhoto` fails. Restore it and re-run to green.

- [ ] **Step 6: Commit**

`feat(#203): crop rectangle rules for pinch, the camera start and rotate's reset`

---

### Task 2: Which gesture owns the rectangle

**Files:**
- Create: `Raconte/Library/CropInteraction.swift`
- Create: `RaconteTests/CropInteractionTests.swift`

**Interfaces:**
- Produces:

```swift
/// Decides which gesture's transform applies to the crop rectangle, and from which
/// starting rectangle. Pure; the view holds one in @State.
struct CropInteraction: Equatable, Sendable {
    init()
    /// A drag update. `startLocation` is `DragGesture.Value.startLocation`, which is constant
    /// for one drag and so identifies it. Returns the rectangle the drag's cumulative
    /// translation applies to, or nil when this update must be ignored.
    mutating func dragChanged(from startLocation: CGPoint, current: CGRect) -> CGRect?
    /// The drag identified by `startLocation` ended. Forgets it, whether it was the owner
    /// or an ignored one.
    mutating func dragEnded(from startLocation: CGPoint)
    /// A pinch update. Returns the rectangle the pinch's cumulative magnification applies to.
    mutating func pinchChanged(current: CGRect) -> CGRect
    mutating func pinchEnded()
}
```

The one invariant behind every rule: a gesture's cumulative translation or magnification is
only ever applied to the rectangle that gesture started from. A drag whose start rectangle
is no longer the truth is ignored for the rest of its life, never re-based.

Rules, each one a test below (revised 2026-11-18 after the Task 2 review; see the ledger):
- A drag's first update records `current` as its start; later updates of the same drag return that start.
- A drag with a different `startLocation` takes over: it starts fresh from `current`, and the drag it displaced is ignored from then on. This covers a second finger on another handle, and a drag that was cancelled without `dragEnded`.
- A pinch's first update records `current` as its start, always the live rectangle; later updates return it. A drag that was active when the pinch began is ignored from then on.
- A drag update while a pinch is active returns nil, and that drag is ignored from then on.
- An ignored drag stays ignored after the pinch ends, until `dragEnded(from:)` names it. More than one drag can be ignored at once (two fingers on two handles).
- `dragEnded(from:)` for a drag that is not the owner leaves the owner alone.
- The type cannot detect a cancelled pinch. The caller must call `pinchEnded()` on end AND on cancel (Task 3 does it from a `@GestureState` reset).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Raconte

final class CropInteractionTests: XCTestCase {
    private let a = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    private let b = CGRect(x: 0.2, y: 0.1, width: 0.8, height: 0.8)   // `a` after some drag
    private let c = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)   // after some pinch
    private let p1 = CGPoint(x: 100, y: 100)
    private let p2 = CGPoint(x: 240, y: 300)
    private let p3 = CGPoint(x: 60, y: 420)

    func testADragAppliesToTheRectItStartedFrom() {
        var i = CropInteraction()
        XCTAssertEqual(i.dragChanged(from: p1, current: a), a)
        XCTAssertEqual(i.dragChanged(from: p1, current: b), a, "later updates keep the start, not the live rect")
    }

    func testAPinchAppliesToTheRectItStartedFrom() {
        var i = CropInteraction()
        XCTAssertEqual(i.pinchChanged(current: a), a)
        XCTAssertEqual(i.pinchChanged(current: c), a)
    }

    func testAPinchStartsFromTheLiveRectAndSilencesTheDrag() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)
        XCTAssertEqual(i.pinchChanged(current: b), b, "the pinch scales the rectangle as it is, never a remembered one")
        XCTAssertNil(i.dragChanged(from: p1, current: b), "the drag is ignored while the pinch runs")
    }

    func testADragThatBeginsDuringAPinchIsIgnored() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        XCTAssertNil(i.dragChanged(from: p1, current: a))
    }

    func testTheDragThatLostToAPinchStaysIgnoredUntilItEnds() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)
        _ = i.pinchChanged(current: b)
        i.pinchEnded()
        XCTAssertNil(i.dragChanged(from: p1, current: c), "its translation predates the pinch; applying it would jump")
        i.dragEnded(from: p1)
        XCTAssertEqual(i.dragChanged(from: p1, current: c), c, "a new drag from the same point works once the old one ended")
    }

    func testBothFingersOfAPinchStayIgnoredAfterIt() {
        // Two fingers on two handles: two drags, both silenced by the pinch.
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        XCTAssertNil(i.dragChanged(from: p1, current: a))
        XCTAssertNil(i.dragChanged(from: p2, current: a))
        i.pinchEnded()
        XCTAssertNil(i.dragChanged(from: p1, current: c))
        XCTAssertNil(i.dragChanged(from: p2, current: c), "the second ignored drag must not be forgotten")
        i.dragEnded(from: p1)
        XCTAssertNil(i.dragChanged(from: p2, current: c), "ending one finger does not revive the other")
    }

    func testANewDragAfterAPinchStartsFromTheScaledRect() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        i.pinchEnded()
        XCTAssertEqual(i.dragChanged(from: p2, current: c), c)
    }

    func testASecondFingerOnAnotherHandleTakesOverAndTheFirstIsIgnored() {
        var i = CropInteraction()
        XCTAssertEqual(i.dragChanged(from: p1, current: a), a)
        XCTAssertEqual(i.dragChanged(from: p2, current: b), b, "the newer drag starts from the live rect")
        XCTAssertNil(i.dragChanged(from: p1, current: c), "the displaced drag is never re-based")
        XCTAssertEqual(i.dragChanged(from: p2, current: c), b)
    }

    func testEndingAnIgnoredDragLeavesTheOwnerAlone() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)
        _ = i.dragChanged(from: p2, current: b)
        i.dragEnded(from: p1)
        XCTAssertEqual(i.dragChanged(from: p2, current: c), b)
    }

    func testADragThatNeverEndedBlocksNeitherTheNextDragNorTheNextPinch() {
        var i = CropInteraction()
        _ = i.dragChanged(from: p1, current: a)   // cancelled: dragEnded never arrives; the rect is now b
        XCTAssertEqual(i.dragChanged(from: p2, current: b), b)
        i.dragEnded(from: p2)
        XCTAssertEqual(i.pinchChanged(current: c), c, "a pinch never returns to a dead drag's start")
    }

    func testAnIgnoredDragThatNeverEndedDoesNotBlockTheNextDrag() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        XCTAssertNil(i.dragChanged(from: p1, current: a))
        i.pinchEnded()                            // the ignored drag is cancelled, no dragEnded
        XCTAssertEqual(i.dragChanged(from: p3, current: c), c)
    }

    func testASecondPinchStartsFromTheLiveRect() {
        var i = CropInteraction()
        _ = i.pinchChanged(current: a)
        i.pinchEnded()
        XCTAssertEqual(i.pinchChanged(current: c), c)
    }
}
```

- [ ] **Step 2: Run to see it fail**

`xcodegen generate`, then the unit command with `-only-testing:RaconteTests/CropInteractionTests`.
Expected: BUILD failure, `cannot find 'CropInteraction' in scope`.

- [ ] **Step 3: Implement `CropInteraction` in `Raconte/Library/CropInteraction.swift`**

Private state is the implementer's choice; the rules and tests above determine the behaviour. Foundation and CoreGraphics only, no SwiftUI import. `xcodegen generate` after creating the file.

- [ ] **Step 4: Run the class**

Expected: 12 tests executed, 12 pass. If it reports 0 tests or the class is missing, the project was not regenerated.

- [ ] **Step 5: Prove two tests can fail**

Mutant 1: when a different drag takes over, do not record the displaced drag as ignored. Expected: `testASecondFingerOnAnotherHandleTakesOverAndTheFirstIsIgnored` fails.
Mutant 2: keep only ONE ignored drag (each new ignored drag replaces the last). Expected: `testBothFingersOfAPinchStayIgnoredAfterIt` fails.
Restore after each and re-run to green.

- [ ] **Step 6: Commit**

`feat(#203): CropInteraction decides whether a drag or a pinch owns the crop rectangle`

---

### Task 3: Wire the crop screen

**Files:**
- Modify: `Raconte/Library/UI/ImageFramingView.swift`
- Modify: `Raconte/Library/PendingFramingQueue.swift` (`framingPresentation`, both platform branches)
- Modify: `Raconte/Library/UI/ImageFullScreenViewer.swift` (`framingView(_:)`)
- Test: `RaconteUITests/ImageCaptureUITests.swift`

**Interfaces:**
- Consumes: everything Tasks 1 and 2 produce.
- Produces: `ImageFramingView.init(data: Data, startingCropRect: CGRect, onUse: @escaping (ImageFraming) -> Void, onCancel: @escaping () -> Void)`. `startingCropRect` has NO default, so the compiler makes every call site state it.

- [ ] **Step 1: Write the failing UI test**

Add to `ImageCaptureUITests`, after `testCropRectangleStartsInsideTheScreenMargins`. It reaches the crop screen exactly as that test does (copy its navigation up to and including the `waitUntil` on `cropRect.frame.width > 50`), then:

```swift
let before = cropRect.frame
// Both fingers land ON the rectangle, so the first one begins a move drag: this is the
// Review Focus 1 case, not a pinch on blank space.
cropRect.pinch(withScale: 0.5, velocity: -1)
waitUntil(10, "the pinch never shrank the crop rectangle") { cropRect.frame.width < before.width * 0.8 }
let after = cropRect.frame
XCTAssertGreaterThan(after.width, before.width * 0.2, "it must not collapse to the minimum")
// The seeded image is square, so the rectangle starts square and a pinch must keep it so.
XCTAssertEqual(after.width, after.height, accuracy: 3, "a pinch keeps the rectangle's shape")
XCTAssertEqual(after.midX, before.midX, accuracy: 6, "a pinch scales around the centre, it does not slide")
XCTAssertEqual(after.midY, before.midY, accuracy: 6)
```

Name it `testPinchingShrinksTheCropRectangleAndKeepsItsShape`.

- [ ] **Step 2: Run it to see it fail**

Run the UI command with `-only-testing:RaconteUITests/ImageCaptureUITests/testPinchingShrinksTheCropRectangleAndKeepsItsShape`.
Expected: FAIL with "the pinch never shrank the crop rectangle". Any other failure (the screen never appearing, 0 tests executed) is not the RED this step wants: fix that first.

- [ ] **Step 3: Wire the view**

In `ImageFramingView`:
- Add the stored `let startingCropRect: CGRect` and an explicit `init` (signature in Interfaces) that seeds `_framing` with `ImageFraming(rotationQuarterTurns: 0, cropRect: startingCropRect)`.
- The Rotate button becomes `framing = framing.rotated(resettingTo: startingCropRect)`.
- Replace `@State private var dragStartRect: CGRect?` with `@State private var interaction = CropInteraction()`. In `moveGesture` and `resizeGesture`, `onChanged` asks `interaction.dragChanged(from: value.startLocation, current: framing.cropRect)` and returns early on nil; `onEnded` calls `interaction.dragEnded(from: value.startLocation)`.
- Add the pinch as `.simultaneousGesture` on the `ZStack` inside the `GeometryReader`, so it works anywhere on the screen and alongside the children's drags:

```swift
@GestureState private var pinching = false

private var pinchGesture: some Gesture {
    MagnifyGesture()
        .updating($pinching) { _, state, _ in state = true }
        .onChanged { value in
            let start = interaction.pinchChanged(current: framing.cropRect)
            framing.cropRect = CropRectGesture.scaled(start, by: value.magnification)
        }
}
```

- End the pinch from the flag, never from `onEnded`: `.onChange(of: pinching) { _, now in if !now { interaction.pinchEnded() } }`. A `@GestureState` resets when the gesture ends AND when it is cancelled; `onEnded` does not fire on cancellation, which would leave every later drag ignored (Review Focus 3).
- Update the type's doc comment: the rectangle's start and the pinch.

Call sites:
- `framingPresentation` (both `#if` branches): `startingCropRect: pending.startingCropRect`.
- `ImageFullScreenViewer.framingView(_:)`: `startingCropRect: ImageFraming.identity.cropRect`, with a one-line comment that a stored image has already had its margins removed.

- [ ] **Step 4: Run the new UI test**

Expected: PASS. If the rectangle moves instead of shrinking, or does not change, the drag is winning: check that the pinch is a `simultaneousGesture` and that the drags return early on nil. Do not loosen the assertions.

- [ ] **Step 5: Run the whole `ImageCaptureUITests` class**

Expected: every test passes, and the count is one higher than the class has on `main`. `testUsingAnUnchangedFramingDoesNotAskToReplace` and `testCropRectangleStartsInsideTheScreenMargins` must pass UNCHANGED: they go through the viewer, which still starts at the full photo.

- [ ] **Step 6: Run the full unit suite, then an iOS compile check**

Unit command with no `-only-testing`. Expected: main's baseline (Global Constraints) plus 21, same skip count.
Then: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' -derivedDataPath .superpowers/dd-ios CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Straggler check**

`grep -rn "dragStartRect" Raconte RaconteTests RaconteUITests` must return nothing. Grep the single word `rotated()` across all three targets and read each hit: `ImageFramingTests` keeps its default-argument test; no production call may still reset a camera shot to the full photo.

- [ ] **Step 8: Commit and open the PR**

Commit: `feat(#203): crop starts inset on camera shots; pinch resizes the rectangle`

Push the branch and open a PR against `main` with `gh pr create --body-file`. The body states: what changed; the unit and UI counts against the baseline; that an untouched Use on a camera shot now crops the outer 10% (spec, "Known cost"); and this owner smoke, which no automated test can reach because the simulator has no camera. Do not write a close keyword next to an issue number unless auto-close is intended.

Owner smoke (iPhone, after a TestFlight build of the merged change; the PR body must restate the build number once it is cut):
1. Take a photo for an entry. Pass: the crop rectangle starts inside the photo with an even dimmed band on all four sides. Fail: it starts at the photo's edges.
2. Pinch in and out with both fingers on the rectangle. Pass: it shrinks and grows around its centre and keeps its shape; the photo does not move. Fail: it slides, jumps, or ignores the pinch.
3. Pinch, lift one finger, keep the other moving. Pass: nothing moves until both are up. Fail: the rectangle jumps.
4. Tap Rotate. Pass: the photo turns and the rectangle is back at the inset. Fail: it covers the whole photo.
5. Drag a handle and move the rectangle with one finger. Pass: both work as before.
6. Pick a photo from the library. Pass: the rectangle starts at the photo's edges, as before.

Then stop. Merging and the build are the owner's.
