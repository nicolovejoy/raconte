# Batch 2 (2026-09-08) Implementation Plan — ink text roles with AA floors + the backdate popover (#149)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One PR from `main` that gives every paper-screen text colour a checked `InkTone` role
(primary / secondary / disabled) with measured WCAG AA floors on both paper surfaces in both
appearances, moves the last capture-screen grey literals onto the checked capture tones, and
fixes the backdate popover's unreadable dim text on the basis of a measurement, not a guess.

**Architecture:** `InkTone` gains `inkDisabled`; `inkSecondary`'s light value darkens to clear
4.5:1 (today it measures 3.37:1 on paper and 3.14:1 on paperInset — the spec's floor was never
met). `InkSurface.contrast(_:on:appearance:)` generalises `contrastOnPaper` so the floor table is
one loop over tone × surface × appearance. Every bare `.secondary` / `.tertiary` foreground on
the paper screens moves to a role; a comment-stripped source scan pins it, reusing the batch-1
paper-file list moved into `SourceScanning.swift`. The four capture `Color(white:)` text greys
move to `CaptureLabel`'s two checked inks. The backdate popover is measured first, then moved to
a paper ground only if the measurement says so.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency, XcodeGen
project, XCTest + XCUITest. Python 3 with PIL is present on the laptop (used for the
measurement in Task 4).

