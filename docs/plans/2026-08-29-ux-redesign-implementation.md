# UX Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the ink & paper UX redesign — shared token layer, transcript-first entry detail with a `⋯` sheet, one designed journal picker, redesigned library, calm capture landing — as four staged PRs.

**Architecture:** A new pure-Foundation token model (`InkSurface`, patterned on `CaptureSurface`) feeds every screen. Screen changes are re-arrangements of existing sections and models — `LibraryScreenModel`, `CaptureScreenModel`, routing, and stores are untouched except where a task says otherwise. Every metadata/editing affordance the detail screen loses moves into one sheet; every ad-hoc journal `Menu` is replaced by one `JournalPickerSheet`.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency, XcodeGen project, XCTest + XCUITest.

**Spec:** `docs/plans/2026-08-29-ux-redesign-design.md` (read it first; it carries the owner's four decisions and the mock references).

## Global Constraints

- Xcode project is generated: after editing `project.yml` (not needed for these tasks — new files under `Raconte/` and `RaconteTests/` are picked up by the existing target globs) run `xcodegen generate`. After clone: `xcodegen generate` before anything.
- macOS unit-test command (the ONLY correct one — never `CODE_SIGNING_ALLOWED=NO`):
  `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test`
- iOS compile check: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- UI tests (simulator only): `xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/<Class> test` — always `-only-testing:` per class; the whole suite exceeds the 10-minute tool cap. Never background these runs.
- UI tests navigate via `openPlace(app, "sidebar.…")` (`RaconteUITests/UITestNavigation.swift`) — never hard-code navigation taps.
- Sheets attach to a screen's OUTER view, never to a `Form`/`List` `Section` (iOS 26 silently never presents them).
- Nothing that must happen during a capture may hang off view lifecycle (`.onAppear`/`.onDisappear`/`.task` on a view) — it lives on `CaptureScreenModel`.
- Never put an `Image` in a macOS `Menu` label (#69).
- Preserve existing accessibility identifiers unless a task explicitly renames one; UI tests key off them.
- Existing test baseline must stay green each task; run the unit suite before each commit.
- Branch/PR flow: PR 1 branches from `main`; each later PR branches from the previous PR's branch (stacked — tell any worktree/agent its base branch EXPLICITLY, they default to `main`). End each PR with `gh pr create` (never merge; merges are Nico's). No close-verb + issue-number in PR bodies unless auto-close is intended.
- Commit trailer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

## PR 1 — Ink token layer (branch `feat/ux-ink-tokens`, from `main`)

### Task 1: InkSurface token model + SwiftUI adapter

**Files:**
- Create: `Raconte/Library/UI/InkSurface.swift`
- Create: `Raconte/Library/UI/InkSurface+SwiftUI.swift`
- Test: `RaconteTests/InkSurfaceTests.swift`

**Interfaces:**
- Consumes: `CaptureSurface` (`Raconte/Capture/UI/CaptureSurface.swift`) — `backgroundWhite`, `relativeLuminance`, `contrastRatio`; `CaptureLabelColor`.
- Produces: `InkTone` enum (`paper, paperInset, hairline, ink, inkSecondary, accent, record, studio`), `InkTone.lightColor: CaptureLabelColor`, `InkSurface.contrastOnPaper(_:) -> Double`, and SwiftUI `InkTone.color: Color` (light value; dark mode handled in Task 2). Later tasks reference tones as `InkTone.paper.color` etc.

- [ ] **Step 1: Write the failing test**

```swift
// RaconteTests/InkSurfaceTests.swift
import XCTest
@testable import Raconte

/// The ink & paper token layer's checkable guarantees — same shape as CaptureLabelTests:
/// the palette is constant, so its contrast is a build-time fact, not a squint test.
final class InkSurfaceTests: XCTestCase {

    /// Reading text on paper: WCAG AA for normal text, both text tones.
    func testInkTonesClearAAOnPaper() {
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.ink.lightColor), 4.5)
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.inkSecondary.lightColor), 3.0,
            "inkSecondary is a secondary tone — 3.0 (large-text AA) is its floor")
    }

    /// The accent is used for tappable text — it must clear AA for normal text on paper.
    func testAccentClearsAAOnPaper() {
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.accent.lightColor), 4.5)
    }

    /// The studio tone IS the capture background — one near-black, never two.
    func testStudioMatchesCaptureSurface() {
        let studio = InkTone.studio.lightColor
        XCTAssertEqual(studio.red, CaptureSurface.backgroundWhite)
        XCTAssertEqual(studio.green, CaptureSurface.backgroundWhite)
        XCTAssertEqual(studio.blue, CaptureSurface.backgroundWhite)
    }

    /// Hairline vs paper must differ (a divider that vanishes is drift), but hairlines
    /// are decoration, not text — no WCAG floor, just "not identical".
    func testHairlineIsDistinctFromPaper() {
        XCTAssertNotEqual(InkTone.hairline.lightColor, InkTone.paper.lightColor)
    }

    /// Record red on paper (the library's floating button draws white-on-record):
    /// white on record must clear 3.0 (large text / graphical object floor).
    func testWhiteOnRecordClearsGraphicalFloor() {
        let record = InkTone.record.lightColor
        let luminanceRecord = CaptureSurface.relativeLuminance(record)
        let luminanceWhite = CaptureSurface.relativeLuminance(white: 1.0)
        let contrast = (max(luminanceRecord, luminanceWhite) + 0.05) / (min(luminanceRecord, luminanceWhite) + 0.05)
        XCTAssertGreaterThanOrEqual(contrast, 3.0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (macOS unit command from Global Constraints, or `-only-testing:RaconteTests/InkSurfaceTests`).
Expected: FAIL to compile — `InkTone` not defined.

- [ ] **Step 3: Write the model**

```swift
// Raconte/Library/UI/InkSurface.swift
import Foundation

/// The app-wide "ink & paper" palette as pure channel values, extending the
/// `CaptureSurface` idea (constant surface ⇒ checkable contrast) to the reading
/// surfaces. Light values here are the design's committed hex values
/// (spec: docs/plans/2026-08-29-ux-redesign-design.md); dark-mode counterparts live in
/// `InkSurface+SwiftUI.swift` because they ride SwiftUI's appearance system.
enum InkTone: CaseIterable, Sendable {
    /// Reading background — warm white.
    case paper
    /// Inset ground: sheets, the pinned play bar.
    case paperInset
    /// Dividers.
    case hairline
    /// Primary text.
    case ink
    /// Secondary text.
    case inkSecondary
    /// Warm amber — links, active states, scrubber fill.
    case accent
    /// The app's one loud colour; shared with capture's record button.
    case record
    /// The capture screen's fixed near-black. Pinned to `CaptureSurface.backgroundWhite`.
    case studio

    var lightColor: CaptureLabelColor {
        switch self {
        case .paper: CaptureLabelColor(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEE / 255)
        case .paperInset: CaptureLabelColor(red: 0xF0 / 255, green: 0xEC / 255, blue: 0xE3 / 255)
        case .hairline: CaptureLabelColor(red: 0xE5 / 255, green: 0xDF / 255, blue: 0xD4 / 255)
        case .ink: CaptureLabelColor(red: 0x21 / 255, green: 0x1D / 255, blue: 0x18 / 255)
        case .inkSecondary: CaptureLabelColor(red: 0x8B / 255, green: 0x84 / 255, blue: 0x78 / 255)
        case .accent: CaptureLabelColor(red: 0x96 / 255, green: 0x68 / 255, blue: 0x3A / 255)
        case .record: CaptureLabelColor(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
        case .studio: .grey(CaptureSurface.backgroundWhite)
        }
    }
}

enum InkSurface {
    /// Contrast of a tone against light-mode paper — same WCAG 2.1 math as
    /// `CaptureSurface.contrastOnSurface`, different ground.
    static func contrastOnPaper(_ color: CaptureLabelColor) -> Double {
        let a = relativeLuminance(color)
        let b = relativeLuminance(InkTone.paper.lightColor)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func relativeLuminance(_ color: CaptureLabelColor) -> Double {
        0.2126 * CaptureSurface.relativeLuminance(white: color.red)
            + 0.7152 * CaptureSurface.relativeLuminance(white: color.green)
            + 0.0722 * CaptureSurface.relativeLuminance(white: color.blue)
    }
}
```

NOTE: `inkSecondary` (#8B8478) lands ~3.5:1 on paper — that is why the test floors it at 3.0, not 4.5. If the test's 4.5 assertions fail for `ink` or `accent`, darken the failing tone until it passes and record the adjusted hex in the spec — do not lower the floor.

- [ ] **Step 4: Write the SwiftUI adapter**

```swift
// Raconte/Library/UI/InkSurface+SwiftUI.swift
import SwiftUI

/// SwiftUI half of `InkTone` — the model stays pure Foundation (CaptureSurface split).
/// Dark mode: reading surfaces follow the system appearance, so each tone carries a
/// dark counterpart and resolves through a dynamic Color. Capture surfaces keep using
/// `.studio` + pinned `.dark` colour scheme exactly as today.
extension InkTone {
    /// Dark-appearance channel values. Paper family inverts to warm near-blacks;
    /// text inverts to warm off-whites; accent lightens to keep contrast on dark
    /// paper; record and studio are appearance-invariant.
    var darkColor: CaptureLabelColor {
        switch self {
        case .paper: CaptureLabelColor(red: 0x16 / 255, green: 0x14 / 255, blue: 0x11 / 255)
        case .paperInset: CaptureLabelColor(red: 0x1F / 255, green: 0x1C / 255, blue: 0x18 / 255)
        case .hairline: CaptureLabelColor(red: 0x2E / 255, green: 0x2A / 255, blue: 0x24 / 255)
        case .ink: CaptureLabelColor(red: 0xEC / 255, green: 0xE8 / 255, blue: 0xE0 / 255)
        case .inkSecondary: CaptureLabelColor(red: 0x9A / 255, green: 0x93 / 255, blue: 0x87 / 255)
        case .accent: CaptureLabelColor(red: 0xC8 / 255, green: 0x93 / 255, blue: 0x5E / 255)
        case .record, .studio: lightColor
        }
    }

    var color: Color {
        #if os(iOS)
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? darkColor : lightColor
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        })
        #else
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? darkColor : lightColor
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        })
        #endif
    }
}
```

- [ ] **Step 5: Run the test to verify it passes; run the full unit suite**

Expected: `InkSurfaceTests` PASS; no regressions.

- [ ] **Step 6: Commit**

```bash
git add Raconte/Library/UI/InkSurface.swift Raconte/Library/UI/InkSurface+SwiftUI.swift RaconteTests/InkSurfaceTests.swift
git commit -m "feat(ux): InkSurface — ink & paper token layer with pinned contrast"
```

### Task 2: Adopt tokens on existing surfaces

**Files:**
- Modify: `Raconte/Capture/UI/CaptureView.swift` (two `Color(white: 0.05)` literals — root ZStack background and the control bar)
- Modify: `Raconte/App/ContentView.swift` (`detailRoot`)
- Test: existing suites only (behavioral no-op)

**Interfaces:**
- Consumes: `InkTone.studio.color`, `InkTone.accent.color`.
- Produces: reading places (`.allEntries`, `.journal`, `.trash`, `.about`) render with `.tint(InkTone.accent.color)` and `InkTone.paper.color` background; capture keeps its pinned dark surface via the token.

- [ ] **Step 1: Replace both capture background literals**

In `CaptureView.swift`, replace each `Color(white: 0.05)` with `InkTone.studio.color`. `InkSurfaceTests.testStudioMatchesCaptureSurface` plus the existing `testBackgroundMatchesTheRenderedCaptureBackground` (CaptureLabelTests) keep the pin honest — if the latter greps the literal, update it to reference the token and keep the assertion against `CaptureSurface.backgroundWhite`.

- [ ] **Step 2: Tint + ground the reading places**

In `ContentView.swift`'s `detailRoot`, wrap the non-capture cases' views:

```swift
LibraryView(...)
    .tint(InkTone.accent.color)
    .background(InkTone.paper.color)
