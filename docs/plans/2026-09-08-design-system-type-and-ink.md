# Design system: type roles in points, ink text roles with floors (#162, #149)

Spec, 2026-09-08. Owner rulings recorded inline. Two batches, one token layer.

## Rulings (owner, 2026-09-08)

1. **One spec, two batches.** Batch 1 = #162 macOS type scale. Batch 2 = #149 text-colour roles,
   backdate sheet, literal sweep. Separate PRs; batch 2 branches from main after batch 1 merges.
2. **Platform-only.** Every macOS window gets the larger scale regardless of width. No
   window-size threshold.
3. **WCAG AA floors** for paper text roles: 4.5:1 for primary and secondary text, 3:1 for
   disabled text, large labels and glyphs. Measured against the surface the text actually sits
   on, in both appearances. The capture (studio) surface keeps its existing stricter 7.0:1 floor.
4. **The capture screen is out of batch 1.** `CaptureView`, `PrecisionDatePicker`,
   `RecStatusLine`, `RecoveryBanner`, `RecordButton`, `LiveTranscriptText`, `VoiceMarkingView`
   keep their sizes. Only their colour literals move, in batch 2.

## Why (facts, measured)

- `.dynamicTypeSize` and `@ScaledMetric` are inert on macOS 26 (harness, 2026-09-08). Sizes must
  be points.
- Apple's text styles render smaller on macOS than iOS: caption 12→10, subheadline 15→11, body
  17→13, headline 17→13 (`CaptureTextSize.pointSize(on:)`). "30% too small" is this drift.
- `CaptureSurface` already states the rule for the capture screen: macOS is held to the iOS
  rendered size. Batch 1 extends that rule to the paper screens.
- Paper-screen font sites today (production target, capture excluded): `.caption` ×28,
  `.subheadline` ×11, `.headline` ×7, `.caption2` ×6, `.footnote` ×3, `.body` ×3, serif body ×7,
  `.system(size:)` literals ×16 (13, 14, 15, 16, 17, 22, 24, 26, 36), `TypeScale` ×3.
- Text colour sites: `InkTone.*` ×44, bare `.secondary` ×32, `.tertiary` ×2, `Color.primary` ×5,
  `Color(white:)` ×4 (all capture), `.white.opacity(0.85)` ×1 (LibraryView 802), `.white` ×5.

## Batch 1 — `TypeRole` (#162)

### Token

`Raconte/App/TypeScale.swift` grows a `TypeRole` enum. Each case carries an iOS text style
(Dynamic Type keeps working) and a macOS point size equal to the iOS rendered size of that style.

| role | iOS style | iOS pt | macOS pt (was) | used for |
|---|---|---|---|---|
| `meta` | `.caption2` | 11 | 11 (10) | counts, tiny status |
| `label` | `.caption` | 12 | 13 (10) | row metadata, sidebar subtitles, dates |
| `footnote` | `.footnote` | 13 | 13 (10) | section footers, explanations |
| `secondary` | `.subheadline` | 15 | 15 (11) | row second lines, banners |
| `body` | `.body` | 17 | 17 (13) | About rows, detail prose |
| `headline` | `.headline` | 17 | 17 (13) | row titles, section titles |
| `reading` | `.system(.body, design: .serif)` | 17 | 17 (13) | transcript prose on paper |

macOS values are stated literally in the enum, not computed from the capture table, so a later
edit to one screen's floor cannot silently move the other. A unit test pins them equal to
`CaptureTextSize.pointSize(on: .macOS)`'s iOS column (see Tests).

API: `TypeRole.font` → `Font`. Sites write `.font(TypeRole.label.font)`. Weight and
`.monospacedDigit()` stay at the call site (`TypeRole.label.font.weight(.semibold)`).

### Literals

The 16 `.system(size:)` literals become named `TypeScale` constants with a macOS branch, in the
existing per-platform style of the Home three. Names and macOS values (iOS value unchanged
unless stated):