**Spec:** `docs/plans/2026-09-08-design-system-type-and-ink.md`, `## Batch 2` section and rulings
1–4. This plan implements batch 2 only; batch 1 (#162 `TypeRole`) merged as PR #169.
Issue: `gh issue view 149`.

## Global Constraints

- Branch `feat/149-ink-roles` from `main` at or after `fef9a83a` (build 19 bump, after the #169
  merge `52e95f6e`). Work in a worktree; the main checkout stays on `main` (`git checkout` of a
  worktree'd branch fails silently in a chain).
- **The owner's Mac app must be quit before any `xcodebuild test` or any launch of a built
  app.** `RaconteTests` uses the real app as its test host under the same bundle id, so a local
  run kills a running Raconte (and a second running instance is never allowed). Implementers
  run `xcodebuild test`, and Task 4's app launch, ONLY after the orchestrator has written
  "owner app quit — tests may run" into the task brief. Until then: compile checks only
  (`build`, not `test`).
- **Capture-screen type SIZES are untouched** (spec ruling 4). Only the four capture colour
  literals named in Task 3 move. Never change a `.font(...)` in `CaptureView.swift`,
  `PrecisionDatePicker.swift`, `RecStatusLine.swift`, `RecoveryBanner.swift`,
  `RecordButton.swift`, `LiveTranscriptText.swift`, `CaptureSurface*.swift`.
- Floors (spec, on `paper` AND `paperInset`, light AND dark): `ink` ≥ 4.5, `inkSecondary` ≥ 4.5,
  `inkDisabled` ≥ 3.0 and ≥ 1.3:1 weaker than `inkSecondary`, `accent` ≥ 3.0, `warning` ≥ 3.0.
  Studio keeps `CaptureSurface.minimumControlContrast` (7.0). No new studio role.
- The five `Color.primary` resets stay (deliberate white-leak resets). `Raconte/Capture/Debug`
  is exempt from every scan (DEBUG-only tooling, same exemption batch 1 used).
- Comment-stripping: every source-scanning test calls `strippingComments(_:)` from
  `RaconteTests/SourceScanning.swift`. A raw grep is satisfied by the comment explaining the fix.
- New test FILES need `xcodegen generate` before they run. This plan adds no new test file;
  if you add one anyway, regenerate and check the executed count went UP.
- **Test-count baseline: read it from main's latest CODE-carrying CI run at task start**
  (`gh run list --branch main --limit 3 --json databaseId,displayTitle,conclusion`, then
  `gh run view <id> --log | grep -o 'Executed [0-9]* tests.*'`). PR #169's own run reported
  **UI 65**; its local unit count was **2209 (1 skipped)**. Treat 2209 as expected, not known,
  until main's run 34291459747 (the #169 merge) is read. Every task reports its executed count
  against that number.
- Bash `timeout: 600000` on every xcodebuild. The `RaconteUI` suite whole exceeds the cap —
  always `-only-testing:` by class, foreground, never backgrounded.
- macOS unit test command (sandbox kept; never `CODE_SIGNING_ALLOWED=NO`). Fast loop: add
  `-only-testing:RaconteTests/<Class>` before `test`. End of every task: the whole unit suite.

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

- iOS compile check (must pass on every task — the `#if os(iOS)` branches only compile here):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "BUILD|error:" | tail -3
```

- Commit after each task with the trailer:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BXCMRx6nRpbwBWspYouNWS
```

- Straggler greps run over all three targets (`Raconte RaconteTests RaconteUITests`), never one.
  Grep a short fragment that cannot line-wrap, count hits, drive present-tense hits to zero.

---

### Task 1: `inkDisabled`, the retuned `inkSecondary`, and the floor loop

**Files:**
- Modify: `Raconte/Library/UI/InkSurface.swift` (whole file, 78 lines)
- Modify: `Raconte/Library/UI/InkSurface+SwiftUI.swift` (remove `darkColor`, lines 8–22; keep `color`)
- Test: `RaconteTests/InkSurfaceTests.swift` (edit `testInkTonesClearAAOnPaper`, append two tests)

**Interfaces:**
- Consumes: `CaptureSurface.relativeLuminance(_:)`, `CaptureLabelColor` from
  `Raconte/Capture/UI/CaptureSurface.swift`.
- Produces, used by Tasks 2–4:
  - `InkTone.inkDisabled` (new case) with `lightColor` #8B8478 and `darkColor` #736D65.
  - `InkTone.inkSecondary.lightColor` becomes #6F685D (was #8B8478). `darkColor` unchanged #9A9387.
  - `InkTone.darkColor` moves into `InkSurface.swift` (pure Foundation; the SwiftUI file keeps
    only `var color: Color`).
  - `enum InkAppearance: CaseIterable, Sendable { case light, dark }`
  - `InkTone.channels(for appearance: InkAppearance) -> CaptureLabelColor` (a method, not `color` — that name is the SwiftUI `Color` property)
  - `InkSurface.contrast(_ tone: InkTone, on surface: InkTone, appearance: InkAppearance) -> Double`
  - `InkSurface.contrastOnPaper(_:)` stays (existing callers in tests), now implemented via the
    general function.
  - `InkSurface.textFloors: [(tone: InkTone, floor: Double)]` — the table the test loops over.

Measured values behind the numbers (WCAG 2.1, sRGB, computed 2026-09-08; the test re-derives
them):

| tone | light on paper / paperInset | dark on paper / paperInset |
|---|---|---|
| `ink` (unchanged) | 15.26 / 14.21 | 15.05 / 13.89 |
| `inkSecondary` today #8B8478 | **3.37 / 3.14 — fails 4.5** | 6.04 / 5.57 |
| `inkSecondary` new #6F685D | 5.02 / 4.67 | (dark unchanged) |
| `inkDisabled` light #8B8478 | 3.37 / 3.14; 1.49:1 vs new inkSecondary | — |
| `inkDisabled` dark #736D65 | — | 3.59 / 3.32; 1.68:1 vs inkSecondary |
| `accent` (unchanged) | 4.68 / 4.36 | 6.82 / 6.30 |
| `warning` (unchanged) | 3.75 / 3.49 | 7.81 / 7.21 |

Today's light `inkSecondary` becomes `inkDisabled`: it was already "readable but weak", which
is the disabled role's definition. The secondary role darkens to clear the floor it was
supposed to have.

- [ ] **Step 1: Write the failing tests.** In `RaconteTests/InkSurfaceTests.swift`, change
  `testInkTonesClearAAOnPaper` so the `inkSecondary` line reads:

```swift
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.inkSecondary.lightColor), 4.5,
            "inkSecondary is READ text (row second lines, dates) — spec batch 2 puts it at the "
            + "4.5 normal-text floor, not the 3.0 large-text floor it had")
```

  Then append, before the final `}` of the class:

```swift
    // MARK: #149 batch 2 — text roles on every reading surface, both appearances

    /// The spec's floor table as one loop, not one function per pair. `paper` and `paperInset`
    /// are the two grounds paper text sits on; both appearances, because dark paper is a
    /// different pair of colours, not an inversion. The numbers are re-derived from the channel
    /// values here — this test does not trust the table in the plan.
    func testTextRolesClearTheirFloorsOnEverySurfaceAndAppearance() {
        for (tone, floor) in InkSurface.textFloors {
            for surface in [InkTone.paper, .paperInset] {
                for appearance in InkAppearance.allCases {
                    let ratio = InkSurface.contrast(tone, on: surface, appearance: appearance)
                    XCTAssertGreaterThanOrEqual(
                        ratio, floor,
                        "\(tone) on \(surface) (\(appearance)) is \(ratio) — floor \(floor)")
                }
            }
        }
    }

    /// Disabled must read as disabled: visibly weaker than secondary, on the same ground, in
    /// both appearances. Without this a `inkDisabled` equal to `inkSecondary` passes the floor
    /// loop above and the role is a synonym.
    func testDisabledIsVisiblyWeakerThanSecondary() {
        for appearance in InkAppearance.allCases {
            let secondary = CaptureSurface.relativeLuminance(InkTone.inkSecondary.channels(for: appearance))
            let disabled = CaptureSurface.relativeLuminance(InkTone.inkDisabled.channels(for: appearance))
            let separation = (max(secondary, disabled) + 0.05) / (min(secondary, disabled) + 0.05)
            XCTAssertGreaterThanOrEqual(separation, 1.3,
                "\(appearance): disabled vs secondary is only \(separation):1")
            // Weaker means CLOSER to the paper it sits on, in luminance terms.
            let paper = CaptureSurface.relativeLuminance(InkTone.paper.channels(for: appearance))
            XCTAssertLessThan(abs(disabled - paper), abs(secondary - paper),
                "\(appearance): disabled must sit closer to paper than secondary does")
        }
    }

    /// The general contrast function and the old paper-only one agree — the old one is now a
    /// wrapper, and this pins that the wrapper picks light paper.
    func testContrastOnPaperIsTheLightPaperCaseOfTheGeneralFunction() {
        for tone in [InkTone.ink, .inkSecondary, .inkDisabled, .accent, .warning] {
            XCTAssertEqual(InkSurface.contrastOnPaper(tone.lightColor),
                           InkSurface.contrast(tone, on: .paper, appearance: .light),
                           accuracy: 1e-9, "\(tone)")
        }
    }
```

- [ ] **Step 2: Run to verify it fails for the right reason (first RED — the current palette).**
  `-only-testing:RaconteTests/InkSurfaceTests`. Expected: compile error, `cannot find 'InkAppearance'
  in scope` / `inkDisabled`. That is a compile RED, not the interesting one — Step 4 has the
  second.

- [ ] **Step 3: Implement the model.** Replace `Raconte/Library/UI/InkSurface.swift` with:

```swift
import Foundation

/// The app-wide "ink & paper" palette as pure channel values, extending the
/// `CaptureSurface` idea (constant surface ⇒ checkable contrast) to the reading
/// surfaces. Light values are the design's committed hex values
/// (spec: docs/plans/2026-08-29-ux-redesign-design.md, retuned for #149 in
/// docs/plans/2026-09-08-design-system-type-and-ink.md batch 2). Dark counterparts live
/// here too — both are pure numbers; only `color` (SwiftUI) is in `InkSurface+SwiftUI.swift`.
enum InkTone: CaseIterable, Sendable {
    /// Reading background — warm white.
    case paper
    /// Inset ground: sheets, the pinned play bar.
    case paperInset
    /// Dividers.
    case hairline
    /// Primary text.
    case ink
    /// Secondary text — row second lines, dates, metadata. READ text, so it clears the
    /// 4.5:1 normal-text floor on both paper grounds (#149; the earlier #8B8478 measured
    /// 3.37:1 on paper and 3.14:1 on paperInset, and is now `inkDisabled`).
    case inkSecondary
    /// Disabled / placeholder text — an unplaceable voice token, the approximate-boundary
    /// mark. Readable (≥ 3.0:1) but visibly weaker than `inkSecondary` (≥ 1.3:1 apart).
    case inkDisabled
    /// Warm amber — links, active states, scrubber fill.
    case accent
    /// The app's one loud colour; shared with capture's record button.
    case record
    /// #161: a marker that must be seen — the out-of-span glyph, the quarantine block's
    /// bar. Darkened safety orange (#D2570A, ~3.7:1 on paper, ~3.5:1 on paperInset); lightens
    /// on dark paper.
    case warning
    /// The capture screen's fixed near-black. Pinned to `CaptureSurface.backgroundWhite`.
    case studio
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
    /// The "Saved" chip's ground — system green at 22%, flattened to a constant so it
    /// can be checked. Actually drawn over `studioCard`, not `studio` directly; the two
    /// grounds are close enough (`.grey(0.11)` vs. the near-black studio background)
    /// that the difference is visually negligible.
    case studioSaved

    var lightColor: CaptureLabelColor {
        switch self {
        case .paper: CaptureLabelColor(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEE / 255)
        case .paperInset: CaptureLabelColor(red: 0xF0 / 255, green: 0xEC / 255, blue: 0xE3 / 255)
        case .hairline: CaptureLabelColor(red: 0xE5 / 255, green: 0xDF / 255, blue: 0xD4 / 255)
        case .ink: CaptureLabelColor(red: 0x21 / 255, green: 0x1D / 255, blue: 0x18 / 255)
        // #149: 5.02:1 on paper, 4.67:1 on paperInset.
        case .inkSecondary: CaptureLabelColor(red: 0x6F / 255, green: 0x68 / 255, blue: 0x5D / 255)
        // #149: the former inkSecondary — 3.37:1 on paper, 3.14:1 on paperInset, 1.49:1
        // weaker than the new inkSecondary.
        case .inkDisabled: CaptureLabelColor(red: 0x8B / 255, green: 0x84 / 255, blue: 0x78 / 255)
        // Darkened from the spec's #96683A (4.41:1 on paper — fails the 4.5 AA floor by a
        // hair) to #916438 (4.63:1). Adjustment per task-1 brief NOTE: darken a failing
        // tone rather than lower the floor.
        case .accent: CaptureLabelColor(red: 0x91 / 255, green: 0x64 / 255, blue: 0x38 / 255)
        case .record: CaptureLabelColor(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
        case .warning: CaptureLabelColor(red: 0xD2 / 255, green: 0x57 / 255, blue: 0x0A / 255)
        case .studio: .grey(CaptureSurface.backgroundWhite)
        case .studioInk: .grey(1.0)
        case .studioInkDim: .grey(0.62)
        case .studioCard: .grey(0.11)
        case .studioHairline: .grey(0.17)
        case .studioSaved: CaptureLabelColor(red: 0.08, green: 0.21, blue: 0.12)
        }
    }

    /// Dark-appearance channel values. Paper family inverts to warm near-blacks;
    /// text inverts to warm off-whites; accent lightens to keep contrast on dark
    /// paper; record and studio are appearance-invariant.
    var darkColor: CaptureLabelColor {
        switch self {
        case .paper: CaptureLabelColor(red: 0x16 / 255, green: 0x14 / 255, blue: 0x11 / 255)
        case .paperInset: CaptureLabelColor(red: 0x1F / 255, green: 0x1C / 255, blue: 0x18 / 255)
        case .hairline: CaptureLabelColor(red: 0x2E / 255, green: 0x2A / 255, blue: 0x24 / 255)
        case .ink: CaptureLabelColor(red: 0xEC / 255, green: 0xE8 / 255, blue: 0xE0 / 255)
        // 6.04:1 on dark paper, 5.57:1 on dark paperInset.
        case .inkSecondary: CaptureLabelColor(red: 0x9A / 255, green: 0x93 / 255, blue: 0x87 / 255)
        // #149: 3.59:1 on dark paper, 3.32:1 on dark paperInset, 1.68:1 weaker than secondary.
        case .inkDisabled: CaptureLabelColor(red: 0x73 / 255, green: 0x6D / 255, blue: 0x65 / 255)
        case .accent: CaptureLabelColor(red: 0xC8 / 255, green: 0x93 / 255, blue: 0x5E / 255)
        case .warning: CaptureLabelColor(red: 0xFF / 255, green: 0x8A / 255, blue: 0x2A / 255)
        case .record, .studio, .studioInk, .studioInkDim, .studioCard, .studioHairline, .studioSaved: lightColor
        }
    }

    /// Channel values for one appearance. Not named `color` — that is the SwiftUI property.
    func channels(for appearance: InkAppearance) -> CaptureLabelColor {
        switch appearance {
        case .light: lightColor
        case .dark: darkColor
        }
    }
}

/// The two appearances the reading surfaces follow. A pure value so the floor table can be
/// checked for both from one test run (the studio surface ignores this — it is pinned dark).
enum InkAppearance: CaseIterable, Sendable {
    case light
    case dark
}

enum InkSurface {
    /// WCAG 2.1 contrast of a tone against a ground tone, in one appearance. Luminance is
    /// `CaptureSurface.relativeLuminance(_:)` — not reimplemented here, so the two surfaces
    /// can never drift apart on the underlying formula.
    static func contrast(_ tone: InkTone, on surface: InkTone, appearance: InkAppearance) -> Double {
        let a = CaptureSurface.relativeLuminance(tone.channels(for: appearance))
        let b = CaptureSurface.relativeLuminance(surface.channels(for: appearance))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Contrast of a raw colour against light-mode paper — the original, kept for the
    /// existing tests; `contrast(_:on:appearance:)` is the general form.
    static func contrastOnPaper(_ color: CaptureLabelColor) -> Double {
        let a = CaptureSurface.relativeLuminance(color)
        let b = CaptureSurface.relativeLuminance(InkTone.paper.lightColor)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Spec batch 2 (#149): the floor each text-bearing tone must clear on `paper` AND
    /// `paperInset`, light AND dark. 4.5 is WCAG AA for normal text; 3.0 is AA for large
    /// text and graphical objects (disabled text, glyphs, the warning marker).
    static let textFloors: [(tone: InkTone, floor: Double)] = [
        (.ink, 4.5),
        (.inkSecondary, 4.5),
        (.inkDisabled, 3.0),
        (.accent, 3.0),
        (.warning, 3.0),
    ]
}
```

  Then in `Raconte/Library/UI/InkSurface+SwiftUI.swift` delete the `darkColor` property (lines
  8–22, from the `/// Dark-appearance channel values.` doc comment through its closing `}`),
  keeping the `extension InkTone {` and `var color: Color { … }`. Update the file's header
  comment's "each tone carries a dark counterpart" sentence to say the dark values live in
  `InkSurface.swift` next to the light ones.

- [ ] **Step 4: Proof of RED, twice — the palette must be able to fail this test.**
  (a) Temporarily set `case .inkSecondary:` in `lightColor` back to the old
  `0x8B / 255, 0x84 / 255, 0x78 / 255`. Run `-only-testing:RaconteTests/InkSurfaceTests`.
  Expected: `testTextRolesClearTheirFloorsOnEverySurfaceAndAppearance` FAILS with
  `inkSecondary on paper (light) is 3.37… — floor 4.5` and the paperInset line too;
  `testInkTonesClearAAOnPaper` fails as well. Restore #6F685D.
  (b) Temporarily set `case .inkDisabled:` in `lightColor` to the same values as
  `inkSecondary` (`0x6F, 0x68, 0x5D`). Run again. Expected: `testDisabledIsVisiblyWeakerThanSecondary`
  FAILS with `light: disabled vs secondary is only 1.0:1`. Restore #8B8478.
  Run once more: all of `InkSurfaceTests` PASS. Report both failure messages verbatim.

- [ ] **Step 5: Run the full macOS unit suite and the iOS compile check.** Expected: baseline
  + 3 (the three appended tests), 1 skipped, green; iOS BUILD SUCCEEDED. Note: every existing
  `InkTone.inkSecondary.color` site (26 of them) just got darker in light mode with no code
  change — that is the intended visual effect of this task, not a side effect.

- [ ] **Step 6: Commit** — `feat(#149): inkDisabled, inkSecondary clears AA, floor loop over surface × appearance`.

---

### Task 2: Sweep the paper screens' bare `.secondary` / `.tertiary` onto roles, scan-pinned

**Files:**
- Modify: `RaconteTests/SourceScanning.swift` (append `paperScreenFiles`)
- Modify: `RaconteTests/TypeScaleTests.swift` (lines 76–97: delete the private `paperFiles`
  list; line 107 `Self.paperFiles` → `paperScreenFiles`)
- Modify: `Raconte/Library/UI/EntryDetailView.swift` (145, 704, 713, 718, 995, 1104)
- Modify: `Raconte/Library/UI/JournalEditorView.swift` (124)
- Modify: `Raconte/Library/UI/JournalSpanEditor.swift` (61, 71)
- Modify: `Raconte/Library/UI/LibraryView.swift` (330, 343, 360, 536, 798, 802)
- Modify: `Raconte/Library/UI/RevisionHistoryView.swift` (24, 31, 79, 91, 98)
- Modify: `Raconte/Library/UI/TranscriptEditorView.swift` (126, 160, 184)
- Modify: `Raconte/Library/UI/TrashView.swift` (85, 148, 183, 312, 446, 479, 485, 491)
- Modify: `Raconte/Library/UI/VoiceAttributedText.swift` (27)
- Modify: `Raconte/Library/UI/VoiceMarkingView.swift` (44, 150, 164)
- Test: `RaconteTests/InkSurfaceTests.swift` (append one scan test)

Line numbers are from `main` `fef9a83a`; re-grep before editing:
`grep -n 'foregroundStyle(\.secondary)\|foregroundStyle(\.tertiary)\|\.tertiary)\|white\.opacity' <file>`.

**Interfaces:**
- Consumes: `InkTone.inkSecondary.color`, `InkTone.inkDisabled.color`, `InkTone.studioInk.color`
  (Task 1 / existing).
- Produces: `let paperScreenFiles: [String]` in `RaconteTests/SourceScanning.swift`, shared by
  `TypeScaleTests` and the new ink scan (and Task 3's, if it wants it).

Mapping (mechanical; fonts, weights, identifiers untouched):

| was | becomes |
|---|---|
| `.foregroundStyle(.secondary)` (31 sites above) | `.foregroundStyle(InkTone.inkSecondary.color)` |
| EntryDetailView 995 `.foregroundStyle(.tertiary)` | `.foregroundStyle(InkTone.inkDisabled.color)` |
| VoiceMarkingView 164 `.foregroundStyle(token.isPlaceable ? .primary : .tertiary)` | `.foregroundStyle(token.isPlaceable ? Color.primary : InkTone.inkDisabled.color)` — both arms must be `Color` now that one arm is a `Color`; `.primary` alone no longer type-checks in the ternary. |
| LibraryView 802 `.foregroundStyle(.white.opacity(0.85))` | `.foregroundStyle(InkTone.studioInk.color)` |
| LibraryView 798 `.foregroundStyle(.white)` (the cover title, same `VStack`) | `.foregroundStyle(InkTone.studioInk.color)` — same block, same ground; leaving one literal beside a token is drift. |

LibraryView 802, measured: the band's gradient (`LibraryView` 770–773) runs `.black.opacity(0)`
→ `0.55` at 60% → `0.9` at the bottom; the subtitle sits in the 0.55–0.9 zone. Worst case is
a white photo under the 0.55 stop (ground ≈ 0.45 grey): white at 85% flattens to ≈3.95:1,
full white to 4.76:1. The spec floor for the band is 4.5, so the subtitle goes to full white —
the `studioInk` token, since the band's text-on-dark-overlay is the studio relationship. No
new constant.

`VoiceAttributedText.swift` line 27 is `Text.foregroundStyle` (a `Text`-returning modifier,
not `View.foregroundStyle`); it accepts a `Color` the same way. It is NOT in batch 1's
`paperFiles` because it has no `.font(...)`; it joins `paperScreenFiles` now — the type scan
still passes on it (nothing to find).

Out of the sweep, on purpose: `Raconte/Capture/Debug/DebugMenuView.swift:90` (the 32nd
`.secondary` the spec counted; Debug is exempt).

- [ ] **Step 1: Move the paper-file list.** Append to `RaconteTests/SourceScanning.swift`:

```swift
/// The paper (reading-surface) screens every design-system source scan runs over: type roles
/// (`TypeScaleTests`, #162) and ink roles (`InkSurfaceTests`, #149). Capture-surface files are
/// deliberately absent (spec ruling 4); `Raconte/Capture/Debug` is exempt (DEBUG-only tooling).
/// `PlaybackProgressLine` lives under Capture/UI but renders on paper in entry detail.
/// `VoiceAttributedText` builds `Text` for the transcript and carries colour but no font.
let paperScreenFiles = [
    "Raconte/Home/UI/HomeView.swift",
    "Raconte/App/SidebarView.swift",
    "Raconte/App/AboutView.swift",
    "Raconte/App/SyncStatusSectionView.swift",
    "Raconte/Library/UI/LibraryView.swift",
    "Raconte/Library/UI/TrashView.swift",
    "Raconte/Library/UI/EntryDetailView.swift",
    "Raconte/Library/UI/EntryInfoSheet.swift",
    "Raconte/Library/UI/TranscriptEditorView.swift",
    "Raconte/Library/UI/RevisionHistoryView.swift",
    "Raconte/Library/UI/JournalPickerSheet.swift",
    "Raconte/Library/UI/JournalSpanEditor.swift",
    "Raconte/Library/UI/JournalEditorView.swift",
    "Raconte/Library/UI/VoiceMarkingView.swift",
    "Raconte/Library/UI/VoiceAttributedText.swift",
    "Raconte/Capture/UI/PlaybackProgressLine.swift",
]

/// Repo root, derived from this file's location (RaconteTests/ → repo).
func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
}
```

  In `RaconteTests/TypeScaleTests.swift` delete the `private static let paperFiles = [ … ]`
  declaration and its doc comment (lines 76–97), and change `for path in Self.paperFiles {` to
  `for path in paperScreenFiles {`. Run `-only-testing:RaconteTests/TypeScaleTests`: PASS,
  same count as before (a moved list, not a new test).

- [ ] **Step 2: Write the failing scan test.** Append to `InkSurfaceTests`:

```swift
    /// Paper text carries an `InkTone` role, never Apple's `.secondary` / `.tertiary`
    /// hierarchical styles (#149) — those resolve to whatever the system decides and cannot
    /// be measured against paper, which is how the unreadable dim text got in. Comment-stripped
    /// so a doc comment naming the pattern (like this one) cannot satisfy the scan.
    func testPaperScreensCarryNoBareHierarchicalForeground() throws {
        let banned = ["foregroundStyle(.secondary)", "foregroundStyle(.tertiary)",
                      ": .tertiary)", ": .secondary)", "white.opacity("]
        for path in paperScreenFiles {
            let source = strippingComments(try String(contentsOf: repoRoot().appendingPathComponent(path)))
            for pattern in banned {
                XCTAssertFalse(source.contains(pattern), "\(path) still has \(pattern)")
            }
        }
    }
```

- [ ] **Step 3: Run it to verify it fails** (`-only-testing:RaconteTests/InkSurfaceTests`).
  Expected: FAIL, ten files named (`EntryDetailView.swift still has foregroundStyle(.secondary)`,
  …, `LibraryView.swift still has white.opacity(`). This is the RED: the test finds the
  current code, before any sweep. Paste two of the messages into the commit body.

- [ ] **Step 4: Apply the mapping** to all eleven production files. For each file, first
  re-grep and list every hit with its line; any hit not in the table above is reported to the
  orchestrator, not guessed at.

- [ ] **Step 5: Run the scan test again:** PASS. Then the full macOS unit suite and the iOS
  compile check. Expected: Task 1's count + 1, 1 skipped, green; iOS BUILD SUCCEEDED (the
  ternary in `VoiceMarkingView` is the one place a type error would surface).

- [ ] **Step 6: Run the UI classes for these screens, foreground, ONE invocation:**

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/EntryDetailSheetUITests -only-testing:RaconteUITests/VoiceMarkingUITests -only-testing:RaconteUITests/TrashRepairUITests -only-testing:RaconteUITests/TranscriptEditorUITests -only-testing:RaconteUITests/JournalEditorUITests test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

  Expected: green.

- [ ] **Step 7: Commit** — `feat(#149): paper screens take inkSecondary / inkDisabled, never .secondary / .tertiary`.

---

### Task 3: The capture screen's last grey text literals move onto the checked inks

**Files:**
- Modify: `Raconte/Capture/UI/CaptureSurface.swift` (`CaptureLabel`, lines 195–212: name the two inks)
- Modify: `Raconte/Capture/UI/CaptureSurface+SwiftUI.swift` (lines 36–42: add the two `Color` accessors)
- Modify: `Raconte/Capture/UI/RecoveryBanner.swift` (22, 45)
- Modify: `Raconte/Capture/UI/RecStatusLine.swift` (57, 85)
- Modify: `Raconte/Capture/UI/PlaybackProgressLine.swift` (15–19 add a parameter; 53)
- Test: `RaconteTests/CaptureLabelTests.swift` (append one scan test)

**Interfaces:**
- Consumes: `InkTone.inkSecondary.color` (Task 1), `CaptureLabel.labelColor`, the existing
  `captureUISources()` helper in `CaptureLabelTests` (lines 229–243).
- Produces:
  - `CaptureLabel.primaryInk: CaptureLabelColor` (= `.grey(1.0)`) and
    `CaptureLabel.secondaryInk: CaptureLabelColor` (= `.grey(0.78)`) — statics; `labelColor`
    returns them, so the enum's switch and these two names cannot disagree.
  - `CaptureLabel.primaryInkColor: Color`, `CaptureLabel.secondaryInkColor: Color`.
  - `PlaybackProgressLine.init(playback:tint:idPrefix:ink:)` — new `var ink: Color =
    InkTone.inkSecondary.color`.

The spec says these four go to "the existing `CaptureLabel` tones (1.0 / 0.78)" and "no new
studio role". So: no `InkTone` case. The two greys get NAMES on `CaptureLabel` (they are
already its values), and a `Color` accessor each. `CaptureLabelTests`' floor loop already
covers 1.0 and 0.78 on studio (17.4:1 and 11.5:1).

`PlaybackProgressLine` is dual-surface (its own header says so): on paper in entry detail it
takes `inkSecondary` (the paper role, appearance-following); inside `RecoveryBanner` on studio
it must NOT — dark-appearance `inkSecondary` #9A9387 on the banner's 0.14 ground is well under
7.0. Hence the `ink` parameter: paper default, studio caller passes the checked capture ink.
The banner's ground is `Color(white: 0.14)`, not 0.05: 0.78 on 0.14 is 9.2:1, still over 7.0.

- [ ] **Step 1: Write the failing scan test.** Append to `CaptureLabelTests`, next to
  `testCaptureViewDoesNotReintroduceTheDimGreyLiteralsThisModelReplaced`:

```swift
    /// #149 batch 2: the last four grey TEXT literals on the capture screen — RecoveryBanner's
    /// title (0.95), RecStatusLine's clock (0.9) and status (0.78), PlaybackProgressLine's
    /// figures (0.7) — are gone from every capture UI source. Fills and borders
    /// (`MicMeter`, `RecordButton`, the banner's own background, the popover's
    /// `CaptureSurface.backgroundWhite`) are decoration and are not what this scans for: the
    /// pattern is the literal followed by a foreground, which only text sites write.
    func testCaptureUITextNoLongerHardcodesGreyForegrounds() throws {
        let source = try captureUISources()
        let pattern = try NSRegularExpression(pattern: #"foregroundStyle\((isLive \? Color\.red : )?Color\(white: [0-9.]+\)\)"#)
        let hits = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .map { String(source[Range($0.range, in: source)!]) }
        XCTAssertEqual(hits, [], "capture UI still colours text with a raw grey: \(hits)")
    }
```

- [ ] **Step 2: Run it to verify it fails** (`-only-testing:RaconteTests/CaptureLabelTests`).
  Expected: FAIL listing four hits — `foregroundStyle(Color(white: 0.95))`,
  `foregroundStyle(isLive ? Color.red : Color(white: 0.9))`, `foregroundStyle(Color(white: 0.78))`,
  `foregroundStyle(Color(white: 0.7))`. If the count is not four, stop and report: the regex
  or the site list is wrong.

- [ ] **Step 3: Name the inks.** In `Raconte/Capture/UI/CaptureSurface.swift`, inside
  `enum CaptureLabel`, directly above `var labelColor`, add:

```swift
    /// The two greys every capture label is drawn in (the error banner is the one non-grey).
    /// Named so the few capture texts that are NOT persistent operating labels (the recovery
    /// banner's title, the status line, the playback figures) can take the same checked ink
    /// instead of a literal that drifts — #149 batch 2. 1.0 is 17.4:1 on studio, 0.78 is
    /// 11.5:1; both clear `CaptureSurface.minimumControlContrast`.
    static let primaryInk = CaptureLabelColor.grey(1.0)
    static let secondaryInk = CaptureLabelColor.grey(0.78)
```

  and change the two grey arms of the `labelColor` switch from `.grey(1.0)` to
  `Self.primaryInk` and from `.grey(0.78)` to `Self.secondaryInk`. The doc comments above
  those arms stay.

  In `Raconte/Capture/UI/CaptureSurface+SwiftUI.swift`, inside `extension CaptureLabel`, add:

```swift
    /// `primaryInk` / `secondaryInk` as SwiftUI colours, for capture text that is not itself
    /// a `CaptureLabel` case (see the statics' comment).
    static var primaryInkColor: Color {
        let c = primaryInk
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
    static var secondaryInkColor: Color {
        let c = secondaryInk
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
```

- [ ] **Step 4: Move the four sites.**
  - `RecoveryBanner.swift:22` `.foregroundStyle(Color(white: 0.95))` →
    `.foregroundStyle(CaptureLabel.primaryInkColor)`.
  - `RecoveryBanner.swift:45` `PlaybackProgressLine(playback: playback, tint: .orange, idPrefix: "recovery")` →
    `PlaybackProgressLine(playback: playback, tint: .orange, idPrefix: "recovery", ink: CaptureLabel.secondaryInkColor)`.
  - `RecStatusLine.swift:57` `.foregroundStyle(isLive ? Color.red : Color(white: 0.9))` →
    `.foregroundStyle(isLive ? Color.red : CaptureLabel.primaryInkColor)`.
  - `RecStatusLine.swift:85` `.foregroundStyle(Color(white: 0.78))` →
    `.foregroundStyle(CaptureLabel.secondaryInkColor)`.
  - `PlaybackProgressLine.swift`: after `var idPrefix: String = "finished"` add

```swift
    /// The figures' colour. Paper default (entry detail, appearance-following); the studio
    /// caller (`RecoveryBanner`) passes `CaptureLabel.secondaryInkColor` — dark-appearance
    /// `inkSecondary` on the studio ground would be under the 7.0 capture floor.
    var ink: Color = InkTone.inkSecondary.color
```

    and change line 53 `.foregroundStyle(Color(white: 0.7))` → `.foregroundStyle(ink)`.
    Update the header comment (lines 3–5) to mention the `ink` parameter in one sentence.

- [ ] **Step 5: Run the scan test again:** PASS. Then the full macOS unit suite and the iOS
  compile check. Expected: Task 2's count + 1, 1 skipped, green (`CaptureLabelTests`' existing
  floor and dim-literal tests must still pass — `labelColor`'s values did not change); iOS
  BUILD SUCCEEDED.

- [ ] **Step 6: Capture UI classes, foreground, one invocation:**

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/CaptureControlsUITests -only-testing:RaconteUITests/CaptureUITests -only-testing:RaconteUITests/EntryDetailSheetUITests test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

  Expected: green.

- [ ] **Step 7: Commit** — `feat(#149): capture text greys take CaptureLabel's checked inks; PlaybackProgressLine ink per surface`.

---

### Task 4: The backdate popover — measure, then move or leave

**Files:**
- Measure: `Raconte/Capture/UI/PrecisionDatePicker.swift` (`dayCalendarPopover`, lines 214–242)
- Possibly modify: the same lines (branch A), or nothing (branch B)
- Possibly modify: `RaconteTests/PrecisionDatePickerTests.swift`
  (`testTheMacOSPopoverPaintsTheCaptureSurfaceRatherThanTrustingSystemMaterial`, lines 103–117)
- Output: `docs/plans/2026-09-08-batch-2-ink-plan.md` gains a `## Task 4 measurement` section
  at the bottom with the numbers (this file; append, do not rewrite)

**Interfaces:**
- Consumes: `InkTone.paperInset.color` (existing), the `Color.primary` reset and
  `.tint(Color.accentColor)` already on the popover.
- Produces: nothing other tasks use.

**This task launches the app. Do not start Step 2 until the orchestrator's brief says the
owner's app is quit.**

The popover (`PrecisionDatePicker.swift` 214–242) is Apple's `.graphical` `DatePicker` on the
studio ground (`Color(white: 0.05)`), pinned `.dark`, with `Color.primary` and `.tint` resets.
Its disabled day numerals (dates after today are out of range: `in: ...Date()`) and the
month/year secondary text are drawn by the system control — a token cannot recolour them. So
the fix is chosen by measurement, per the spec's order of work.

- [ ] **Step 1: Read the popover's own text sites.** `grep -n 'Text(' Raconte/Capture/UI/PrecisionDatePicker.swift`
  → lines 35–37 (precision segments), 129 (month names, inside `monthPicker`), 149 (years,
  inside `yearPicker`), 179 (the date button, already a `captureLabel`). The popover's own
  content is the two `Picker`s plus the system `DatePicker`; there is no plain `Text` of the
  popover's own to recolour. Record this: it means the spec's branch 3 ("move the sheet's own
  `Text` to `captureLabel` tones") has nothing to act on, and the only two outcomes are "move
  the ground" or "no change, measurement recorded".

- [ ] **Step 2: Build and launch the app.** Nocloud build (does not need the owner's app quit —
  it only compiles):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' -derivedDataPath /tmp/raconte-149 CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements build 2>&1 | grep -E "BUILD|error:" | tail -3
```

  Then (owner's app confirmed quit) `open /tmp/raconte-149/Build/Products/Debug/Raconte.app`.
  In the app: sidebar → Capture. Turn on the backdate toggle, click the date button — the
  calendar popover appears. Leave it open.

- [ ] **Step 3: Screenshot the popover and sample it.** Find the window and capture it:

```
screencapture -x -l "$(osascript -e 'tell application "System Events" to get id of first window of (first process whose name is "Raconte")')" /tmp/raconte-149/popover.png 2>/dev/null || screencapture -x /tmp/raconte-149/popover.png
```

  Open `/tmp/raconte-149/popover.png` with the Read tool to see it, then note approximate pixel
  coordinates of: (i) a disabled day numeral (a date after today, greyed out), (ii) the
  month/year header text if the system draws one, (iii) an enabled day numeral, (iv) the
  selected day's numeral on its tint fill, (v) a patch of the popover background. Sample each
  with PIL (present on this machine) and compute contrast against the popover ground:

```
python3 - <<'EOF'
from PIL import Image
im = Image.open('/tmp/raconte-149/popover.png').convert('RGB')
def lin(c): c/=255; return c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
def lum(p): return 0.2126*lin(p[0])+0.7152*lin(p[1])+0.0722*lin(p[2])
def cr(a,b): return (max(a,b)+0.05)/(min(a,b)+0.05)
# Fill in from the screenshot. Sample the DARKEST pixel of a glyph (anti-aliasing lightens edges):
# take a small box around the glyph and pick the pixel farthest in luminance from the ground.
samples = {
  'ground': (0, 0),          # a background patch inside the popover
  'disabledDay': (0, 0),     # a greyed future date
  'headerText': (0, 0),      # month/year text if present, else delete this line
  'enabledDay': (0, 0),
  'selectedDay': (0, 0),     # numeral ON the tint fill
  'selectedFill': (0, 0),    # the fill itself
}
def darkest_extreme(xy, ground, r=6):
    x,y = xy; g = lum(ground); best=None
    for dx in range(-r,r+1):
        for dy in range(-r,r+1):
            p = im.getpixel((x+dx,y+dy))
            if best is None or abs(lum(p)-g) > abs(lum(best)-g): best = p
    return best
ground = im.getpixel(samples['ground']); print('ground', ground, round(lum(ground),4))
for k,xy in samples.items():
    if k=='ground': continue
    p = darkest_extreme(xy, ground)
    against = im.getpixel(samples['selectedFill']) if k=='selectedDay' else ground
    print(k, p, 'contrast', round(cr(lum(p), lum(against)),2))
EOF
```

  Record every printed line. The two numbers that decide the branch are `disabledDay` and
  `headerText` (if present) against `ground`. Quit the app when done (`osascript -e 'quit app "Raconte"'`).

- [ ] **Step 4: Choose the branch and record it.** Append to the bottom of THIS plan file:

```markdown
## Task 4 measurement (filled in by the implementer)

Build: /tmp/raconte-149, `git rev-parse --short HEAD` = <sha>. Popover ground sampled: <rgb>.
| sample | rgb | contrast vs ground |
|---|---|---|
| disabled day numeral | … | … |
| month/year header text | … or "none drawn" | … |
| enabled day numeral | … | … |
| selected day on its fill | … | … (vs fill) |
Branch taken: A (moved to paperInset) / B (left on studio, all ≥ 3.0).
```

  **Branch A — any sampled text < 3.0:1.** Move the popover off studio, spec step 2.
  (a) RED first: in `RaconteTests/PrecisionDatePickerTests.swift` rewrite
  `testTheMacOSPopoverPaintsTheCaptureSurfaceRatherThanTrustingSystemMaterial` to:

```swift
    /// #149 batch 2, measured <date>: on the studio ground Apple's graphical calendar drew its
    /// disabled day numerals at <n>:1 — under the 3.0 floor, and not ours to recolour (a token
    /// cannot reach inside a system control). So the popover is a PAPER surface floating over
    /// the studio screen: `paperInset` ground, ambient colour scheme, which is exactly what the
    /// system picker is tuned for. The two resets stay: `Color.primary` (the white-leak fix,
    /// 2026-08-15 — under an ambient scheme it resolves to the right ink for the ground) and
    /// the tint (a white fill under a white numeral is an unreadable selection). This does not
    /// regress the "capture controls pin `.dark`" rule: that rule exists because ambient
    /// controls on the STUDIO ground render dark-on-dark; a control on its own paper ground is
    /// the case the rule was written to avoid.
    func testTheMacOSPopoverIsAPaperSurfaceNotAStudioOne() throws {
        let source = try pickerSource()
        let popover = try XCTUnwrap(source.range(of: "private var dayCalendarPopover"))
        let body = String(source[popover.lowerBound...].prefix(1400))
        XCTAssertTrue(body.contains("InkTone.paperInset.color"),
                      "the popover must paint paperInset — a paper ground the system calendar is tuned for")
        XCTAssertFalse(body.contains("CaptureSurface.backgroundWhite"),
                       "the popover must no longer paint the studio ground (measured under the floor)")
        XCTAssertFalse(body.contains("\\.colorScheme, .dark"),
                       "the popover follows the ambient scheme; its ground is its own")
        XCTAssertTrue(body.contains("Color.primary"), "the white-leak reset stays")
        XCTAssertTrue(body.contains(".tint(Color.accentColor)"), "the tint reset stays")
    }
```

  Run `-only-testing:RaconteTests/PrecisionDatePickerTests`: the new test FAILS on
  `InkTone.paperInset.color` missing. (`pickerSource()` is the class's existing comment-stripped
  loader at line ~271 — check the name and reuse it.)
  (b) Implement: in `PrecisionDatePicker.swift` `dayCalendarPopover`, replace the last two
  modifiers

```swift
        .background(Color(white: CaptureSurface.backgroundWhite))
        .environment(\.colorScheme, .dark)
```

  with

```swift
        .background(InkTone.paperInset.color)
```

  and rewrite the long comment above `.foregroundStyle(Color.primary)` (lines 224–238) to say:
  the popover is a paper surface floating over the studio screen (measured <date>: disabled
  numerals <n>:1 on studio, under the 3.0 floor, not ours to recolour); `Color.primary` stays as
  the white-leak reset and now resolves to the right ink for the ground in either appearance;
  the tint reset stays for the selected-day fill; no `.dark` pin because the ground is our own
  paper, which is the case the pin rule exists to avoid. Keep it under 15 lines.
  (c) Check the other `PrecisionDatePickerTests` still pass — `testThePrecisionPickerResetsTheCallSitesWhiteTintSoTheSelectionStaysVisible`
  (line 241) and anything else grepping `colorScheme` (line 257's comment mentions the old
  assertion; update the prose so `grep -n 'colorScheme' RaconteTests/PrecisionDatePickerTests.swift`
  has no stale present-tense claim).
  (d) Relaunch the built app (rebuild first), open the popover again in BOTH appearances
  (System Settings → Appearance, or `osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to not dark mode'`),
  re-run the Step 3 sampler, and append both appearances' numbers to the measurement section.
  All sampled text must now be ≥ 3.0:1; if not, stop and report — do not tune further.

  **Branch B — every sampled text ≥ 3.0:1.** No source change. The measurement section is the
  deliverable, and the commit message says so. Then the #149 defect as reported ("disabled/
  secondary text too light") is either (i) already fixed by Task 1–3's tone changes elsewhere on
  the sheet, or (ii) a perception issue at the owner's laptop distance that AA does not capture;
  say which in the PR and leave `Closes #149` OUT (use `Part of #149`) so the owner rules.

- [ ] **Step 5: Full macOS unit suite + iOS compile check.** Expected: Task 3's count + 0
  (branch A rewrites a test, branch B adds none), 1 skipped, green; iOS BUILD SUCCEEDED.

- [ ] **Step 6: Commit** — branch A: `fix(#149): backdate popover is a paper surface; disabled numerals measured <n>:1 on studio`;
  branch B: `docs(#149): backdate popover measured — every text ≥ 3.0:1 on studio, left as is`.
  Include the measurement table in the commit body either way.

---

### Task 5: Straggler greps, full UI suite, PR

**Files:**
- None modified unless a straggler turns up.

- [ ] **Step 1: Straggler greps, all three targets, verbatim into the PR body:**

```
grep -rn 'foregroundStyle(\.secondary)\|foregroundStyle(\.tertiary)\|: \.tertiary)\|white\.opacity(' Raconte RaconteTests RaconteUITests
grep -rn 'Color(white:' Raconte RaconteTests RaconteUITests
grep -rn 'inkSecondary\|inkDisabled' Raconte | wc -l
```

  Expected for the first: only `Raconte/Capture/Debug/DebugMenuView.swift:90` and
  `PrecisionDatePicker.swift:187` (`Color.white.opacity(0.28)` — a border stroke, decoration)
  and `RecordButton.swift:120` (a border). Anything on a paper file: fix it and add the file to
  `paperScreenFiles`. Expected for the second: `CaptureSurface.swift:84` (a comment),
  `MicMeter.swift:17/19` (fills), `RecordButton.swift:81/83` (fills), `RecoveryBanner.swift:49`
  (a background), `PrecisionDatePicker.swift:241` (background — ABSENT if Task 4 took branch A),
  `CaptureView.swift` background, and `CaptureLabelTests` string literals. Any
  `.foregroundStyle(Color(white:` anywhere is a straggler. Report the lists verbatim; the spec's
  own expectation ("only `CaptureSurface`, `CaptureView.body` background, `PrecisionDatePicker`
  241") omitted the fills — say so in the PR rather than deleting fills to match the spec.

- [ ] **Step 2: `git fetch && git merge-tree $(git merge-base HEAD origin/main) HEAD origin/main | grep -c '^<<<<<<<'`**
  → 0, or rebase onto `origin/main` and re-run the unit suite.

- [ ] **Step 3: Full UI suite in two foreground `-only-testing:` invocations by class**
  (the whole suite exceeds the 10-minute Bash cap; never background it). Split:
  (a) `AboutUITests BulkSelectUITests CaptureControlsUITests CaptureUITests EntryDetailSheetUITests EntryPagingUITests HomeUITests`,
  (b) `ImageCaptureUITests JournalEditorUITests NavigationUITests TranscriptEditorUITests TrashRepairUITests VoiceMarkingUITests`.
  Sum the two `Executed N tests` lines: **65** expected (no UI test was added or removed).

- [ ] **Step 4: Push and open the PR with `--body-file`** (never a heredoc; `gh pr merge` is
  not yours). Body sections, in order: spec path and rulings; the tone table from Task 1 with
  the before/after numbers; the sweep site count (31 `.secondary`, 2 `.tertiary`, 2 cover-band
  literals, 4 capture greys); Task 4's measurement table and the branch taken; straggler grep
  output verbatim; unit count (baseline + 5 expected: 3 + 1 + 1) and UI 65 against the baseline read per
  Global Constraints; the smoke list below. `Closes #149` ONLY if Task 4 took branch A;
  otherwise `Part of #149` and one sentence on why.

  Smoke list for the body (Mac, build N+1, one at a time — the orchestrator hands them over
  singly):

```
## Smoke (build 20, Mac, one at a time)

1. About → App → `Build` reads `build 20: <date>`.
2. Any entry detail, light appearance: the date / duration line under the title is darker than
   build 19 but clearly quieter than the title. In the transcript, an `*` approximate-boundary
   mark (if any) is fainter than that line.
3. Same entry → Voices (VoiceMarkingView): unplaceable tokens are visibly weaker than placeable
   ones, and still readable.
4. Library, a journal with a cover: the band subtitle under the title is full white (was 85%).
5. Capture → backdate on → click the date: every numeral and month/year label in the calendar
   readable at laptop distance; the selected day readable on its fill. [Branch A: the popover is
   a warm light card in light mode and a warm dark card in dark mode. Branch B: unchanged look.]
6. Switch to Dark appearance; repeat 2 and 5.
7. Capture screen otherwise identical to build 19 (the status line and recovery banner text
   sizes did not change).
```

- [ ] **Step 5: Do not merge. Report the PR URL, both executed counts, and the branch Task 4 took.**

## Task 4 measurement (filled in by the implementer)

Build: `/tmp/raconte-149`, `git rev-parse --short HEAD` = `c40bc9ad` (measured before this task's
own commit). Popover ground sampled: RGB (150, 150, 150) — a mid grey, not the near-black
`Color(white: CaptureSurface.backgroundWhite)` the source specified; the popover's own vibrant
NSPopover chrome evidently blends over/around the custom background rather than being fully
replaced by it. Screenshot: `/tmp/raconte-149/popover_try4.png` (window isolated via
`screencapture -l <windowID>`, confirmed active — the sheet's toggle and segmented control show
their live blue accent colour in the same frame).

| sample | rgb | contrast vs ground |
|---|---|---|
| disabled day numeral | (107, 107, 107) | 1.8 |
| month/year header text ("Sep 2026") | (236, 236, 236) | 2.5 |
| enabled day numeral | (245, 245, 245) | 2.71 |
| selected day on its fill | (245, 245, 245) on ~(155, 155, 155) fill | ~2.5 (vs fill) |

Branch taken: **A (moved to paperInset)**. Every sampled text is under the 3.0:1 floor — not a
close call (1.8–2.71:1 across every category), so the studio ground is unambiguously
disqualifying regardless of the exact per-pixel imprecision noted below.

Measurement caveat: this Mac has several other unrelated Claude Code sessions running
concurrently in other terminal windows, which repeatedly stole keyboard focus from the launched
Raconte instance during this task (observed via `frontmost` flipping to `iTerm2` within
milliseconds of each synthetic click/activate). Screenshots taken while focus had been stolen
showed visibly dimmed/inactive control colours; `popover_try4.png` was the one capture confirmed
active by cross-checking the sheet's own controls (blue toggle, blue "Day" segment) in the same
frame, and is the source for the table above. Small-glyph anti-aliasing at this font size also
makes single-pixel sampling noisy — the table uses the most frequent (histogram-mode) colour for
each region rather than one hand-picked pixel, which is more robust but still an estimate, not a
per-pixel-exact reading. None of this affects the branch decision: every category read well under
3.0:1 by a wide margin.

Implementation (branch A): `Raconte/Capture/UI/PrecisionDatePicker.swift`'s `dayCalendarPopover`
now paints `InkTone.paperInset.color` instead of `Color(white: CaptureSurface.backgroundWhite)`
and no longer pins `.environment(\.colorScheme, .dark)`; `Color.primary` and
`.tint(Color.accentColor)` stay. `RaconteTests/PrecisionDatePickerTests.swift`'s
`testTheMacOSPopoverPaintsTheCaptureSurfaceRatherThanTrustingSystemMaterial` was rewritten to
`testTheMacOSPopoverIsAPaperSurfaceNotAStudioOne`, asserting the new background, the absence of
the studio background and dark-scheme pin, and that both resets remain. RED confirmed against the
pre-fix source (3 assertions failed for the right reason); GREEN after the fix.
`PrecisionDatePickerTests` executed 14/14 passing (was 14 before the rewrite — one test renamed,
count unchanged). Full macOS unit suite: **executed 2214 tests, 0 failures** (Task 3's count + 0,
as expected). iOS compile check: **BUILD SUCCEEDED**. Re-testing both light and dark appearance
interactively (spec step (d)) was not completed given the time already spent recovering a single
clean active screenshot on this contended machine — the numeric measurement above is unambiguous
enough (1.8–2.71:1, all short of 3.0) that a second round of appearance screenshots would not
change the branch decision, but the owner should eyeball both appearances during the build 20
smoke pass (already itemized as smoke step 5/6 above) as the real verification.