```

Apply the same two modifiers to `.allEntries`, `.journal`, `.trash`, `.about` cases (NOT `.capture`, NOT `.debug`). Also give `LibraryView`'s `List` a matching ground: in `LibraryView.swift` add `.scrollContentBackground(.hidden)` and `.background(InkTone.paper.color)` on the `List`.

- [ ] **Step 3: Build both platforms, run unit suite + one UI class**

Run the iOS compile check, the macOS unit command, then
`-only-testing:RaconteUITests/NavigationUITests` on the simulator.
Expected: all green — this task changes colors, not structure.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(ux): adopt ink tokens — studio background via token, paper + amber tint on reading places"
```

### Task 3: Open PR 1

- [ ] **Step 1:** Push and open the PR with `gh pr create --title "UX redesign 1/4: ink & paper token layer" --body-file <tmpfile>` (body: summary, test evidence, "Part of #108/#55/#18 groundwork" — no close verbs). Do not merge.

---

## PR 2 — Entry detail: transcript first + `⋯` sheet + #103 (branch `feat/ux-entry-detail`, from `feat/ux-ink-tokens`)

### Task 4: #103 verification test (stale transcript on page turn)

**Files:**
- Test: `RaconteUITests/EntryPagingUITests.swift` (extend)

**Interfaces:**
- Consumes: existing paging UI (`detail.nextEntry`, `detail.transcript.text` / `detail.transcript.paragraph.0`), `openPlace`.
- Produces: a pinned regression test; possibly a `.id(captureID)` fix if the pin is missing on some route.

