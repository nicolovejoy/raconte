# Batch B (2026-09-08) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the five presentation follow-ups from the 2026-09-07 build 17 / build 15 smokes as
two independent PRs from `main`: a readability branch (#162 type scale, #161 out-of-span glyph,
#163 quarantine block) and an images-and-live-band branch (#106 journal cover lightbox, #164
live voice mark).

**Architecture:** PR A adds a tiny `TypeScale` token file (one macOS Dynamic Type bump on the
`WindowGroup`, three graded Home point sizes), a `warning` tone in the existing `InkTone` layer
with a contrast test, and a paper-inset block treatment for the Trash screen's unreadable
section. PR B adds a `JournalCoverLightbox` presented from the journal editor's cover strip
(sheet on macOS, full-screen cover on iOS, attached to the `Form` itself), a UI-test cover seed,
and mirrors #136's `paragraphFrames` mechanism with `voiceMarks` (frame + voice) so
`LiveTranscriptText` can break the line and prefix the voice label where a voice tap landed.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency, XcodeGen
project, XCTest + XCUITest.

**Spec:** Issue bodies #162 (with its 2026-09-08 ruling comment), #161, #163, #106 (and #147,
closed as its duplicate, for the two traps), #164. Read each with `gh issue view N --comments`
before starting its task. Owner rulings from the 2026-09-07/08 sessions, restated here:

1. Slate: exactly these five issues, two PRs. **#149 (backdate sheet contrast) was in the
   approved slate and is deliberately left out of this plan**: its own body says it is a
   design-system ask (text-role tokens with stated contrast floors, then a sweep), and the
   "immediate defect" needs measuring against the real surface. A one-off opacity nudge would
   be a guess. It goes back to the owner as its own spec-first item.
2. #162 sizes: **macOS everything ~30% larger** (one root-level bump, judged on a smoke).
   **iOS graded**: the relative-time line under a journal on Home ("18 hours ago") +30%;
   journal titles in Home rows WITH a cover (the face-out shelf) +20%; journal titles in Home
   rows WITHOUT a cover (the spine list) +10%; the "Raconte" title unchanged. Research
   established that these three texts live in `HomeView`, not the sidebar; the sidebar's
   subtitle is a date range and already scales with Dynamic Type.
3. #161: safety orange and ~30% larger, still a marker only (#71 ruling 4: flag, never block).
   The entry-detail sentence is untouched.
4. #106: the lightbox opens from the journal EDITOR's cover strip (the owner's own proposal
   in the #106 thread). The library header band keeps its one job — opening the editor — so
   no nested control there.
5. #164: the live band shows the voice label the voice BUTTON shows — the journal's configured
   label if any, else the uppercased id ("BN"/"LN") — because the live band is a capture-time
   instrument, and an unlabeled break is exactly the "can't see it" the owner reported. The
   persisted (reading) view keeps its opt-in labels (#56); this plan does not touch it.
6. "Use cheaper models a lot": implementers and per-task reviewers on Sonnet; whole-branch
   reviews on Opus.
7. T8 is NOT in this slate. Do not touch transcription, revision or sync code.

## Global Constraints

- **Branch per PR, from `main` at or after `8110828f`.** Two branches:
  `feat/162-161-163-readability` (Tasks 1, 2, 3) and
  `feat/106-164-cover-lightbox-live-voice` (Tasks 4, 5). Each PR body uses `Closes #N` for the
  issues it fully resolves. PR bodies via `--body-file`, never a heredoc. **Merges are the
  owner's.**
- **Worktrees:** one per PR, under `.worktrees/<branch>` (gitignored), created with
  `git worktree add .worktrees/<branch> -b <branch> main`. Run `xcodegen generate` in every
  fresh worktree before the first build.
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
- iOS compile check (required for every task — three tasks branch on `#if os`):
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- UI tests (simulator only). **The whole `RaconteUI` suite exceeds the Bash tool's
  10-minute cap**: run FOREGROUND `-only-testing:RaconteUITests/<Class>` invocations,
  one class at a time, each with the Bash tool's `timeout` set to `600000`. A run past the
  120 s default is silently backgrounded and its completion never arrives. Never
  background a test run.
  `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/<Class> test`
- **Baseline from main's latest code-carrying CI run** (the build-17 bump `3a175a14`,
  2026-09-07): unit **2189** (1 skipped), UI **64**. Each task states its expected delta.
  Two PRs branched from the same base can both be green and still merge red; the owner's
  "Update branch" between merges is the guard.
- **Straggler grep covers all three targets**: `grep -rn <token> Raconte RaconteTests
  RaconteUITests docs CLAUDE.md` for every deleted or renamed symbol, and drive present-tense
  hits to zero. For prose, grep a single word that cannot wrap.
- Source-scanning tests strip comments before matching (`RaconteTests/SourceScanning.swift:12`,
  free function `strippingComments(_:)`). A raw-source grep is satisfied by the comment that
  explains the fix; always strip first.
- Every test written here must be shown RED first (run it before the production change, or
  with the production change stashed) and the failure reason must be the one the plan
  names. A test that cannot fail is a plan defect — report it, do not ship it.
- Accessibility identifiers go on the leaf control, never on a container that would
  overwrite its children's identifiers (`Raconte/Library/UI/TrashView.swift:118-127` restates
  the trap for the section this plan edits).
- `.fileImporter`, `.sheet`, `.fullScreenCover` and `.alert` attach to a screen's OUTER view
  (the `List` / `Form` / `ScrollView` itself), never to a `Section` — on a `Section` they
  silently never present on iOS 26 (`CLAUDE.md`, and `JournalEditorView.swift:189-192`).