- `homeChevron` 13 → macOS 15 (HomeView 125)
- `homeNewEntryButton` 17 → macOS 19 (HomeView 147)
- `homeEmptyTitle` 24 serif → macOS 28, `homeEmptyBody` 15 → macOS 17 (HomeView 163/166)
- `libraryRowMeta` 13 → macOS 15 (LibraryView 300, 311; TrashView 174, 303, 320)
- `libraryOutOfSpanGlyph` 14 → macOS 16 (LibraryView 697; #161's glyph, keeps `.semibold`)
- `trashUnreadableTitle` 16 → macOS 18 (TrashView 172, 181)
- `libraryJournalTitle` 22 → macOS 24 (LibraryView 390)
- `libraryCoverTitle` 26 serif → macOS 28 (LibraryView 797, 814)
- `detailPlayGlyph` 36 → unchanged both (EntryDetailView 613; a glyph, not text)

Rule: the constant is the default for every literal above. A site switches to a role instead only
when it is a `Text` of running prose (a sentence or more); glyphs, counts, dates and buttons keep
the constant. The implementer states which sites switched, in the PR.

### Sweep

Every `.font(.<style>)` and serif-body site in these files moves to a role:
`LibraryView`, `TrashView`, `EntryDetailView`, `EntryInfoSheet`, `TranscriptEditorView`,
`RevisionHistoryView`, `JournalPickerSheet`, `JournalSpanEditor`, `JournalEditorView`,
`SidebarView`, `SyncStatusSectionView`, `AboutView`, `HomeView`, `PlaybackProgressLine`.
`PlaybackProgressLine` and `VoiceMarkingView` are rendered on paper (entry detail), so they are
in; `VoiceMarkingView` 43/149/162 too. Capture-only files listed in ruling 4 stay untouched.

Straggler check: `grep -rn '\.font(\.\(caption\|caption2\|footnote\|subheadline\|body\|headline\))' Raconte` returns only capture-surface files after the sweep; `grep -rn 'system(size: [0-9]' Raconte` returns only `NeutralCoverTile`, `CaptureSurface`, `CaptureControlBarMetrics`, `RecStatusLine`, `RecordButton`, `LiveTranscriptText`.

### Clipping risks (each gets an expected number and a smoke line)

- **Sidebar rows** (`SidebarView` 133–163): 28 pt thumb beside a title (system default) and a
  `label` subtitle. Subtitle grows 10→13 on macOS. Expected row height ≈ 40 pt; the thumb stays
  28. Pass: subtitle not clipped, thumb not squashed.
- **Home spine rows** (`HomeView` 129, 151): fixed `frame(height: 52)`. Title is already 22 pt on
  macOS; the chevron grows 13→15. Expected: fits. Smoke: no vertical clip on a long title
  (`lineLimit` unchanged).
- **Library cover band** (`LibraryView` 761–785, `Self.height`): title 26→28 serif on an
  overlay. Expected: fits inside the band; if the band clips, the band grows, the type does not
  shrink.
- **Trash rows and the unreadable block** (`TrashView`): `label` and `secondary` grow; rows are
  intrinsic height, no fixed frames. Expected: rows taller, nothing clipped.
- **About** rows use `body`, 13→17 on macOS: the `Build` row must still show
  `build N: <date>` on one line at the default window width.

No `lineLimit(1)` exists on paper screens today (grep, 2026-09-08), so no line-shrink risk.

### Tests

- `TypeScaleTests`: every `TypeRole` macOS size equals `CaptureTextSize.pointSize(on: .iOS)` for
  its iOS style; every macOS size ≥ 1.25 × `CaptureTextSize.pointSize(on: .macOS)` for that
  style, except `meta` (11 vs 10, +10%, the one style Apple already sizes close). Every named
  literal constant's macOS value ≥ its iOS value.
- Proof of RED: add the test with the enum absent, watch it fail to compile; then with values
  copied from the macOS column, watch the equality assertion fail.
- Source-scanning test (comments stripped, `Source-scanning tests must strip comments`): no
  bare `.font(.caption…)` in the paper file list above.
- UI: existing suites must stay green at the same count (an assertion added to an existing
  test does not move it). No new UI test — sizes are unit-pinned; clipping is a smoke.

### Smoke (build N+1, Mac, one at a time)

1. About → App → `Build` row reads `build N+1: <date>`, on one line.
2. Sidebar: journal subtitles readable at laptop distance, thumbs 28 pt, nothing clipped.
3. Library, a journal with a cover: band title larger, still inside the band.
4. Trash with the unreadable block: block text and row metadata larger; block intact.
5. Entry detail: transcript prose visibly larger than build 18. Play glyph unchanged.
6. Capture screen: identical to build 18 (ruling 4).

## Batch 2 — ink text roles and the backdate sheet (#149)

### Token

`InkTone` gains `inkDisabled` (paper, light and dark). Text-role floors, on `paper` AND
`paperInset`, both appearances:

- `ink` ≥ 4.5:1
- `inkSecondary` ≥ 4.5:1
- `inkDisabled` ≥ 3.0:1 and visibly weaker than `inkSecondary` (≥ 1.3:1 between them)
- `accent`, `warning` ≥ 3.0:1 (already tested on paper; add paperInset)

Studio roles keep `CaptureSurface.minimumControlContrast` (7.0). No new studio role: the capture
screen already has `studioInk` (1.0) and `studioInkDim` (0.62); `CaptureLabel.labelColor`'s
0.78 secondary stays.

Contrast helper: `InkSurface.contrast(_ tone:, on surface:, appearance:)` generalising
`contrastOnPaper`, so the test table is one loop, not one function per pair.

### Sweep

- 32 bare `.foregroundStyle(.secondary)` → `InkTone.inkSecondary.color`.
- 2 `.tertiary` (EntryDetailView 995, VoiceMarkingView 164 unplaceable token) → `inkDisabled`.
- `LibraryView` 802 `.white.opacity(0.85)` on the cover band → `InkTone.studioInk` or a new
  constant; measure against the band's gradient floor (`.black.opacity(0.55…0.9)`), floor 4.5.
- Capture `Color(white:)` ×4 (RecoveryBanner 22, RecStatusLine 57/85, PlaybackProgressLine 49)
  → the existing `CaptureLabel` tones (1.0 / 0.78). `PlaybackProgressLine` is on paper in entry
  detail: it takes `inkSecondary` there, not a capture grey.
- `Color.primary` ×5 stay: they are deliberate resets against the white leak (documented).

Straggler check: `grep -rn 'foregroundStyle(\.secondary)\|foregroundStyle(\.tertiary)\|Color(white:' Raconte` → only `CaptureSurface`, `CaptureView.body` background, `PrecisionDatePicker` 241.

### Backdate sheet (`PrecisionDatePicker`, macOS popover, lines 224–242)

The dim text is drawn by Apple's graphical `DatePicker` inside a popover pinned to the studio
surface (`Color(white: 0.05)`, `.dark` scheme). A token cannot recolour a system control's
disabled tone. Order of work:

1. **Measure.** Screenshot the popover, sample the disabled day numerals and the month/year
   secondary text, compute contrast against 0.05 grey. Record the numbers in the PR.
2. **If any sampled text < 3.0:1**, move the popover off studio: background `InkTone.paperInset`,
   ambient colour scheme (no `.dark` pin), keep `.foregroundStyle(Color.primary)` (the white-leak
   reset, PrecisionDatePicker 227–232, must stay) and `.tint(Color.accentColor)`. The popover
   becomes a paper surface floating over the studio screen, which Apple's picker is tuned for.
3. **If all ≥ 3.0:1**, leave the surface, and the defect is the sheet's own `Text` on studio:
   move those to `captureLabel` tones (7.0 floor) and report the measurement as the fix's basis.

The 2026-08-15 white-on-white leak and the "capture controls pin `.dark`" rule are not regressed
by option 2: the pin rule exists because ambient controls on the STUDIO ground render
dark-on-dark; a control on its own paper ground is the case the rule was written to avoid.

### Tests

- `InkSurfaceTests`: the floor loop above (tone × surface × appearance), RED first by setting
  `inkDisabled` to `inkSecondary`'s value (fails the 1.3:1 separation).
- Source-scanning test: no `.secondary`/`.tertiary` foreground in the paper file list.
- `CaptureLabelTests` unchanged.

### Smoke

1. Backdate sheet on the Mac: every numeral and label readable at laptop distance, selected day
   readable on its fill, no white-on-white in the New Journal field.
2. Any entry detail: secondary lines quieter than the title but readable; disabled voice tokens
   in `VoiceMarkingView` visibly weaker than placeable ones.
3. Dark appearance: same two screens.

## Out of scope

- Capture-screen type sizes (ruling 4). If batch 1 smokes well, a follow-up issue can extend
  `CaptureLabel.textSize(on:)`.
- Sidebar thumb size (28 pt) and the Home shelf sizes (already ruled).
- A paired size+colour modifier for paper (considered, rejected: roles don't map 1:1).
- Window-size-aware scaling (ruling 2).