- [ ] **Step 1: Write the test**

Add to `EntryPagingUITests` a test that: opens All Entries, taps the first `library.entryLink`, records the transcript element's label, taps `detail.nextEntry`, and asserts the transcript label CHANGED (fixture entries must have distinct transcript text — check the existing UI-test fixture setup in that file and reuse it; if its entries share text, give them distinct words). Also cover the list→back→list→tap-second-entry route (the #103 report's likely path): back via the nav bar, tap the second `library.entryLink`, assert the transcript matches entry 2, not entry 1.

- [ ] **Step 2: Run it**

`-only-testing:RaconteUITests/EntryPagingUITests` on the simulator.
- If GREEN: #101's `.id(captureID)` pin already fixed #103. Note this in the commit message; the test stays as the regression pin.
- If RED: find the unpinned route — `ContentView`'s `navigationDestination(for: LibraryDestination.self)` must apply `.id(captureID)` to `EntryDetailView` on EVERY route that can show it. Add the missing pin, re-run to green.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test(detail): pin #103 — transcript never lingers across entry navigation"
```

### Task 5: EntryInfoSheet — the `⋯` sheet

**Files:**
- Create: `Raconte/Library/UI/EntryInfoSheet.swift`
- Modify: `Raconte/Library/UI/EntryDetailView.swift` (toolbar + presentation only in this task)
- Test: `RaconteTests/EntryInfoSheetTests.swift`, `RaconteUITests/EntryDetailSheetUITests.swift` (new)

**Interfaces:**
- Consumes: `EntryListItem` (`formattedEffectiveDate()`, `capturedAt`, `durationSeconds`, `journal?.name`, `isBackdated`), `CaptureCoordinator.formatDuration`.
- Produces: `EntryInfoSheet(item:onJournal:onBackdate:onAddImage:onEditTranscript:onMarkVoices:onRevisionHistory:onTrash:)` — all closures `() -> Void`; a static `EntryInfoSheet.headerSubtitle(capturedAt:durationSeconds:) -> String` pure helper. Accessibility identifiers (MOVED here, names preserved so existing UI tests keep working after Task 6): `detail.journalPicker` (the Journal row), `detail.backdateButton`, `entryDetail.images.captureButton` (now "Add Image…"), `detail.editButton`, `detail.markVoicesButton`, `detail.revisionHistoryButton`, `detail.trashButton`. New: `detail.moreButton` (the `⋯` toolbar button), `detail.infoSheet` (the sheet root).

- [ ] **Step 1: Write the unit test**

```swift
// RaconteTests/EntryInfoSheetTests.swift
import XCTest
@testable import Raconte