- **Never put an `Image` in a macOS `Menu` label** (#69). The cover strip becomes a `Button`,
  never a `Menu`.
- `CaptureLabelTests.testCaptureViewDoesNotReintroduceTheColourLiteralsInkToneReplaced` fails
  on `.foregroundStyle(.white)`, `Color.white.opacity(`, `Color.green`, `.tint(.white)`,
  `.tint(.red)` in `CaptureView.swift`. `SidebarRowInsetTests.testTheRowAppliesTheInsetRule`
  greps `SidebarView.swift` for the literal `leadingInset(isJournal: row.journalID != nil)`.
  Task 5 edits `CaptureView.swift` (one call site); `SidebarView.swift` is not edited. Keep
  those literals intact either way.
- `Logger` lines the owner may read back must be `.notice`, not `.info`.
- Commit after each green step with a conventional message; the reviewer reads the diff,
  not the transcript.

---

## PR A — `feat/162-161-163-readability`

### Task 1: Type scale — macOS root bump, iOS graded Home sizes (#162)

**Files:**
- Create: `Raconte/App/TypeScale.swift`
- Modify: `Raconte/App/RaconteApp.swift:71-81` (`body`, the `WindowGroup` chain with the
  existing `#if os(macOS) .commands {…} #endif`)
- Modify: `Raconte/Home/UI/HomeView.swift:72-73` (face-out title), `:76-78` (relative time),
  `:120-121` (spine title)
- Create: `RaconteTests/TypeScaleTests.swift`
- Modify: `project.yml` — no edit needed (targets glob their folders), but run
  `xcodegen generate` after creating the two files.

**Interfaces:**
- Consumes: `DynamicTypeSize` (SwiftUI), `InkTone` (unchanged), `strippingComments(_:)`.
- Produces: `enum TypeScale` with `static let macDynamicTypeSize: DynamicTypeSize`,
  `static let homeFaceOutTitle: CGFloat`, `static let homeSpineTitle: CGFloat`,
  `static let homeRelativeTime: CGFloat`. Task 2 does not depend on these; nothing else does.

**Why these numbers.** Current Home literals are 13 (face-out title), 17 (spine title), 11
(relative time) on both platforms. iOS ruling: +20%, +10%, +30% → 15.6, 18.7, 14.3 → **16, 19,
14**. macOS ruling ×1.3 → 16.9, 22.1, 14.3 → **17, 22, 14**. Everything else on macOS that uses a
semantic text style scales through `dynamicTypeSize`: `.xxxLarge` is body 23 pt against the
default 17 pt (+35%), `.xxLarge` is 21 pt (+24%); the ruling says "~30%", so this plan picks
**`.xxxLarge`** and the owner judges on the smoke. The remaining `.font(.system(size:))` literals
(TrashView 5, LibraryView 5, one each in a few leaves) do NOT move with Dynamic Type; that is
accepted for this pass and noted in the PR body — if the smoke says they look small next to
the scaled text, that is a follow-up, not this task.

- [ ] **Step 1: Write the failing tests**

Create `RaconteTests/TypeScaleTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Raconte

/// #162: the owner's type-size rulings (2026-09-08) as build-time facts. Sizes are stated in
/// points, per platform — never as text-style names, which differ in size across platforms.
final class TypeScaleTests: XCTestCase {

    private func appSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Raconte/App/RaconteApp.swift")
        return strippingComments(try String(contentsOf: url))
    }

    /// iOS: smallest text up the most, largest not at all. 13/17/11 were the literals before.
    /// macOS: everything ×1.3.
    func testHomeSizesFollowTheRuling() {
        #if os(macOS)
        XCTAssertEqual(TypeScale.homeFaceOutTitle, 17)
        XCTAssertEqual(TypeScale.homeSpineTitle, 22)
        XCTAssertEqual(TypeScale.homeRelativeTime, 14)
        #else
        XCTAssertEqual(TypeScale.homeFaceOutTitle, 16, "+20% over 13")
        XCTAssertEqual(TypeScale.homeSpineTitle, 19, "+10% over 17")
        XCTAssertEqual(TypeScale.homeRelativeTime, 14, "+30% over 11")
        #endif
    }

    /// The macOS bump is one Dynamic Type step above the default's +24%: `.xxxLarge`.
    func testMacDynamicTypeSizeIsXXXLarge() {
        XCTAssertEqual(TypeScale.macDynamicTypeSize, .xxxLarge)
    }

    /// The bump is applied once, at the scene root, inside the macOS-only block — not
    /// per screen, and never on iOS.
    func testTheSceneAppliesTheMacBumpInsideTheMacOSBlock() throws {
        let source = try appSource()
        guard let macBlock = source.range(of: "#if os(macOS)"),
              let endBlock = source.range(of: "#endif", range: macBlock.upperBound..<source.endIndex) else {
            return XCTFail("RaconteApp.swift has no #if os(macOS) block")
        }
        let inside = source[macBlock.upperBound..<endBlock.lowerBound]
        XCTAssertTrue(inside.contains(".dynamicTypeSize(TypeScale.macDynamicTypeSize)"),
                      "the macOS bump must sit in the scene's #if os(macOS) block")
        XCTAssertEqual(source.components(separatedBy: ".dynamicTypeSize(").count - 1, 1,
                       "exactly one dynamicTypeSize call in the scene")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `xcodegen generate`, then the macOS unit command with `-only-testing:RaconteTests/TypeScaleTests`.
Expected: compile FAILURE — `cannot find 'TypeScale' in scope`. That is the RED for this task
(a missing type). Record the message.

- [ ] **Step 3: Create the token file**

Create `Raconte/App/TypeScale.swift`:

```swift
import SwiftUI

/// #162: the app's type-size decisions, in points, per platform (owner ruling 2026-09-08).
///
/// Two levers. On macOS a single Dynamic Type bump at the scene root scales every semantic
/// text style ~30% (the same style names are smaller in points on macOS than iOS —
/// `.callout` is 16 pt on iOS and 12 pt on macOS — so "too small on the laptop" was mostly
/// platform drift). `.font(.system(size:))` literals do NOT move with Dynamic Type, so the
/// Home shelf's three literal sizes are stated here explicitly, graded on iOS: the
/// smallest text up the most, the largest not at all.
enum TypeScale {
    /// One step above the +24% `.xxLarge`: body 23 pt against the default 17 pt.
    static let macDynamicTypeSize: DynamicTypeSize = .xxxLarge

    #if os(macOS)
    /// Was 13 — ×1.3.
    static let homeFaceOutTitle: CGFloat = 17
    /// Was 17 — ×1.3.
    static let homeSpineTitle: CGFloat = 22
    /// Was 11 — ×1.3.
    static let homeRelativeTime: CGFloat = 14
    #else
    /// Was 13 — +20% (journal titles on rows WITH a cover).
    static let homeFaceOutTitle: CGFloat = 16
    /// Was 17 — +10% (journal titles on rows WITHOUT a cover).
    static let homeSpineTitle: CGFloat = 19
    /// Was 11 — +30% (the "18 hours ago" line, the smallest text on Home).
    static let homeRelativeTime: CGFloat = 14
    #endif
}
```

- [ ] **Step 4: Apply the macOS bump at the scene root**

In `Raconte/App/RaconteApp.swift`, change the `body`'s macOS block to:

```swift
        #if os(macOS)
        .commands { RaconteCommands(services: services) }
        .dynamicTypeSize(TypeScale.macDynamicTypeSize)
        #endif
```

`.dynamicTypeSize(_:)` is a `View` modifier; if the compiler rejects it on the `WindowGroup`
chain (it is a `Scene`), move it onto `ContentView(services: services)` inside the
`WindowGroup` closure, wrapped in its own `#if os(macOS) … #endif` — and update the test's
block search accordingly (it only requires the call to sit inside AN `#if os(macOS)` block
in that file, and to appear once).

- [ ] **Step 5: Use the graded sizes on Home**

In `Raconte/Home/UI/HomeView.swift`, replace the three literals:

```swift
                        Text(journal.name)
                            .font(.system(size: TypeScale.homeFaceOutTitle, weight: .medium))
```

```swift
                            Text(last, format: .relative(presentation: .named))
                                .font(.system(size: TypeScale.homeRelativeTime))
```

```swift
                            Text(journal.name)
                                .font(.system(size: TypeScale.homeSpineTitle, design: .serif))
```

Leave `.navigationTitle("Raconte")` (`HomeView.swift:37`) and the chevron's 13 pt alone.

- [ ] **Step 6: Run the tests to verify they pass, and the iOS compile check**

Run the macOS unit command with `-only-testing:RaconteTests/TypeScaleTests`. Expected: 3 PASS.
Run the iOS compile check. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Whole unit suite**

Run the macOS unit command with no filter. Expected: `Executed 2192 tests, with 1 test skipped`
(baseline 2189 + 3), 0 failures.

- [ ] **Step 8: Commit**

```bash
git add Raconte/App/TypeScale.swift Raconte/App/RaconteApp.swift Raconte/Home/UI/HomeView.swift RaconteTests/TypeScaleTests.swift
git commit -m "feat(type): macOS Dynamic Type bump at the scene root; graded Home sizes on iOS (#162)"
```

---

### Task 2: Out-of-span glyph — warning tone, larger (#161)

**Files:**
- Modify: `Raconte/Library/UI/InkSurface.swift:8-56` (`InkTone` cases and `lightColor`)
- Modify: `Raconte/Library/UI/InkSurface+SwiftUI.swift:9-19` (`darkColor`)
- Modify: `Raconte/Library/UI/LibraryView.swift:694-700` (the glyph)
- Modify: `RaconteTests/InkSurfaceTests.swift` (append one test inside the class)
- Modify: `RaconteTests/EntryListItemTests.swift:169-171`
  (`testLibraryRowRendersTheOutOfSpanMarker`; the file's `fileSource(_:)` helper at `:160-166`
  already strips comments)

**Interfaces:**
- Consumes: `InkSurface.contrastOnPaper(_:) -> Double` (`InkSurface.swift:68`),
  `CaptureLabelColor(red:green:blue:)`.
- Produces: `InkTone.warning` (light `#D2570A`, dark `#FF8A2A`). Task 3 uses it for the
  block's leading bar.

**Why these colours.** Safety orange proper (`#FF7900`) is 2.5:1 on white — below the 3.0
graphical-object floor `InkSurfaceTests` already applies to `inkSecondary`. `#D2570A` is a
darkened safety orange at ~4.1:1 on paper. On dark paper the tone lightens to `#FF8A2A`, the
same direction `accent` takes. Size: `.caption2` is 10 pt on macOS / 11 pt on iOS; the ruling
is ~30% larger and in points, so **14 pt, semibold**, on both platforms.

- [ ] **Step 1: Write the failing tests**

Append inside `final class InkSurfaceTests` in `RaconteTests/InkSurfaceTests.swift`:

```swift
    /// #161: the warning tone marks a row (the out-of-span glyph) — a graphical object, so
    /// 3.0 is its floor on paper, and it must not collapse into the accent or record tones.
    func testWarningClearsTheGraphicalFloorAndIsItsOwnColour() {
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.warning.lightColor), 3.0)
        XCTAssertNotEqual(InkTone.warning.lightColor, InkTone.accent.lightColor)
        XCTAssertNotEqual(InkTone.warning.lightColor, InkTone.record.lightColor)
        XCTAssertNotEqual(InkTone.warning.darkColor, InkTone.warning.lightColor,
                          "warning lightens on dark paper, like accent")
    }
```

Replace `testLibraryRowRendersTheOutOfSpanMarker` in `RaconteTests/EntryListItemTests.swift`:

```swift
    /// #71: the row renders the marker. #161: it is the warning tone at 14 pt semibold — a
    /// marker the owner can see from laptop distance, still never a gate.
    func testLibraryRowRendersTheOutOfSpanMarkerInTheWarningTone() throws {
        let source = try fileSource("Raconte/Library/UI/LibraryView.swift")
        guard let glyph = source.range(of: "calendar.badge.exclamationmark"),
              let identifier = source.range(of: "library.outOfSpan", range: glyph.upperBound..<source.endIndex) else {
            return XCTFail("the out-of-span glyph and its identifier are no longer together")
        }
        let block = source[glyph.upperBound..<identifier.lowerBound]
        XCTAssertTrue(block.contains("InkTone.warning.color"), "the glyph is the warning tone")
        XCTAssertTrue(block.contains(".font(.system(size: 14, weight: .semibold))"), "14 pt semibold")
        XCTAssertFalse(block.contains("inkSecondary"), "the quiet tone is gone from this glyph")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the macOS unit command with
`-only-testing:RaconteTests/InkSurfaceTests -only-testing:RaconteTests/EntryListItemTests`.
Expected: compile FAILURE `type 'InkTone' has no member 'warning'` (the RED for both; the
source-pin test would also fail on `InkTone.warning.color` absent). Record it.

- [ ] **Step 3: Add the tone**

In `Raconte/Library/UI/InkSurface.swift`, add a case after `record`:

```swift
    /// The app's one loud colour; shared with capture's record button.
    case record
    /// #161: a marker that must be seen — the out-of-span glyph, the quarantine block's
    /// bar. Darkened safety orange (#D2570A, ~4.1:1 on paper); lightens on dark paper.
    case warning
```

and in `lightColor`, after the `.record` line:

```swift
        case .warning: CaptureLabelColor(red: 0xD2 / 255, green: 0x57 / 255, blue: 0x0A / 255)
```

In `Raconte/Library/UI/InkSurface+SwiftUI.swift` `darkColor`, add before the invariant line:

```swift
        case .warning: CaptureLabelColor(red: 0xFF / 255, green: 0x8A / 255, blue: 0x2A / 255)
```

(`InkTone` is `CaseIterable`; if any `switch` elsewhere over `InkTone` is exhaustive without a
default, the compiler names it — add the `.warning` case there with the same values.)

- [ ] **Step 4: Change the glyph**

In `Raconte/Library/UI/LibraryView.swift:694-700`:

```swift
                // #71: flagged, never blocked (owner ruling 4) — a marker only, never a
                // gate on any control or filter. #161: warning tone, 14 pt — the quiet
                // caption2/inkSecondary version was invisible at laptop distance.
                if item.isDatedOutsideJournalSpan {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(InkTone.warning.color)
                        .accessibilityLabel("Dated outside this journal's range")
                        .accessibilityIdentifier("library.outOfSpan")
                }
```

Leave the two sibling markers at `:677` and `:685` (`clock.arrow.circlepath`,
`questionmark.circle`) as they are — they are status, not warnings.

- [ ] **Step 5: Run the tests to verify they pass, and the iOS compile check**

Same two classes. Expected: all PASS, including the pre-existing `InkSurfaceTests`. iOS compile
check: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Raconte/Library/UI/InkSurface.swift Raconte/Library/UI/InkSurface+SwiftUI.swift Raconte/Library/UI/LibraryView.swift RaconteTests/InkSurfaceTests.swift RaconteTests/EntryListItemTests.swift
git commit -m "feat(library): out-of-span glyph in a new InkTone.warning at 14 pt (#161)"
```

---

### Task 3: Trash — the unreadable section as a distinct block (#163)

**Files:**
- Modify: `Raconte/Library/UI/TrashView.swift:116-133` (`unreadableSection`), `:143-165`
  (`unreadableRow`)
- Create: `RaconteTests/TrashUnreadableSectionSourceTests.swift`
- Run: `RaconteUITests/TrashRepairUITests.swift` (unchanged; it must still pass — it finds the
  header by `trash.unreadable.section`, the row by `trash.unreadable.row`, the button by
  `trash.unreadable.quarantine`)

**Interfaces:**
- Consumes: `InkTone.paperInset` (existing; the `selectionBar` at `TrashView.swift:304` and
  `EntryInfoSheet.swift:85` already use it as the inset ground), `InkTone.warning` (Task 2),
  `LibraryScreenModel.unreadableEntries`.
- Produces: nothing new for later tasks. Identifiers unchanged.

**Design.** Three things, all presentation: (1) every unreadable row sits on the paper-inset
ground with a 3 pt warning bar down its leading edge, so the block reads as one tinted panel;
(2) the header carries the count — `Unreadable entries · 1`; (3) the explanatory footer moves
INTO the block as the last row on the same ground, so the tint ends where the trash begins,
and the ordinary trash rows keep their plain ground. No behavior changes.

- [ ] **Step 1: Write the failing source-pin test**

Create `RaconteTests/TrashUnreadableSectionSourceTests.swift`:

```swift
import XCTest
@testable import Raconte

/// #163: the Trash screen's unreadable-entries block is visually its own thing — tinted
/// ground, warning bar, count in the header — while the ordinary trash rows stay plain.
/// Pinned at the source level (comment-stripped) because SwiftUI's row background is not
/// reachable from XCUITest.
final class TrashUnreadableSectionSourceTests: XCTestCase {

    private func trashSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RaconteTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Raconte/Library/UI/TrashView.swift")
        return strippingComments(try String(contentsOf: url))
    }

    /// The block between the section's opening and the `trash.unreadable.section` header
    /// identifier carries the inset ground and the warning bar; the header names the count.
    func testTheUnreadableBlockIsTintedBarredAndCounted() throws {
        let source = try trashSource()
        guard let start = source.range(of: "private var unreadableSection"),
              let header = source.range(of: "trash.unreadable.section", range: start.upperBound..<source.endIndex) else {
            return XCTFail("unreadableSection or its header identifier is gone")
        }
        let block = source[start.upperBound..<header.lowerBound]
        XCTAssertTrue(block.contains(".listRowBackground(InkTone.paperInset.color)"),
                      "unreadable rows sit on the inset ground")
        XCTAssertTrue(block.contains("InkTone.warning.color"), "a warning bar marks the block")
        XCTAssertTrue(block.contains("Unreadable entries · \\(model.unreadableEntries.count)"),
                      "the header carries the count")
    }

    /// The ordinary trash rows keep the plain ground: the tint must not leak.
    func testTheOrdinaryTrashRowsAreNotTinted() throws {
        let source = try trashSource()
        guard let row = source.range(of: "struct TrashEntryRow") else {
            return XCTFail("TrashEntryRow is gone")
        }
        XCTAssertFalse(source[row.upperBound...].contains(".listRowBackground(InkTone.paperInset.color)"),
                       "the inset ground belongs to the unreadable block only")
    }
}
```

- [ ] **Step 2: Regenerate and run the test to verify it fails**

Run: `xcodegen generate`, then the macOS unit command with
`-only-testing:RaconteTests/TrashUnreadableSectionSourceTests`.
Expected: `testTheUnreadableBlockIsTintedBarredAndCounted` FAILS on "unreadable rows sit on
the inset ground"; the second test PASSES already (it pins a negative — that is fine, it
guards Step 3 against leaking).

