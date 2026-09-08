# Batch C (2026-09-08) Implementation Plan — type roles in points (#162) + Trash headers (#168)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One PR from `main` that gives every paper screen a per-platform type scale in points
(macOS text renders at the iOS size, ~30% larger than today) and gives the Trash screen matched
section headers.

**Architecture:** `Raconte/App/TypeScale.swift` grows a `TypeRole` enum (iOS keeps the semantic
text style so Dynamic Type still scales; macOS states a point size) plus named per-platform
constants for the sizes no text style has. Every `.font(.<style>)` and `.system(size:)` literal
on the paper screens moves onto a role or a constant. The capture screen is untouched. A
source-scanning unit test pins the sweep. `TrashView` gains a `Deleted entries` header to match
the existing `Unreadable entries` one.

**Tech Stack:** SwiftUI multiplatform (iOS 26 + macOS 26), Swift 6 strict concurrency, XcodeGen
project, XCTest + XCUITest.

**Spec:** `docs/plans/2026-09-08-design-system-type-and-ink.md` (batch 1 section) and issue #168
(`gh issue view 168`). This plan implements batch 1 only. Batch 2 (#149 ink roles) is a later
plan, branched after this merges.

## Global Constraints

- Branch `feat/162-type-roles` from `main` at or after `deea0f54`. Work in a worktree; the main
  checkout stays on `main` (`git checkout` of a worktree'd branch fails silently in a chain).
- **The capture screen keeps its sizes** (spec ruling 4). Never edit `CaptureView.swift`,
  `PrecisionDatePicker.swift`, `RecStatusLine.swift`, `RecoveryBanner.swift`,
  `RecordButton.swift`, `LiveTranscriptText.swift`, `CaptureSurface*.swift`,
  `CaptureControlBarMetrics.swift`. `VoiceMarkingView.swift` and `PlaybackProgressLine.swift`
  ARE in scope (they render on paper in entry detail).
- macOS sizes are points, stated literally. Never `.dynamicTypeSize`, never `@ScaledMetric`
  (both inert on macOS 26). iOS keeps semantic styles.
- Weight and `.monospacedDigit()` stay at the call site: `TypeRole.label.font.weight(.semibold)`.
- New test FILES need `xcodegen generate` before they run; a suite that stays at the old count
  after adding a file is the tell. This plan adds no new test file (all tests go into
  existing files), so no regen is needed — but if you do add one, regenerate.
- Test-count baseline (main CI run 34263241845, after #166): **unit 2203, 1 skipped; UI 65.**
  Every task reports the executed count. Bash `timeout: 600000` on every xcodebuild.
- macOS unit test command (sandbox kept; never `CODE_SIGNING_ALLOWED=NO`):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

- iOS compile check (must pass on every task; the `#else` branches only compile here):

```
xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "BUILD|error:" | tail -3
```

- Commit after each task with the trailer:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BXCMRx6nRpbwBWspYouNWS
```

- Straggler greps run over all three targets (`Raconte RaconteTests RaconteUITests`), never one.

---

### Task 1: `TypeRole` and the named size constants, unit-pinned

**Files:**
- Modify: `Raconte/App/TypeScale.swift` (whole file, currently 3 constants)
- Test: `RaconteTests/TypeScaleTests.swift` (append; existing test stays)

**Interfaces:**
- Consumes: `CaptureTextSize` and `CapturePlatform` from `Raconte/Capture/UI/CaptureSurface.swift`
  (`CaptureTextSize.caption2/.caption/.footnote/.subheadline/.body/.headline`,
  `pointSize(on: .iOS) -> Double`, `pointSize(on: .macOS) -> Double`).
- Produces, used by Tasks 2–4:
  - `enum TypeRole: CaseIterable, Sendable { case meta, label, footnote, secondary, body, headline, reading }`
  - `var font: Font` (SwiftUI) on `TypeRole`
  - `var macOSPointSize: Double`, `var iOSStyle: CaptureTextSize`, `var isSerif: Bool` on `TypeRole`
  - `TypeScale.homeChevron`, `.homeNewEntryButton`, `.homeEmptyTitle`, `.homeEmptyBody`,
    `.libraryRowMeta`, `.libraryOutOfSpanGlyph`, `.trashUnreadableTitle`, `.libraryJournalTitle`,
    `.libraryCoverTitle`, `.detailPlayGlyph` — all `CGFloat`, per-platform.
  - `TypeScale.namedSizes: [(name: String, size: CGFloat, iOSSize: CGFloat)]` for the test.

- [ ] **Step 1: Write the failing tests** — append to `TypeScaleTests`:

```swift
    /// Spec batch 1: a role's macOS size is the iOS rendered size of its style — the same rule
    /// `CaptureSurface` already states for the capture screen. Stated literally in the enum, so
    /// this test is a pin, not a tautology: it compares two independently written tables.
    func testEveryRoleRendersAtTheiOSSizeOnMacOS() {
        for role in TypeRole.allCases {
            XCTAssertEqual(role.macOSPointSize, role.iOSStyle.pointSize(on: .iOS),
                           "\(role): macOS must render at the iOS size of \(role.iOSStyle)")
        }
    }

    /// The ~30% ask (#162): every role except `meta` is at least 1.2× Apple's macOS default
    /// for its style (caption is 10→12, the smallest step; body/headline are 13→17, 1.31×).
    /// `meta` is caption2, which Apple already sizes 10 vs 11 — +10% is all there is.
    func testEveryRoleIsAtLeastAFifthLargerThanAppleMacOSDefault() {
        for role in TypeRole.allCases where role != .meta {
            let apple = role.iOSStyle.pointSize(on: .macOS)
            XCTAssertGreaterThanOrEqual(role.macOSPointSize, apple * 1.2,
                                        "\(role): \(role.macOSPointSize) vs Apple macOS \(apple)")
        }
        XCTAssertEqual(TypeRole.meta.macOSPointSize, 11)
    }

    /// Only `reading` is serif; everything else is the system face.
    func testOnlyReadingIsSerif() {
        XCTAssertEqual(TypeRole.allCases.filter(\.isSerif), [.reading])
    }

    /// Named literal constants: macOS never smaller than iOS, and the play glyph is the one
    /// deliberate exception that does not move at all (a glyph, not text).
    func testNamedSizesNeverShrinkOnMacOS() {
        for entry in TypeScale.namedSizes {
            XCTAssertGreaterThanOrEqual(entry.size, entry.iOSSize, entry.name)
        }
        XCTAssertEqual(TypeScale.detailPlayGlyph, 36)
        #if os(macOS)
        XCTAssertEqual(TypeScale.libraryRowMeta, 15)
        XCTAssertEqual(TypeScale.libraryCoverTitle, 28)
        XCTAssertEqual(TypeScale.homeNewEntryButton, 19)
        #else
        XCTAssertEqual(TypeScale.libraryRowMeta, 13)
        XCTAssertEqual(TypeScale.libraryCoverTitle, 26)
        XCTAssertEqual(TypeScale.homeNewEntryButton, 17)
        #endif
    }
```

- [ ] **Step 2: Run to verify it fails** — expected: compile error, `cannot find 'TypeRole' in scope`.

- [ ] **Step 3: Implement** — replace `Raconte/App/TypeScale.swift` with:

```swift
import SwiftUI

/// #162: the app's type-size decisions, in points, per platform (owner rulings 2026-09-08,
/// spec docs/plans/2026-09-08-design-system-type-and-ink.md).
///
/// `.dynamicTypeSize` and `@ScaledMetric` are inert on macOS 26 (measured 2026-09-08 in a
/// standalone harness), so macOS sizes are stated in points. iOS keeps Apple's semantic styles so
/// Dynamic Type still scales them. The rule for the macOS numbers is the one `CaptureSurface`
/// already states for the capture screen: **macOS renders at the iOS size**. Apple's macOS
/// scale runs ~30% smaller (caption 10 vs 12, body 13 vs 17), which was the whole complaint.
///
/// The paper screens' text roles. Capture-screen text is NOT on this scale — it has its own
/// (`CaptureLabel`, a stricter 7:1 surface) and was ruled out of the sweep.
enum TypeRole: CaseIterable, Sendable {
    /// Counts, tiny status — caption2.
    case meta
    /// Row metadata, sidebar subtitles, dates — caption.
    case label
    /// Section footers and explanations — footnote.
    case footnote
    /// Row second lines, banners — subheadline.
    case secondary
    /// About rows, detail prose — body.
    case body
    /// Row titles, section titles — headline.
    case headline
    /// Transcript prose on paper — body, serif.
    case reading

    /// The Apple style this role wears on iOS (and whose iOS size macOS is held to).
    var iOSStyle: CaptureTextSize {
        switch self {
        case .meta: .caption2
        case .label: .caption
        case .footnote: .footnote
        case .secondary: .subheadline
        case .body, .reading: .body
        case .headline: .headline
        }
    }

    /// Stated literally — NOT computed from `CaptureTextSize` — so an edit to the capture
    /// table can never silently move the paper screens. `TypeScaleTests` pins the two equal.
    var macOSPointSize: Double {
        switch self {
        case .meta: 11
        case .label: 12
        case .footnote: 13
        case .secondary: 15
        case .body, .reading, .headline: 17
        }
    }

    var isSerif: Bool { self == .reading }

    var font: Font {
        #if os(macOS)
        .system(size: macOSPointSize, design: isSerif ? .serif : .default)
        #else
        switch self {
        case .meta: .caption2
        case .label: .caption
        case .footnote: .footnote
        case .secondary: .subheadline
        case .body: .body
        case .headline: .headline
        case .reading: .system(.body, design: .serif)
        }
        #endif
    }
}

/// Sizes no text style has: the former `.system(size:)` literals, named, per platform.
/// macOS values are the iOS value scaled toward the same ~1.3 ratio and rounded to whole points;
/// `detailPlayGlyph` is a glyph, not text, and does not move.
enum TypeScale {
    #if os(macOS)
    static let homeFaceOutTitle: CGFloat = 17
    static let homeSpineTitle: CGFloat = 22
    static let homeRelativeTime: CGFloat = 14
    static let homeChevron: CGFloat = 15
    static let homeNewEntryButton: CGFloat = 19
    static let homeEmptyTitle: CGFloat = 28
    static let homeEmptyBody: CGFloat = 17
    static let libraryRowMeta: CGFloat = 15
    static let libraryOutOfSpanGlyph: CGFloat = 16
    static let trashUnreadableTitle: CGFloat = 18
    static let libraryJournalTitle: CGFloat = 24
    static let libraryCoverTitle: CGFloat = 28
    #else
    static let homeFaceOutTitle: CGFloat = 16
    static let homeSpineTitle: CGFloat = 19
    static let homeRelativeTime: CGFloat = 14
    static let homeChevron: CGFloat = 13
    static let homeNewEntryButton: CGFloat = 17
    static let homeEmptyTitle: CGFloat = 24
    static let homeEmptyBody: CGFloat = 15
    static let libraryRowMeta: CGFloat = 13
    static let libraryOutOfSpanGlyph: CGFloat = 14
    static let trashUnreadableTitle: CGFloat = 16
    static let libraryJournalTitle: CGFloat = 22
    static let libraryCoverTitle: CGFloat = 26
    #endif
    static let detailPlayGlyph: CGFloat = 36

    /// Every named size with its iOS value, for the never-shrinks test. The iOS column is
    /// repeated here on purpose (a second, independent statement of the numbers).
    static let namedSizes: [(name: String, size: CGFloat, iOSSize: CGFloat)] = [
        ("homeFaceOutTitle", homeFaceOutTitle, 16),
        ("homeSpineTitle", homeSpineTitle, 19),
        ("homeRelativeTime", homeRelativeTime, 14),
        ("homeChevron", homeChevron, 13),
        ("homeNewEntryButton", homeNewEntryButton, 17),
        ("homeEmptyTitle", homeEmptyTitle, 24),
        ("homeEmptyBody", homeEmptyBody, 15),
        ("libraryRowMeta", libraryRowMeta, 13),
        ("libraryOutOfSpanGlyph", libraryOutOfSpanGlyph, 14),
        ("trashUnreadableTitle", trashUnreadableTitle, 16),
        ("libraryJournalTitle", libraryJournalTitle, 22),
        ("libraryCoverTitle", libraryCoverTitle, 26),
        ("detailPlayGlyph", detailPlayGlyph, 36),
    ]
}
```

Keep the existing `testHomeSizesFollowTheRuling` untouched; the three Home constants keep their
values.

- [ ] **Step 4: Proof the pin is not a tautology** — temporarily change `case .label: 12` to
  `case .label: 10` (Apple's macOS value), run `TypeScaleTests` only
  (`-only-testing:RaconteTests/TypeScaleTests`), watch BOTH the equality test and the ≥1.2×
  test fail naming `label`. Restore 12. Run again: PASS.

- [ ] **Step 5: Run the full macOS unit suite and the iOS compile check.** Expected: unit
  count 2203 + 4 = **2207**, 1 skipped; iOS BUILD SUCCEEDED.

- [ ] **Step 6: Commit** — `feat(#162): TypeRole and named per-platform sizes, unit-pinned`.

---

### Task 2: Sweep — Home, Sidebar, About, Sync status, Library, Trash

**Files:**
- Modify: `Raconte/Home/UI/HomeView.swift` (lines 125, 147, 163, 166)
- Modify: `Raconte/App/SidebarView.swift` (139)
- Modify: `Raconte/App/AboutView.swift` (116, 122)
- Modify: `Raconte/App/SyncStatusSectionView.swift` (47) — find with `grep -n "\.font(" `
- Modify: `Raconte/Library/UI/LibraryView.swift` (300, 311, 329, 342, 359, 390, 423, 535, 662, 671, 678, 686, 697, 706, 713, 723, 797, 801, 814, 818, 822)
- Modify: `Raconte/Library/UI/TrashView.swift` (139, 172, 174, 181, 303, 320, 434, 437, 466, 470, 482, 493)

Line numbers are from 2026-09-08 main; re-grep before editing:
`grep -n "\.font(" <file>`.

**Interfaces:**
- Consumes: `TypeRole.<role>.font`, `TypeScale.<name>` from Task 1.
- Produces: nothing new. Task 4's source scan will assert these files contain no bare style.

Mapping (apply mechanically; weight/monospaced modifiers stay):

| was | becomes |
|---|---|
| `.font(.caption2)` | `.font(TypeRole.meta.font)` |
| `.font(.caption)` | `.font(TypeRole.label.font)` |
| `.font(.caption.weight(.semibold))` | `.font(TypeRole.label.font.weight(.semibold))` |
| `.font(.caption.monospacedDigit())` | `.font(TypeRole.label.font.monospacedDigit())` |
| `.font(.footnote)` | `.font(TypeRole.footnote.font)` |
| `.font(.subheadline)` / `.subheadline.weight(…)` | `TypeRole.secondary.font` (+ weight) |
| `.font(.body)` | `.font(TypeRole.body.font)` |
| `.font(.headline)` | `.font(TypeRole.headline.font)` |
| `.font(.system(.body, design: .serif))` | `.font(TypeRole.reading.font)` |
| `.font(.system(size: 13))` in HomeView 125 | `.font(.system(size: TypeScale.homeChevron))` |
| `.font(.system(size: 17, weight: .semibold))` HomeView 147 | `.font(.system(size: TypeScale.homeNewEntryButton, weight: .semibold))` |
| HomeView 163 `size: 24, design: .serif` | `size: TypeScale.homeEmptyTitle, design: .serif` |
| HomeView 166 `size: 15` | `size: TypeScale.homeEmptyBody` |
| LibraryView 300/311, TrashView 174/303/320 `size: 13` or `15` | `size: TypeScale.libraryRowMeta` **unless** the site is a `Text` of running prose (a sentence or more) — then `TypeRole.secondary.font` (15) or `TypeRole.label.font` (13). State each switch in the commit body. |
| LibraryView 697 `size: 14, weight: .semibold` | `size: TypeScale.libraryOutOfSpanGlyph, weight: .semibold` |
| TrashView 172 `size: 16, weight: .semibold`, 181 `size: 16` | `TypeScale.trashUnreadableTitle` |
| LibraryView 390 `size: 22, weight: .semibold` | `TypeScale.libraryJournalTitle` |
| LibraryView 797/814 `size: 26, weight: .semibold, design: .serif` | `TypeScale.libraryCoverTitle` |

Do not touch any `.font(...)` whose argument is already `TypeScale.…`, `CaptureProse.font`, or a
`captureLabel(_:)` call. Do not change any `.foregroundStyle`.

- [ ] **Step 1: Re-grep the six files** for `\.font(` and list every hit with its line. Compare to
  the list above; any site not in the mapping table is reported, not guessed.

- [ ] **Step 2: Apply the mapping** to all six files.

- [ ] **Step 3: Verify the sweep is complete for these files:**

```
grep -n '\.font(\.\(caption\|caption2\|footnote\|subheadline\|body\|headline\)\|system(size: [0-9]\|system(\.body' Raconte/Home/UI/HomeView.swift Raconte/App/SidebarView.swift Raconte/App/AboutView.swift Raconte/App/SyncStatusSectionView.swift Raconte/Library/UI/LibraryView.swift Raconte/Library/UI/TrashView.swift
```

Expected: no output.

- [ ] **Step 4: Run the macOS unit suite and the iOS compile check.** Expected: **2207** unit,
  1 skipped, green; iOS BUILD SUCCEEDED. (No count change: this task moves call sites only.)

- [ ] **Step 5: Run the UI classes that exercise these screens, foreground, one invocation:**

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/HomeUITests -only-testing:RaconteUITests/NavigationUITests -only-testing:RaconteUITests/TrashRepairUITests -only-testing:RaconteUITests/BulkSelectUITests -only-testing:RaconteUITests/AboutUITests test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

Expected: green.

- [ ] **Step 6: Commit** — `feat(#162): sweep Home, Sidebar, About, Sync, Library, Trash onto TypeRole`.
  List in the body which `size: 13/15` sites became a role instead of `libraryRowMeta`.

---

### Task 3: Sweep — entry detail, editors, sheets, revision history

**Files:**
- Modify: `Raconte/Library/UI/EntryDetailView.swift` (144, 513, 523, 613, 703, 712, 717, 929, 983, 994, 1023)
- Modify: `Raconte/Library/UI/EntryInfoSheet.swift` (108, 112, 117, 143)
- Modify: `Raconte/Library/UI/TranscriptEditorView.swift` (117, 125, 151, 153, 159, 167, 169, 183)
- Modify: `Raconte/Library/UI/RevisionHistoryView.swift` (77, 82, 90, 97)
- Modify: `Raconte/Library/UI/JournalPickerSheet.swift` (79)
- Modify: `Raconte/Library/UI/JournalSpanEditor.swift` (61, 71, 79)
- Modify: `Raconte/Library/UI/JournalEditorView.swift` (123)
- Modify: `Raconte/Capture/UI/VoiceMarkingView.swift` (43, 149, 162) — on paper (entry detail); in scope
- Modify: `Raconte/Capture/UI/PlaybackProgressLine.swift` (48) — lives under Capture/UI but renders on paper in entry detail; in scope

Re-grep before editing: `grep -n "\.font(" <file>`.

**Interfaces:**
- Consumes: `TypeRole.<role>.font`, `TypeScale.detailPlayGlyph` from Task 1.

Same mapping table as Task 2, plus:

| was | becomes |
|---|---|
| EntryDetailView 613 `.system(size: 36)` | `.system(size: TypeScale.detailPlayGlyph)` |
| VoiceMarkingView 149 `.caption.weight(.semibold)` | `TypeRole.label.font.weight(.semibold)` |
| VoiceMarkingView 162 `.system(.body, design: .serif)` | `TypeRole.reading.font` |
| PlaybackProgressLine 48 `.caption.monospacedDigit()` | `TypeRole.label.font.monospacedDigit()` |

- [ ] **Step 1: Re-grep the nine files** for `\.font(`; list every hit. Report, don't guess, any
  site not covered by the mapping.

- [ ] **Step 2: Apply the mapping.**

- [ ] **Step 3: Verify:**

```
grep -n '\.font(\.\(caption\|caption2\|footnote\|subheadline\|body\|headline\)\|system(size: [0-9]\|system(\.body' Raconte/Library/UI/EntryDetailView.swift Raconte/Library/UI/EntryInfoSheet.swift Raconte/Library/UI/TranscriptEditorView.swift Raconte/Library/UI/RevisionHistoryView.swift Raconte/Library/UI/JournalPickerSheet.swift Raconte/Library/UI/JournalSpanEditor.swift Raconte/Library/UI/JournalEditorView.swift Raconte/Capture/UI/VoiceMarkingView.swift Raconte/Capture/UI/PlaybackProgressLine.swift
```

Expected: no output.

- [ ] **Step 4: macOS unit suite + iOS compile check.** Expected **2207**, 1 skipped, green;
  iOS BUILD SUCCEEDED.

- [ ] **Step 5: UI classes for these screens, foreground, ONE invocation:**

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/EntryDetailSheetUITests -only-testing:RaconteUITests/EntryPagingUITests -only-testing:RaconteUITests/TranscriptEditorUITests -only-testing:RaconteUITests/VoiceMarkingUITests -only-testing:RaconteUITests/JournalEditorUITests test 2>&1 | grep -E "Executed|error:|failed" | tail -5
```

Expected: green.

- [ ] **Step 6: Commit** — `feat(#162): sweep entry detail, editors, sheets onto TypeRole`.

---

### Task 4: Straggler scan test and repo-wide greps

**Files:**
- Test: `RaconteTests/TypeScaleTests.swift` (append)
- Uses: `RaconteTests/SourceScanning.swift` `strippingComments(_:)`

**Interfaces:**
- Consumes: the file lists from Tasks 2–3.

- [ ] **Step 1: Write the scan test** (append to `TypeScaleTests`):

```swift
    /// The paper screens are on `TypeRole`/`TypeScale`, never a bare Apple style or a size
    /// literal — a bare style is 10–13 pt on macOS, which is #162 coming back. Capture-surface
    /// files are deliberately absent from this list (spec ruling 4).
    private static let paperFiles = [
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
        "Raconte/Capture/UI/VoiceMarkingView.swift",
        "Raconte/Capture/UI/PlaybackProgressLine.swift",
    ]

    func testPaperScreensCarryNoBareTextStyleOrSizeLiteral() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let bare = [".font(.caption", ".font(.footnote", ".font(.subheadline",
                    ".font(.body", ".font(.headline", ".font(.system(.body",
                    ".font(.title", ".font(.largeTitle"]
        let literal = try NSRegularExpression(pattern: #"system\(size:\s*[0-9]"#)
        for path in Self.paperFiles {
            let url = root.appendingPathComponent(path)
            let source = strippingComments(try String(contentsOf: url))
            for pattern in bare {
                XCTAssertFalse(source.contains(pattern), "\(path) still has \(pattern)")
            }
            let hits = literal.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertEqual(hits, 0, "\(path) still has a system(size: <number>) literal")
        }
    }
```

- [ ] **Step 2: Proof of RED** — with `git stash` of Task 2's `HomeView.swift` change NOT
  available (it's committed), instead temporarily edit `HomeView.swift` to put back one
  `.font(.caption)`; run `-only-testing:RaconteTests/TypeScaleTests`; watch the test fail naming
  `HomeView.swift`. Revert the edit (`git checkout Raconte/Home/UI/HomeView.swift`). Run again: PASS.

- [ ] **Step 3: Repo-wide straggler greps, all three targets:**

```
grep -rn '\.font(\.\(caption\|caption2\|footnote\|subheadline\|body\|headline\))' Raconte RaconteTests RaconteUITests
grep -rn 'system(size: [0-9]' Raconte RaconteTests RaconteUITests
```

Expected: first grep hits only files named in the Global Constraints capture list. Second grep
hits only `NeutralCoverTile.swift`, `CaptureSurface+SwiftUI.swift`, `CaptureControlBarMetrics`
users (`RecStatusLine`, `RecordButton`), `LiveTranscriptText.swift`. Anything else: fix it and
add its file to `paperFiles`. Report the final hit list verbatim.

- [ ] **Step 4: macOS unit suite + iOS compile check.** Expected **2208**, 1 skipped, green.

- [ ] **Step 5: Commit** — `test(#162): paper screens carry no bare text style or size literal`.

---

### Task 5: Trash section headers (#168)

**Files:**
- Modify: `Raconte/Library/UI/TrashView.swift` (the `List` body, lines ~80–104 on main; the
  `unreadableSection` header at ~144)
- Test: `RaconteUITests/TrashRepairUITests.swift` (extend the existing test)

**Interfaces:**
- Consumes: `TypeRole.label.font` (Task 1) if a header needs an explicit font; `TrashPolicy.retentionDays`.
- Produces: accessibility identifier `trash.deleted.section` on the deleted header `Text`.

Design (issue #168, owner-picked mock, 2026-09-08): two matched section headers under the
`Trash` title, same style, each with a count. Names: **Unreadable entries** / **Deleted
entries**. Ordering unchanged (unreadable first). The deleted header carries the retention:
`Deleted entries · 4 · kept 30 days`. "Trash is empty" (deleted empty, unreadable present) still
renders under the `Deleted entries` header. The both-empty placeholder is unchanged.

- [ ] **Step 1: Extend the UI test** — in `testAnUnreadableEntryCanBeQuarantinedFromTrash`,
  right after the `section` assertion, add:

```swift
        let deletedHeader = app.staticTexts["trash.deleted.section"].firstMatch
        XCTAssertTrue(deletedHeader.waitForExistence(timeout: 5),
                      "the Deleted entries section header never appeared (#168)")
        XCTAssertTrue(deletedHeader.label.hasPrefix("Deleted entries"),
                      "header reads \(deletedHeader.label)")
        XCTAssertTrue(deletedHeader.label.contains("kept \(30) days"),
                      "header must state the retention (#168): \(deletedHeader.label)")
```

`TrashPolicy.retentionDays` is 30 (`Raconte/Library/TrashSweep.swift:10`).

- [ ] **Step 2: Run the class to verify it fails:**

```
xcodebuild -project Raconte.xcodeproj -scheme RaconteUI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RaconteUITests/TrashRepairUITests test 2>&1 | grep -E "Executed|error:|failed|never appeared" | tail -5
```

Expected: FAIL, "the Deleted entries section header never appeared".

- [ ] **Step 3: Implement** — in `TrashView`'s `List`, wrap the deleted rows (and the
  "Trash is empty" fallback) in one `Section` with a header:

```swift
                List {
                    unreadableSection
                    Section {
                        if model.trashed.isEmpty {
                            Text("Trash is empty")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.trashed) { item in
                                if selection.isActive {
                                    selectableRow(item)
                                } else {
                                    TrashEntryRow(item: item,
                                                  onRestore: { /* unchanged */ },
                                                  onDeleteNow: { pendingPermanentDelete = item })
                                }
                            }
                        }
                    } header: {
                        // #168: the deleted rows had no header, so they read as a continuation
                        // of the unreadable block. Same style as `unreadableSection`'s header;
                        // the identifier goes on the Text, never the Section (see the note there).
                        Text("Deleted entries · \(model.trashed.count) · kept \(TrashPolicy.retentionDays) days")
                            .accessibilityIdentifier("trash.deleted.section")
                    }
                }
```

Keep the existing `onRestore` closure body verbatim (copy it; do not paraphrase). Do NOT
attach `.sheet`/`.confirmationDialog` to the new `Section` (they silently never present on a
`Section` — the file's own comments say so).

Check the unreadable header for symmetry: if it has any explicit `.font(...)`, give the deleted
header the same one; if it has none, add none.

- [ ] **Step 4: Run the class again:** PASS. Executed count for the class unchanged (assertions
  added to an existing test).

- [ ] **Step 5: macOS unit suite** (TrashView compiles on both; any source-scan test over
  TrashView must still pass): **2208**, 1 skipped, green. iOS compile check: BUILD SUCCEEDED.

- [ ] **Step 6: Commit** — `feat(#168): Trash gets matched Unreadable / Deleted entries headers`.

---

### Task 6: PR

- [ ] **Step 1:** `git merge-tree` against current `origin/main` for conflicts; rebase if main moved.
- [ ] **Step 2:** Full UI suite split in two foreground `-only-testing:` invocations by class
  (the whole suite exceeds the 10-minute Bash cap); reconcile: **65** total expected.
- [ ] **Step 3:** Push, open the PR with `--body-file` (never a heredoc). Body: the spec path,
  the mapping table summary, which `size: 13/15` sites became roles, the straggler grep output
  verbatim, unit **2208** (1 skipped) and UI **65** against the baseline 2203/65, and the six-step
  Mac smoke from the spec ("Smoke (build N+1, Mac, one at a time)"). Say `Closes #168`. Do NOT
  say `Closes #162`: the capture screen and batch 2 remain — say `Part of #162`.
- [ ] **Step 4:** Do not merge. Report the PR URL.