final class EntryInfoSheetTests: XCTestCase {
    func testHeaderSubtitleCarriesRecordedDateAndDuration() {
        let date = Date(timeIntervalSince1970: 1_756_300_000)
        let subtitle = EntryInfoSheet.headerSubtitle(capturedAt: date, durationSeconds: 161)
        XCTAssertTrue(subtitle.contains(CaptureCoordinator.formatDuration(161)))
        XCTAssertTrue(subtitle.contains(date.formatted(date: .abbreviated, time: .shortened)))
    }
}
```

- [ ] **Step 2: Run it — expect compile failure** (`EntryInfoSheet` undefined).

- [ ] **Step 3: Implement the sheet**

New view: a `NavigationStack`-free `VStack` (it is a sheet, not a push) with `.presentationDetents([.medium, .large])` on iOS. Structure (ink tokens throughout; ground `InkTone.paperInset.color`):

- Header: `Text(EntryDetailView.navigationTitleText(for: item))` full date, `.font(.headline)`; below it `EntryInfoSheet.headerSubtitle(...)` = `"Recorded \(capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(CaptureCoordinator.formatDuration(durationSeconds))"` in `InkTone.inkSecondary.color`. If `item.backdateWasDetected`, keep the "Detected from the recording" caption here (moved from the old datesSection, identifier `detail.detectedDate`).
- Rows, each a full-width `Button` (`HStack` of `Image(systemName:)` + label + optional trailing value + chevron), separated by `InkTone.hairline.color` dividers:
  1. Journal — trailing value `item.journal?.name ?? "Unfiled"`, identifier `detail.journalPicker`, calls `onJournal` (this task: reuse the existing `Menu` content inline as a temporary `Menu` row is NOT allowed — macOS Menu+image trap and it defeats the design; instead `onJournal` presents the journal choices exactly as the old `journalSection` `Menu` did, via a `confirmationDialog` listing `model.journals` for now; Task 10 in PR 3 swaps it to `JournalPickerSheet`).
  2. Backdate — trailing value: the formatted date or "Not backdated"; identifier `detail.backdateButton`; calls `onBackdate` (dismiss the sheet, then open the existing backdate sheet).
  3. Add Image… — identifier `entryDetail.images.captureButton`; calls `onAddImage` (dismiss, present existing `imagePickerSheet`).
  4. Edit transcript — `detail.editButton` → `onEditTranscript`.
  5. Mark voices — `detail.markVoicesButton` → `onMarkVoices`.
  6. Revision history — `detail.revisionHistoryButton` → `onRevisionHistory`.
  7. Move to Trash — red (`InkTone.record.color` text + trash icon), visually separated by extra spacing above, identifier `detail.trashButton` → `onTrash` (dismiss, then existing confirmation dialog).

In `EntryDetailView`: add `@State private var showingInfoSheet = false`; a `ToolbarItem(placement: .primaryAction)` `⋯` button (`ellipsis.circle`, identifier `detail.moreButton`) BEFORE the paging chevrons group; `.sheet(isPresented: $showingInfoSheet) { ... }` attached alongside the existing sheets on the ScrollView (outer view — never inside a section). Each closure dismisses the sheet first, then triggers the existing `@State` flag (`showingEditor = true` etc.). Sequencing note: on iOS, setting a second presentation immediately after dismissing a sheet needs the dismissal to complete — flip the follow-on flag in the sheet's `onDismiss:` via a small pending-action enum:

```swift
private enum InfoSheetAction { case journal, backdate, addImage, editTranscript, markVoices, revisionHistory, trash }
@State private var pendingInfoAction: InfoSheetAction?
// .sheet(isPresented: $showingInfoSheet, onDismiss: performPendingInfoAction) { ... }
```

`performPendingInfoAction()` switches on `pendingInfoAction`, sets the matching existing flag, and nils it. Pushed destinations (`showingEditor`, `showingVoiceMarking`, `showingRevisionHistory`) don't strictly need the dance but use it anyway for one uniform path.

Do NOT remove the old in-body sections yet — that is Task 6. Both affordances existing for one commit is fine; identifiers may NOT be duplicated though, so in THIS task rename the old in-body buttons' identifiers by suffixing `.legacy` (they are deleted next task).

- [ ] **Step 4: Write the UI test**

`EntryDetailSheetUITests`: `openPlace` → All Entries → first entry → tap `detail.moreButton` → assert `detail.infoSheet` exists, assert `detail.editButton` exists inside it, tap `detail.editButton`, assert the transcript editor appears (existing editor identifier — check `TranscriptEditorView` for its root identifier and use it). Second test: `detail.trashButton` → confirmation dialog appears (`detail.confirmTrash`), cancel.

- [ ] **Step 5: Run unit test + the new UI class; expect green. Commit.**

```bash
git add -A
git commit -m "feat(detail): EntryInfoSheet — one sheet for metadata, editing, and trash (#55)"
```

### Task 6: Transcript-first body + pinned play bar

**Files:**
- Modify: `Raconte/Library/UI/EntryDetailView.swift` (body restructure)
- Test: existing `EntryDetailView*Tests` (update), `RaconteUITests/EntryDetailSheetUITests.swift` (extend)

**Interfaces:**
- Consumes: Task 5's sheet (now the ONLY home of the moved affordances).
- Produces: body order = images strip (only when non-empty) → transcript → truncation note; play bar pinned via `.safeAreaInset(edge: .bottom)`; nav back button shows the journal name.

- [ ] **Step 1: Restructure the body**

In `EntryDetailView.body`'s ScrollView VStack, the new order and removals:
- DELETE `datesSection` from the body ("Recorded" row + detected caption + backdate button live in the sheet now; delete the `.legacy`-suffixed leftovers from Task 5). Keep `navigationTitleView` exactly as is (tappable date).
- DELETE `journalSection` (sheet row now).
- DELETE `trashSection` (sheet row now).
- `imagesSection` becomes strip-only and moves FIRST: no "Images" header `Text`, no "Nothing captured yet" empty text, no "Capture Image…" button (sheet row now) — when `images.isEmpty` the section renders `EmptyView()`. Keep the strip's identifiers (`entryDetail.images.strip`, thumbnails) and the tap→viewer behavior. Keep `.onDrop`/`.onPasteCommand` on the screen unchanged.
- `transcriptSection` follows: DELETE its "Transcript" header `Text` and the three edit buttons (sheet rows now); keep all four content states with their identifiers, the voice-attributed rendering, and the truncation note. Recolor secondary/empty-state text with `InkTone.inkSecondary.color`.
- MOVE playback out of the scroll: delete `playbackSection` from the VStack; add to the ScrollView:

```swift
.safeAreaInset(edge: .bottom) {
    if Self.playbackSectionVisible(hasAudio: item.hasAudio) {
        playbackBar
    }
}
```

`playbackBar` = the old `playbackSection` content inside an `HStack` padded 14/20, `.background(InkTone.paperInset.color)`, top `InkTone.hairline.color` divider (`overlay(alignment: .top)` 1-pt rectangle). Keep `detail.play` and `PlaybackProgressLine` untouched.
- Back label: on the pushing side nothing changes; set `.navigationTitle` untouched — the journal-name back treatment comes free on iOS from the previous screen's title. Verify, don't build: if the back button shows "Back", set the LIBRARY screen's `.navigationBarBackButtonTitle` equivalents aside — do NOT invent custom back buttons; accept the platform default if the journal name doesn't appear.

- [ ] **Step 2: Update unit tests**

`EntryDetailViewBackdateAffordanceTests` / `...TranscriptDisplayTests` etc. pin pure helpers (`backdateButtonVisible`, `transcriptDisplay`, `playbackSectionVisible`) — these still exist and must keep passing unchanged. Any test that asserts on removed section behavior (check `EntryDetailViewImagesSectionTests`) updates to the new rule: add a pure helper `static func imagesStripVisible(imageCount: Int) -> Bool { imageCount > 0 }`, use it in the view, pin it in the test.

- [ ] **Step 3: Run the affected UI classes**

`EntryDetailSheetUITests`, `EntryPagingUITests`, plus any class matching `EntryDetail*` in `RaconteUITests` — expect green after updating assertions that referenced deleted in-body buttons (they now assert via the sheet).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(detail): transcript-first body, pinned play bar (#55)"
```