- [ ] **Step 3: Restyle the block**

Replace `unreadableSection` in `Raconte/Library/UI/TrashView.swift`:

```swift
    @ViewBuilder
    private var unreadableSection: some View {
        if !model.unreadableEntries.isEmpty {
            // The identifier goes on the HEADER text alone, never on the `Section`
            // itself: a `Section`-level `.accessibilityIdentifier` cascades to every
            // descendant (header, each row, footer) and silently overwrites their own
            // — measured, not assumed, the same container-identifier trap
            // `TrashEntryRow`'s comment and `unreadableRow` below both call out. The
            // section's presence is what `trash.unreadable.section` names, so the
            // header carrying it is enough.
            //
            // #163: the block is visibly its own thing — inset ground and a warning bar
            // on every row, the explanation as the block's last row on the same ground,
            // and the count in the header — so it cannot read as the first few rows of
            // the trash below it (the owner's "why so many?" on the build 17 smoke).
            Section {
                ForEach(model.unreadableEntries) { item in
                    unreadableRow(item)
                        .listRowBackground(InkTone.paperInset.color)
                }
                Text("These entries’ settings files could not be read. Quarantine moves "
                     + "the whole entry, audio included, out of the library into the "
                     + "app’s quarantine folder. Nothing is deleted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(InkTone.paperInset.color)
            } header: {
                Text("Unreadable entries · \(model.unreadableEntries.count)")
                    .accessibilityIdentifier("trash.unreadable.section")
            }
        }
    }
```

and in `unreadableRow`, add the bar to the returned `HStack` (the modifiers already on it stay;
add these two just before the existing `.accessibilityElement(children: .contain)`):

```swift
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(InkTone.warning.color)
                .frame(width: 3)
        }
```

- [ ] **Step 4: Run the source test, then the UI test**

Macos unit command with `-only-testing:RaconteTests/TrashUnreadableSectionSourceTests`.
Expected: 2 PASS.
UI: the simulator command with `-only-testing:RaconteUITests/TrashRepairUITests`, Bash
`timeout: 600000`. Expected: `Executed 1 test`, 0 failures — the identifiers did not move.
iOS compile check is covered by the UI run.

- [ ] **Step 5: Whole unit suite**

Run the macOS unit command with no filter. Expected: `Executed 2195 tests, with 1 test skipped`
(baseline 2189; Task 1 +3, Task 2 +1 net [one test added, one replaced], Task 3 +2). State
the number you got; if it differs, find out why before committing.

- [ ] **Step 6: Commit**

```bash
git add Raconte/Library/UI/TrashView.swift RaconteTests/TrashUnreadableSectionSourceTests.swift
git commit -m "feat(trash): unreadable entries as a tinted, barred, counted block (#163)"
```

- [ ] **Step 7: Open PR A**