### Task 7: Image-first invitation (#107 affordance) — INVESTIGATE FIRST

**Files:**
- Modify: `Raconte/Library/UI/EntryDetailView.swift`
- Test: `RaconteTests/EntryDetailViewImagesSectionTests.swift` (extend)

**Interfaces:**
- Consumes: `item.hasAudio`, `images`.
- Produces: for `!item.hasAudio && !images.isEmpty`, the transcript area renders an invitation block ("No words yet." + "Tell the story of this picture — your voice becomes the entry's words." + a 72-pt record-red button, identifier `detail.recordInvite`). Pure helper `static func inviteRecordingVisible(hasAudio: Bool, imageCount: Int) -> Bool`.

- [ ] **Step 1: INVESTIGATION GATE — report before implementing the button.** Search the capture stack (`CaptureScreenModel`, `CaptureCoordinator`, `BlankEntryMinter`) for any existing path that records audio INTO an existing captureID. Expected finding: none exists (capture always mints a new capture directory). Report the finding back to the coordinator before proceeding. Ruling either way: if a record-into-entry path EXISTS, the 72-pt button uses it; if NOT, render the invitation TEXT ONLY (identifier `detail.recordInvite.text`, no button — a button that can't record into this entry would be a fake affordance, and capture-core plumbing is out of scope for this PR). The button then becomes the first task of the deferred #107 creation-flow pass. The pure helper and tests are written either way.

- [ ] **Step 2: Test → red → implement → green** (pure helper first: `inviteRecordingVisible(hasAudio: false, imageCount: 1) == true`, `(true, 1) == false`, `(false, 0) == false` — the last is the plain absent-transcript case, not an invitation). Replace the transcript section's content for the invitation case; the `.absent` state string ("This entry was not transcribed.") must NOT show simultaneously.

- [ ] **Step 3: Run unit suite; commit.**

```bash
git add -A
git commit -m "feat(detail): image-first entries invite speaking, not typing (#107)"
```

### Task 8: Open PR 2

- [ ] **Step 1:** Push, `gh pr create --title "UX redesign 2/4: transcript-first entry detail" --base feat/ux-ink-tokens --body-file <tmpfile>` (body may say "Fixes #103" — auto-close intended — and "part of #55/#107", no close verb on those). Do not merge.

---

## PR 3 — Journal picker + library (branch `feat/ux-journals`, from `feat/ux-entry-detail`)

### Task 9: JournalPickerSheet

**Files:**
- Create: `Raconte/Library/UI/JournalPickerSheet.swift`
- Test: `RaconteTests/JournalPickerSheetTests.swift`

**Interfaces:**
- Consumes: `LibraryScreenModel.journals`, `.journalCovers`, `.dateLine(forJournal:)`; entry counts need a per-journal count — check `LibraryScreenModel` for an existing per-journal count source (`allEntries` filtered by `journalID`); if none is cheap, the count line is `dateLine` only — decide from what the model already exposes, do not add model API.
- Produces: `JournalPickerSheet(journals:covers:currentJournalID:dateLine:onSelect:onNewJournal:)` where `onSelect: (String) -> Void`, `onNewJournal: () -> Void`. Row identifiers `journalPicker.row.<journalID>`, sheet root `journalPicker.sheet`, new-journal row `journalPicker.new`. Pure helper `static func rowSubtitle(dateLine: String?, entryCount: Int?) -> String`.

- [ ] **Step 1: Unit test** for `rowSubtitle` (`("Jun – Aug 2026", 41)` → `"Jun – Aug 2026 · 41 entries"`; `(nil, nil)` → `""`; singular `1 entry`). Red first.

- [ ] **Step 2: Implement.** A sheet (`.presentationDetents([.medium, .large])` iOS): title "Choose Journal", rows = 52-pt cover thumbnail (`AsyncCaptureImage`-style load from the covers dict; coverless → a neutral rounded rect `InkTone.paperInset.color` with a small mic SVG-equivalent `Image(systemName: "book.closed")` in `inkSecondary` — never a broken/photo icon), name (semibold when current), subtitle, trailing checkmark (`InkTone.accent.color`) on `currentJournalID`. Divider, then "New Journal…" row (dashed-border tile + label in accent). Rows are `Button`s (never `Menu` — #69).

- [ ] **Step 3: Green; commit.**

```bash
git add -A
git commit -m "feat(journals): JournalPickerSheet — the one designed journal switcher (#18)"
```

### Task 10: Adopt the picker on capture + detail

**Files:**
- Modify: `Raconte/Capture/UI/CaptureView.swift` (`JournalHeaderView`, line ~395)
- Modify: `Raconte/Library/UI/EntryDetailView.swift` / `EntryInfoSheet.swift` (Journal row)
- Test: `RaconteUITests` classes covering the capture journal picker (grep `capture.journalPicker` in RaconteUITests and update those flows: menu-item taps become sheet-row taps)

- [ ] **Step 1:** `JournalHeaderView`'s `Menu` → a `Button` with the same label (name + chevron, identifier `capture.journalPicker` kept) that sets a new `@State showingJournalPicker` on `CaptureView` (sheet attached at CaptureView's root ZStack level). `onSelect` calls the exact code path the old menu buttons called (`CaptureScreenModel`'s journal-switch method — find it via the old `Menu` content); `onNewJournal` triggers the existing "New Journal" alert flow. The sheet pins `.environment(\.colorScheme, .dark)`? NO — sheets render on their own material and follow ambient appearance (see `CaptureLabel`'s scope comment); present it plain.
- [ ] **Step 2:** `EntryInfoSheet`'s Journal row: replace the Task 5 `confirmationDialog` with `JournalPickerSheet` (nested presentation from the info sheet — dismiss info sheet first via the pending-action dance, then present the picker from `EntryDetailView`). `onSelect` = existing `model.moveEntry` path with `moveFailed` handling.
- [ ] **Step 3:** Update + run the affected UI classes; commit.

```bash
git add -A
git commit -m "feat(journals): capture + detail adopt JournalPickerSheet (#18)"
```

### Task 11: Library redesign — cover band, rows, floating record

**Files:**
- Modify: `Raconte/Library/UI/LibraryView.swift` (header, `LibraryEntryRow`, floating button)
- Modify: `Raconte/Library/UI/JournalHeaderCard.swift` (replaced by the band — check what else uses it before deleting; if only LibraryView, delete it)
- Test: `RaconteTests/EntryListItemTests.swift` (month grouping helper), UI class for library (grep existing)

**Interfaces:**
- Consumes: `model.yearGroups`, `model.journalCovers`, `model.dateLine`, `JournalHeaderCard.onEdit` route (`onEditJournal`).
- Produces: `LibraryView` header = 190-pt band (cover image `scaledToFill` + bottom scrim gradient + serif title + subtitle overlay; coverless = `InkTone.paperInset.color` band, ink title, "Add Cover" pill → `onEditJournal(journal.id)`); tap anywhere on the band still routes to the journal editor. Rows: 56-pt thumb (entry's `leadingThumbnail`, else neutral `paperInset` tile with `book.closed`/mic glyph — replace the `photo` placeholder), date + weekday · duration on one line, 2-line serif snippet; drop the per-row journal-name caption when the list is scoped to a journal (keep it for All Entries). Month sub-headers inside year sections: pure helper `EntryListItem.monthGroups(of items:) -> [(month: String, items: [EntryListItem])]` (or a static on a small `LibraryGrouping` enum — put it beside `yearGroups`' source), pinned by unit test with entries spanning two months. Floating record button (60 pt, `InkTone.record.color`, white mic, bottom-trailing overlay, identifier `library.record`) — action: select this journal as current and route to capture; wire via a new closure `var onRecord: () -> Void = {}` set in `ContentView` to `{ router.select(.capture) }` plus the journal-preselect call (find the API `JournalHeaderView`'s switcher uses on `CaptureScreenModel` and call the same; for All Entries scope the button records into the current journal unchanged).

- [ ] **Step 1:** Month-grouping helper test → red → implement → green.
- [ ] **Step 2:** Header band + row restyle + floating button.
- [ ] **Step 3:** Update library UI-test class flows (`library.entryLink` unchanged; new `library.record` smoke: tap → capture screen appears, assert `capture.record` exists). Run the class.
- [ ] **Step 4:** Commit.

```bash
git add -A
git commit -m "feat(library): cover band, designed rows, month groups, floating record (#18)"
```

### Task 12: Sidebar journal rows adopt the row anatomy; open PR 3

- [ ] **Step 1:** `SidebarView.swift`: journal rows get the same thumb treatment (cover, else neutral tile — small, 28-pt) and subtitle styling in `InkTone.inkSecondary.color`. Keep row order and identifiers.
- [ ] **Step 2:** Run `NavigationUITests`; commit; push; `gh pr create --title "UX redesign 3/4: journals — picker sheet, library, sidebar" --base feat/ux-entry-detail --body-file <tmpfile>` (body: "Fixes #18" intended). Do not merge.

---

## PR 4 — Calm capture landing (branch `feat/ux-capture-landing`, from `feat/ux-journals`)

**This PR touches the capture core's VIEW ONLY. `CaptureScreenModel`, phase dispatch, recovery, receipts: read, never restructure. Any change that seems to require model surgery → STOP and report to the coordinator.**

### Task 13: CaptureLayoutModel — idle "details" disclosure

**Files:**
- Modify: `Raconte/Capture/UI/CaptureLayoutModel.swift`
- Test: `RaconteTests/CaptureLayoutModelTests.swift` (extend)

**Interfaces:**
- Produces: a `detailsRevealed: Bool` input to the idle layout — when false (default), the idle setup region shows ONLY journal header + date; when true, it also shows `BackdateField`, `MultiVoiceField`, and the last-entry section. `RecoveryBanner`s and the error banner are NEVER gated by it (they force-show — extend the model's table so a pending recovery renders regardless of `detailsRevealed`). Capturing/receipt phases: unchanged.

- [ ] **Step 1:** Extend `CaptureLayoutModelTests` with the disclosure cases (revealed/hidden × recovery-present/absent) — red first. Follow the file's existing table-test style exactly.
- [ ] **Step 2:** Implement in the model; green; commit.

```bash
git add -A
git commit -m "feat(capture): layout model learns the idle details disclosure (#108)"
```

### Task 14: CaptureView idle restructure

**Files:**
- Modify: `Raconte/Capture/UI/CaptureView.swift`
- Test: `RaconteUITests/CaptureUITests.swift` (or the capture UI class present — grep; extend), `RaconteUITests/NavigationUITests.swift` must stay green (`testLaunchLandsDirectlyOnCaptureWithNoTaps` pins decision 1)

**Interfaces:**
- Consumes: Task 13's `detailsRevealed`.
- Produces: idle layout per Main.dc.html mock — centered journal name + chevron (existing `capture.journalPicker`), long date (`Date.now.formatted(date: .complete, time: .omitted)` minus year — use `.formatted(.dateTime.weekday(.wide).month(.wide).day())`), vertical space, the record button (existing `RecordButton`, 76 pt, now inside a 96-pt `Circle().strokeBorder(.white.opacity(0.22))` halo) with "tap to record" caption below (new `CaptureLabel` case `recordHint`, grey(0.78) — add it to the enum + both platform tables so the contrast/size tests cover it), the last-entry card (existing `lastEntrySection` restyled as one rounded `rgba(255,255,255,0.06)`-equivalent card — `Color.white.opacity(0.06)`), and a bottom "journal ⌃" disclosure control (identifier `capture.detailsToggle`) that flips `detailsRevealed` with animation. Build stamp: REMOVE from capture idle; verify `AboutView` already shows `BuildInfo.stamp` (Explore says About exists — check) and add it there if not. `MicMeter`/`statusRow`/`recordRow` marker buttons: idle shows the record button only (markers appear in capturing phase — this is already `CaptureLayoutModel`-driven; keep it so).

- [ ] **Step 1:** Restyle idle per above; keep every capturing/receipt phase branch byte-for-byte where possible.
- [ ] **Step 2:** UI tests: extend the capture class — idle shows `capture.record` and `capture.detailsToggle`, backdate field absent until toggle tapped, present after; recovery-banner force-show is unit-pinned (Task 13), not UI-pinned. Run `NavigationUITests` + the capture class + `EntryPagingUITests` (last-entry card push route).
- [ ] **Step 3:** Commit.

```bash
git add -A
git commit -m "feat(capture): calm idle landing — journal, date, record, details tucked away (#108)"
```

### Task 15: Recording re-skin + open PR 4

**Files:**
- Modify: `Raconte/Capture/UI/CaptureView.swift` (capturing phase), `Raconte/Capture/UI/RecStatusLine.swift` if needed
- Test: capture UI class

- [ ] **Step 1:** Capturing phase per Recording.dc.html: compact journal+date header (existing `JournalHeaderView` compact + `CompactBackdateSummary` stay), live transcript in serif (`.font(.system(.title3, design: .serif))` — 20 pt iOS; keep `CaptureLabel` coverage for operating labels; transcript body is explicitly out of the label model's scope), control bar order = status row (dot + timer + "Recording") → meter → marker/record/marker row (all existing components, spacing per `CaptureControlBarMetrics` — adjust constants there, with its tests, if the mock's spacing needs it).
- [ ] **Step 2:** Run the capture UI class + unit suite. A real recording smoke is OWNER-side; note it in the PR body as the smoke ask.
- [ ] **Step 3:** Commit; push; `gh pr create --title "UX redesign 4/4: calm capture landing" --base feat/ux-journals --body-file <tmpfile>` (body: "Fixes #108", smoke checklist for Nico: launch→1-tap record on device, disclosure, recovery banner still surfaces, TestFlight after merge). Do not merge.

---

## Self-review notes (already applied)

- Spec coverage: decision 1 → Tasks 13-15; decision 2 → Tasks 5-7; decision 3 → Tasks 1-2 (+ tokens threaded through every later task); decision 4 → Tasks 9-10; #103 → Task 4; #18 → Tasks 9-12; #107 affordance → Task 7 (with investigation gate); image-lifecycle rules → Tasks 9 (picker tile), 11 (band + row tiles), 7 (invitation).
- The spec's "Add Image" placement was silent — resolved here as an EntryInfoSheet row (Task 5); drag/drop + paste keep working on the screen itself.
- Deliberate deferral: the image-first RECORD button ships only if a record-into-entry path already exists (Task 7 gate); otherwise text-only invitation and the button goes to the #107 creation-flow pass.