Push `feat/162-161-163-readability`; `gh pr create --base main --body-file <file>`. Body: what
each of the three tasks changed, `Closes #162`, `Closes #161`, `Closes #163`, the unit and UI
counts you observed against the baseline, and the accepted gap from Task 1 (the
`.font(.system(size:))` literals outside Home do not scale on macOS). Do not merge.

---

## PR B — `feat/106-164-cover-lightbox-live-voice`

### Task 4: Journal cover lightbox from the editor's cover strip (#106)

**Files:**
- Create: `Raconte/Library/UI/JournalCoverLightbox.swift`
- Modify: `Raconte/Library/UI/JournalEditorView.swift:76-90` (`Section("Cover")`), the
  `@State` block near the top of the struct (add `showingCoverLightbox`), and the `Form`'s
  modifier chain at `:197-213` (add the presentation right after the existing
  `.sheet(isPresented: $showingCoverPicker)`)
- Modify: `Raconte/Capture/Debug/UITestSupport.swift` (append `UITestJournalCoverSeed`)
- Modify: `Raconte/Library/LibraryScreenModel.swift:283-288` (call the seed inside `rescan()`
  before the cover read loop, `#if DEBUG`)
- Modify: `RaconteTests/JournalEditorSourceTests.swift` (append one test)
- Modify: `RaconteUITests/JournalEditorUITests.swift` (append one test after
  `testAddingACoverOpensTheRealPickerSheet`, reusing its `launchApp`/`openCapture`/
  `firstJournalRow`/`press` helpers — read the top of the file for their signatures; if
  `launchApp` cannot take extra environment, add an optional `environment: [String: String]`
  parameter to it, defaulting to `[:]`)

**Interfaces:**
- Consumes: `JournalCoverThumbnail.decode(_:) -> Image?` (`JournalCoverImage.swift:26-36`),
  `JournalCoverPreview(data:)`, `LibraryScreenModel.journalCovers: [String: Data]`,
  `JournalCoverStore.write(imageData:journalID:) async throws` (`JournalCoverStore.swift:71`),
  `UITestImageSeed.onePixelRedPNGBase64` (private today — make it `static let` internal, or
  copy the literal into the new seed; prefer widening access).
- Produces: `struct JournalCoverLightbox: View { let data: Data }`; identifiers
  `journalEditor.cover.preview` (the strip, now a button), `journalCover.lightbox` (the image
  container), `journalCover.lightbox.done`; env `RACONTE_UITEST_SEED_JOURNAL_COVER`.

**Facts that shape this.** Covers are stored once, downscaled to 1024 px on the long side
(`JournalCoverStore.swift:28,40`); there is no larger original, so "full screen" means the
1024 px JPEG scaled to fit — say so in the view's doc comment. `JournalEditorView` is a `Form`
(`:63`) and its cover strip is inside `Section("Cover")` — the presentation goes on the `Form`
chain next to the existing cover-picker sheet, never on the section. `fullScreenCover` does
not exist on macOS; mirror `EntryDetailView.swift:374-378`'s split.

- [ ] **Step 1: Write the failing source-pin test**

Append inside `final class JournalEditorSourceTests` in `RaconteTests/JournalEditorSourceTests.swift`
(the class has a comment-stripped source helper — read lines 9-20 for its name and use it;
the snippet below calls it `editorSource()`):

```swift
    /// #106: the cover strip is a button that opens the lightbox, and the lightbox is
    /// presented from the Form's own modifier chain — at the same indentation as the
    /// cover-picker sheet — never from inside `Section("Cover")` (the iOS 26 trap).
    func testCoverLightboxIsPresentedFromTheFormNotTheSection() throws {
        let source = try editorSource()
        XCTAssertTrue(source.contains("journalEditor.cover.preview"), "the strip is tappable")
        let lines = source.components(separatedBy: "\n")
        guard let picker = lines.first(where: { $0.contains(".sheet(isPresented: $showingCoverPicker)") }),
              let lightbox = lines.first(where: { $0.contains("isPresented: $showingCoverLightbox)") }) else {
            return XCTFail("cover picker sheet or cover lightbox presentation is missing")
        }
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        XCTAssertEqual(indent(picker), indent(lightbox),
                       "the lightbox must hang off the Form exactly where the picker sheet does")
        XCTAssertTrue(source.contains("#if os(iOS)\n" + String(repeating: " ", count: indent(lightbox)) + ".fullScreenCover(isPresented: $showingCoverLightbox)")
                      || source.contains(".fullScreenCover(isPresented: $showingCoverLightbox)"),
                      "iOS presents full screen")
        XCTAssertTrue(source.contains(".sheet(isPresented: $showingCoverLightbox)"), "macOS presents a sheet")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Macos unit command with `-only-testing:RaconteTests/JournalEditorSourceTests`.
Expected: the new test FAILS on "the strip is tappable" (identifier absent). The three
pre-existing tests still PASS.

- [ ] **Step 3: Create the lightbox**

Create `Raconte/Library/UI/JournalCoverLightbox.swift`:

```swift
import SwiftUI

/// #106: a journal's cover at the largest size we have. Covers are stored once, downscaled to
/// 1024 px on the long side (`JournalCoverStore`), so this is that JPEG scaled to fit — there
/// is no larger original, unlike entry images. Presented full-screen on iOS and as a large
/// sheet on macOS (`fullScreenCover` does not exist there), always from the editor `Form`'s
/// own modifier chain. Dismiss: Done, Esc (macOS, via the cancel keyboard shortcut), or a
/// tap anywhere on the image's ground.
struct JournalCoverLightbox: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = JournalCoverThumbnail.decode(data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Text("This cover could not be decoded.")
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .accessibilityIdentifier("journalCover.lightbox")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("journalCover.lightbox.done")
                }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 540)
            #endif
        }
    }
}
```

- [ ] **Step 4: Make the strip a button and present the lightbox**

In `Raconte/Library/UI/JournalEditorView.swift`: add `@State private var showingCoverLightbox = false`
beside `showingCoverPicker`. In `Section("Cover")`, replace the preview line:

```swift
                    if let cover = model.journalCovers[journalID] {
                        // #106: the strip stays the cropped preview the form wants, but a
                        // tap opens the whole image. A `Button` label, never a `Menu`
                        // label — an `Image` in a macOS `Menu` label renders at intrinsic
                        // size and covers the screen (#69).
                        Button { showingCoverLightbox = true } label: {
                            JournalCoverPreview(data: cover)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View cover")
                        .accessibilityIdentifier("journalEditor.cover.preview")
                        .listRowInsets(EdgeInsets())
```

On the `Form`'s modifier chain, directly after the closing brace of
`.sheet(isPresented: $showingCoverPicker) { … }` and at the SAME indentation:

```swift
            // #106: presented from the Form, never from `Section("Cover")` — a `.sheet`
            // on a Section silently never presents on iOS 26.
            #if os(iOS)
            .fullScreenCover(isPresented: $showingCoverLightbox) {
                if let cover = model.journalCovers[journalID] { JournalCoverLightbox(data: cover) }
            }
            #else
            .sheet(isPresented: $showingCoverLightbox) {
                if let cover = model.journalCovers[journalID] { JournalCoverLightbox(data: cover) }
            }
            #endif
```

- [ ] **Step 5: Run the source test, then compile both platforms**

`-only-testing:RaconteTests/JournalEditorSourceTests` → all PASS. iOS compile check →
`BUILD SUCCEEDED`. (If `testCoverSectionDocumentsTheKnownMacOSGap` or
`testFieldsAppearInDesignOrder` fails, you moved something they pin — read them and restore
the order/comment; do not edit those tests.)

- [ ] **Step 6: Commit the production change**

```bash
git add Raconte/Library/UI/JournalCoverLightbox.swift Raconte/Library/UI/JournalEditorView.swift RaconteTests/JournalEditorSourceTests.swift
git commit -m "feat(journal): cover strip opens a full-size lightbox from the editor (#106)"
```

- [ ] **Step 7: Write the failing UI test**

Append inside `JournalEditorUITests` in `RaconteUITests/JournalEditorUITests.swift`:

```swift
    /// #106: a journal WITH a cover shows the strip as a tappable preview; tapping it opens
    /// the lightbox, Done closes it and the editor is still there. The cover is seeded by
    /// `UITestJournalCoverSeed` because XCUITest cannot drive a real photo pick.
    func testTappingTheCoverPreviewOpensTheLightbox() {
        let app = XCUIApplication()
        app.launchEnvironment["RACONTE_UITEST_ID"] = UUID().uuidString
        app.launchEnvironment["RACONTE_UITEST_SEED_JOURNAL_COVER"] = "1"
        app.launch()
        openCapture(app)
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30),
                      "capture screen never appeared after openCapture")

        let journalRow = firstJournalRow(app)
        XCTAssertTrue(journalRow.waitForExistence(timeout: 15))
        press(journalRow)

        let header = app.descendants(matching: .any)
            .matching(identifier: "journal.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        press(header)

        let preview = app.buttons["journalEditor.cover.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15),
                      "the seeded cover did not render as a tappable preview")
        press(preview)

        let done = app.buttons["journalCover.lightbox.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 15), "the lightbox never presented")
        press(done)

        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "the lightbox did not dismiss")
        XCTAssertTrue(app.textFields["journalEditor.name"].firstMatch.waitForExistence(timeout: 10),
                      "dismissing the lightbox should land back on the editor")
    }
```

If the class's `launchApp()` is the only way its other tests set `RACONTE_UITEST_ID`, keep the
inline launch above — it is the same shape `TrashRepairUITests` uses.

- [ ] **Step 8: Run the UI test to verify it fails for the right reason**

Simulator command with `-only-testing:RaconteUITests/JournalEditorUITests/testTappingTheCoverPreviewOpensTheLightbox`,
Bash `timeout: 600000`. Expected: FAIL at "the seeded cover did not render as a tappable
preview" — no seed exists yet, so the journal has no cover and the strip shows
`journalEditor.cover.add` instead.

- [ ] **Step 9: Add the seed**

In `Raconte/Capture/Debug/UITestSupport.swift`, widen `onePixelRedPNGBase64` from
`private static let` to `static let` on `UITestImageSeed`, then append:

```swift
/// #106: a real, decodable cover on the first journal, for the editor's lightbox UI test —
/// XCUITest cannot drive a photo pick. Env-gated (`RACONTE_UITEST_SEED_JOURNAL_COVER`) and
/// idempotent (no-op when the journal already has a cover). Runs inside
/// `LibraryScreenModel.rescan()` — the only place that has both the registry's journal ids
/// and the cover store — before the covers are read, so the same rescan publishes it.
enum UITestJournalCoverSeed {
    static func seedIfRequested(store: JournalCoverStore, journalIDs: [String]) async {
        guard ProcessInfo.processInfo.environment["RACONTE_UITEST_SEED_JOURNAL_COVER"] != nil,
              let journalID = journalIDs.first,
              await store.read(journalID: journalID) == nil,
              let data = Data(base64Encoded: UITestImageSeed.onePixelRedPNGBase64) else { return }
        try? await store.write(imageData: data, journalID: journalID)
    }
}
```

In `Raconte/Library/LibraryScreenModel.swift` `rescan()`, directly before
`var loadedCovers: [String: Data] = [:]`:

```swift
        #if DEBUG
        await UITestJournalCoverSeed.seedIfRequested(store: journalCoverStore,
                                                     journalIDs: (loadedJournals ?? []).map(\.id))
        #endif
```

If `JournalCoverStore.write` refuses a 1×1 PNG (it downscales through ImageIO; a 1 px image
should pass — `UITestImageSeed` already round-trips the same bytes through `ImageStore`), report
it rather than switching to a hand-written JPEG. `UITestSupport.swift` is `#if DEBUG` in whole
or in part — match whatever the file's other seeds do.

- [ ] **Step 10: Run the UI test to verify it passes, then the whole class**

Same single-test invocation → PASS. Then `-only-testing:RaconteUITests/JournalEditorUITests`
(the whole class, `timeout: 600000`). Expected: every test in the class passes and the
executed count is the class's previous count + 1.

- [ ] **Step 11: Commit**

```bash
git add Raconte/Capture/Debug/UITestSupport.swift Raconte/Library/LibraryScreenModel.swift RaconteUITests/JournalEditorUITests.swift
git commit -m "test(journal): seed a cover and prove the lightbox opens and closes (#106)"
```

---

### Task 5: Live voice mark inline (#164)

**Files:**
- Modify: `Raconte/Capture/CaptureCoordinator.swift:108-110` (beside `paragraphFrames`),
  `:334-343` (`appendMarker`), `:826` (the wiring reset)
- Modify: `Raconte/Capture/UI/LiveTranscriptText.swift` (whole file is 62 lines)
- Modify: `Raconte/Capture/UI/CaptureView.swift:153` (the `LiveTranscriptText(...)` call)
- Modify: `RaconteTests/LiveTranscriptTextTests.swift` (append four tests)
- Modify: `RaconteTests/CaptureCoordinatorTests.swift` (append one test after
  `testParagraphFramesAccumulateAndResetWithTheWiring`, `:1165-1180`; reuse its
  `FakeSession`/`FakeRecorder`/`makeCoordinator` exactly as that test does)

**Interfaces:**
- Consumes: `TranscriptAttribution.cutIndex(forFrame:ranges:)` (`TranscriptAttribution.swift:345`),
  `VoiceDisplay.accessibilityName(forVoice:voiceLabels:)` (`VoiceDisplay.swift:42` — configured
  label, else uppercased id; the same rule the voice button uses at `CaptureView.swift:613`),
  `CaptureScreenModel.selectedJournalVoiceLabels` (`CaptureScreenModel.swift:135`),
  `StructureMarker.Voice.littleNico` / `.bigNico` (ids `"ln"` / `"bn"`).
- Produces: `struct LiveVoiceMark: Equatable, Sendable { let frame: Int64; let voice: String }`
  (in `CaptureCoordinator.swift`, file scope), `CaptureCoordinator.voiceMarks: [LiveVoiceMark]`
  (`private(set)`), `LiveTranscriptText.attributed(_:paragraphFrames:voiceMarks:voiceLabels:ink:dim:)`
  with the two new parameters defaulted, so every existing call and test compiles unchanged.

**Rendering rule.** Compute a cut index per voice mark with the same nearer-edge
`cutIndex(forFrame:ranges:)` the ¶ break uses. At a run index that carries a voice cut: the
separator before it is a blank line (`"\n\n"`) exactly as for a ¶ (a ¶ and a voice at the
same index make ONE break), and the run's text is prefixed with `"<label>: "` in semibold
(`inlinePresentationIntent = .stronglyEmphasized`) in the run's own colour. Two voice marks at
the same index: the later one wins. A voice cut at index 0 (a tap before any words) prefixes the
first run with no leading break. Label = `VoiceDisplay.accessibilityName(forVoice:voiceLabels:)`
(ruling 5).

- [ ] **Step 1: Write the failing unit tests**

Append inside `LiveTranscriptTextTests` (uses the file's `run(_:_:)` helper at `:12-14`):

```swift
    private func mark(_ frame: Int64, _ voice: String) -> LiveVoiceMark {
        LiveVoiceMark(frame: frame, voice: voice)
    }

    /// #164: a voice tap between two runs starts a new line AND names the voice, with the
    /// same fallback label the voice button shows (uppercased id) when the journal has none.
    func testAVoiceMarkBetweenRunsBreaksTheLineAndPrefixesTheLabel() {
        let runs = [run("one two", 0..<100), run("three", 100..<200)]
        let s = LiveTranscriptText.attributed(runs, voiceMarks: [mark(100, "ln")], ink: .white, dim: .gray)
        XCTAssertEqual(String(s.characters), "one two\n\nLN: three")
        let label = s.runs.first { String(s[$0.range].characters) == "LN: " }
        XCTAssertNotNil(label, "the label is its own attributed run")
        XCTAssertEqual(label?.inlinePresentationIntent, .stronglyEmphasized, "the label is semibold")
    }

    /// The journal's configured label wins over the id, exactly as on the voice button.
    func testAVoiceMarkUsesTheJournalsConfiguredLabel() {
        let runs = [run("one two", 0..<100), run("three", 100..<200)]
        let s = LiveTranscriptText.attributed(runs, voiceMarks: [mark(100, "ln")],
                                              voiceLabels: ["ln": "Little Nico"], ink: .white, dim: .gray)
        XCTAssertEqual(String(s.characters), "one two\n\nLittle Nico: three")
    }

    /// A ¶ and a voice tap at the same cut make ONE blank line, not two.
    func testAVoiceMarkAndAParagraphAtTheSameCutMakeOneBreak() {
        let runs = [run("one two", 0..<100), run("three", 100..<200)]
        let s = LiveTranscriptText.attributed(runs, paragraphFrames: [100], voiceMarks: [mark(100, "ln")],
                                              ink: .white, dim: .gray)
        XCTAssertEqual(String(s.characters), "one two\n\nLN: three")
    }

    /// A voice tap before any words labels the first run with no leading break; the later of
    /// two marks at one cut wins.
    func testAVoiceMarkAtTheStartLabelsTheFirstRunAndTheLaterMarkWins() {
        let runs = [run("one", 0..<100), run("two", 100..<200)]
        let s = LiveTranscriptText.attributed(runs, voiceMarks: [mark(0, "bn"), mark(0, "ln")],
                                              ink: .white, dim: .gray)
        XCTAssertEqual(String(s.characters), "LN: one two")
    }
```

Append inside `CaptureCoordinatorTests`, after `testParagraphFramesAccumulateAndResetWithTheWiring`:

```swift
    /// #164: the live band needs each voice tap's frame AND voice off the coordinator, in
    /// order — the same shape as `paragraphFrames` (#136) — reset with the wiring.
    func testVoiceMarksAccumulateAndResetWithTheWiring() async throws {
        let session = FakeSession(); let recorder = FakeRecorder()
        let fixedNow = Date(timeIntervalSince1970: 1_650_000_000)
        let coordinator = makeCoordinator(session: session, recorder: recorder, now: { fixedNow })

        await coordinator.record()
        recorder.feed(frames: 480)
        coordinator.markVoice(StructureMarker.Voice.littleNico)
        recorder.feed(frames: 240)
        coordinator.markVoice(StructureMarker.Voice.bigNico)

        XCTAssertEqual(coordinator.voiceMarks,
                       [LiveVoiceMark(frame: 480, voice: "ln"), LiveVoiceMark(frame: 720, voice: "bn")])

        await coordinator.done()

        XCTAssertEqual(coordinator.voiceMarks, [])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Macos unit command with
`-only-testing:RaconteTests/LiveTranscriptTextTests -only-testing:RaconteTests/CaptureCoordinatorTests`.
Expected: compile FAILURE `cannot find 'LiveVoiceMark' in scope`. That is the RED. Record it.

- [ ] **Step 3: Coordinator state**

In `Raconte/Capture/CaptureCoordinator.swift`, at file scope (near the top, after the imports or
beside other small types the file declares):

```swift
/// #164: one voice tap as the live transcript needs it — where it landed and which voice it
/// switched to. The on-disk `StructureMarker` is the record; this is the in-memory mirror
/// for the live band, the same relationship `paragraphFrames` has to ¶ markers (#136).
struct LiveVoiceMark: Equatable, Sendable {
    let frame: Int64
    let voice: String
}
```

Beside `paragraphFrames` (`:108-110`):

```swift
    /// #164: this capture's voice taps (frame + voice), for the live transcript; reset with
    /// the wiring, like `paragraphFrames`.
    private(set) var voiceMarks: [LiveVoiceMark] = []
```

In `appendMarker`, after `if case .voice = kind { currentVoice = voice }`:

```swift
            if case .voice = kind, let voice { voiceMarks.append(LiveVoiceMark(frame: frame, voice: voice)) }
```

In the wiring reset (`:826`, after `paragraphFrames = []`):

```swift
        voiceMarks = []
```

- [ ] **Step 4: Render it**

Replace the body of `Raconte/Capture/UI/LiveTranscriptText.swift`'s struct (keep the file's
`CaptureProse` enum untouched):

```swift
struct LiveTranscriptText: View {
    let runs: [ConsolidatedTranscriptRun]
    /// #136: the frames of this capture's ¶ taps — the same coordinator state
    /// `CaptureCoordinator.paragraphFrames` exposes. Recomputed on every render from
    /// `runs`, so a provisional run that gets re-ranged moves the break with it.
    var paragraphFrames: [Int64] = []
    /// #164: this capture's voice taps (`CaptureCoordinator.voiceMarks`), placed by the
    /// same cut rule. Each one breaks the line and prefixes the voice's label.
    var voiceMarks: [LiveVoiceMark] = []
    /// The selected journal's configured labels; absent ones fall back to the uppercased
    /// id — the voice BUTTON's rule (`VoiceDisplay.accessibilityName`), so the band and
    /// the button always agree. The reading view's opt-in labels (#56) are a different
    /// surface with a different rule; this is a capture-time instrument.
    var voiceLabels: [String: String] = [:]

    var body: some View {
        Text(Self.attributed(runs, paragraphFrames: paragraphFrames, voiceMarks: voiceMarks,
                             voiceLabels: voiceLabels,
                             ink: InkTone.studioInk.color, dim: InkTone.studioInkDim.color))
            .font(CaptureProse.font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Pure, so the dim-in-the-middle rule is testable without a renderer. Runs are joined
    /// with single spaces, except at a paragraph break (#136) or a voice change (#164),
    /// which render as a blank line ("\n\n") instead — same nearer-edge cut rule the
    /// detail screen uses (`TranscriptAttribution.cutIndex(forFrame:ranges:)`), so live
    /// and post-hoc agree on where a break falls. A voice change also prefixes the run
    /// with "<label>: " in semibold; the later of two marks at one cut wins; a mark at
    /// index 0 labels the first run with no leading break.
    static func attributed(_ runs: [ConsolidatedTranscriptRun], paragraphFrames: [Int64] = [],
                           voiceMarks: [LiveVoiceMark] = [], voiceLabels: [String: String] = [:],
                           ink: Color, dim: Color) -> AttributedString {
        let visible = runs.filter { !$0.text.isEmpty }
        let ranges = visible.map(\.range)
        var breaks = Set(paragraphFrames.map { TranscriptAttribution.cutIndex(forFrame: $0, ranges: ranges) })
        var labels: [Int: String] = [:]
        for mark in voiceMarks {
            let index = TranscriptAttribution.cutIndex(forFrame: mark.frame, ranges: ranges)
            labels[index] = VoiceDisplay.accessibilityName(forVoice: mark.voice, voiceLabels: voiceLabels)
            breaks.insert(index)
        }
        var out = AttributedString()
        for (index, run) in visible.enumerated() {
            let colour = run.isProvisional ? dim : ink
            if !out.characters.isEmpty {
                var separator = AttributedString(breaks.contains(index) ? "\n\n" : " ")
                separator.foregroundColor = out.runs.last?.foregroundColor
                out.append(separator)
            }
            if let label = labels[index] {
                var prefix = AttributedString("\(label): ")
                prefix.foregroundColor = colour
                prefix.inlinePresentationIntent = .stronglyEmphasized
                out.append(prefix)
            }
            var piece = AttributedString(run.text)
            piece.foregroundColor = colour
            out.append(piece)
        }
        return out
    }
}
```

Check the existing behaviour still holds: `testFramesAtTheEdgesRenderNoBreak` relies on an
out-of-range cut index not matching any `index` — unchanged, since `labels` and `breaks` are
only consulted at real indices.

- [ ] **Step 5: Wire the capture screen**

`Raconte/Capture/UI/CaptureView.swift:153`:

```swift
                LiveTranscriptText(runs: transcription.runs,
                                   paragraphFrames: model.coordinator.paragraphFrames,
                                   voiceMarks: model.coordinator.voiceMarks,
                                   voiceLabels: model.selectedJournalVoiceLabels)
```

`voiceMarks` changes only on a tap, never on the 100 ms tick, so this adds no tick-rate read to
`CaptureView.body` (#155's containment holds — do not touch `elapsed` or `micLevel`).

- [ ] **Step 6: Run the tests to verify they pass, then the iOS compile check**

Same two classes → all PASS (the four new `LiveTranscriptTextTests` and the one coordinator
test, plus every pre-existing test in both classes). iOS compile check → `BUILD SUCCEEDED`.

- [ ] **Step 7: Whole unit suite and the capture UI classes**

Macos unit command, no filter. Expected: `Executed 2195 tests, with 1 test skipped`
(baseline 2189; Task 4 +1, Task 5 +5). State the number you got.
UI: `-only-testing:RaconteUITests/CaptureControlsUITests` and
`-only-testing:RaconteUITests/CaptureUITests`, each foreground with `timeout: 600000` — the
live band is rendered in both; expect both classes green at their previous counts.

- [ ] **Step 8: Commit and open PR B**

```bash
git add Raconte/Capture/CaptureCoordinator.swift Raconte/Capture/UI/LiveTranscriptText.swift Raconte/Capture/UI/CaptureView.swift RaconteTests/LiveTranscriptTextTests.swift RaconteTests/CaptureCoordinatorTests.swift
git commit -m "feat(capture): live transcript breaks and labels at each voice tap (#164)"
```

Push `feat/106-164-cover-lightbox-live-voice`; `gh pr create --base main --body-file <file>`.
Body: what each task changed, `Closes #106`, `Closes #164`, the observed unit and UI counts
against the baseline (UI expected **65**: 64 + 1), ruling 5 restated (live label = button
label; reading view untouched), and that the lightbox shows the 1024 px stored cover because
no larger original exists. Do not merge.

---

## Self-review

- **Spec coverage:** #162 → Task 1 (both platforms, all four graded texts; "Raconte" untouched
  by construction). #161 → Task 2. #163 → Task 3. #106 → Task 4 (editor strip only, per
  ruling 4; header band unchanged). #164 → Task 5. #149 → excluded, stated in ruling 1 with
  the reason; the owner decides its next step.
- **Placeholders:** none. Every code step shows the code.
- **Type consistency:** `TypeScale.homeFaceOutTitle/homeSpineTitle/homeRelativeTime/macDynamicTypeSize`
  (Task 1, test and production agree); `InkTone.warning` (Tasks 2 and 3);
  `LiveVoiceMark(frame:voice:)`, `CaptureCoordinator.voiceMarks`,
  `LiveTranscriptText.attributed(_:paragraphFrames:voiceMarks:voiceLabels:ink:dim:)` (Task 5,
  tests and production agree); identifiers `journalEditor.cover.preview`,
  `journalCover.lightbox`, `journalCover.lightbox.done`, env
  `RACONTE_UITEST_SEED_JOURNAL_COVER` (Task 4, test, seed and view agree).
- **Counts:** PR A unit 2189 → 2195 (Task 1 +3, Task 2 +1 net, Task 3 +2), UI 64 → 64.
  PR B unit 2189 → 2195 (Task 4 +1, Task 5 +5), UI 64 → 65. After both merge: unit 2201,
  UI 65.
