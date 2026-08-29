# UX redesign: landing → capture → viewing (design)

2026-08-29. Owner-approved direction from the design session (mocks:
Claude artifact "Raconte Redesign"). Anchor issues: #108 (opening), #55
(detail hierarchy), #18 (journal switcher), #103 (stale transcript), #107
(image-first affordance).

## Decisions (owner, 2026-08-28/29)

1. **Landing = calm capture.** The app keeps opening on the capture screen
   and recording stays one tap from launch, but the idle screen is quiet:
   journal name (tap → journal picker sheet), today's date, the record
   button, one "last entry" card. Backdate, voice field, recovery banners,
   and the build stamp leave the front surface.
2. **Entry detail = transcript first.** Date lives in the nav title
   (tappable → backdate, as today). The body opens with the transcript in
   a reading serif. Play bar pinned at the bottom. All metadata and
   editing (journal, backdate, edit transcript, mark voices, revision
   history, trash) move into one `⋯` sheet.
3. **Direction = ink & paper.** One shared token layer. Reading surfaces
   (library, detail, sheets) are warm paper in light mode and follow
   system dark mode; capture surfaces stay pinned near-black regardless —
   the same app dimming the lights, built from the same tokens.
4. **Journals = one designed picker sheet** (cover thumb + name + range +
   entry count + checkmark + "New Journal…"), used everywhere a journal is
   chosen: capture's "recording into", detail's move-entry, and any future
   chooser. Replaces the three ad-hoc `Menu`s.

Staged PRs (owner, 2026-08-29): tokens → entry detail + #103 → journal
picker + library → capture landing last. Each PR mergeable and smoke-able
alone; TestFlight build after the batch.

## Token layer (`InkSurface`, new; extends the CaptureSurface pattern)

Follow `CaptureSurface.swift`'s shape — enums with resolved values, a
SwiftUI adapter file, tests pin contrast — but for the whole app:

- **Palette** (light / dark):
  - `paper` #F7F4EE / near-black; `paperInset` #F0ECE3 (sheet + play bar
    ground); `hairline` #E5DFD4.
  - `ink` #211D18 / off-white; `inkSecondary` #8B8478; both held to ≥ 4.5:1
    on `paper`, pinned by test like `CaptureLabelColorTests`.
  - `accent` warm amber #916438 (darkened from the mock's #96683A to clear 4.5:1 on paper) (links, active states, scrubber) —
    replaces default blue accent on reading surfaces.
  - `record` red #E5484D — the app's one loud color, shared by capture and
    the floating record button.
  - `studio` = existing `Color(white: 0.05)` — promoted from the two
    literals in `CaptureView.swift` into the token layer.
- **Type**: UI text stays system sans via the existing `CaptureTextSize`
  scale (generalized); entry prose (transcript, snippets, receipt prose)
  uses the serif design (`.fontDesign(.serif)` / New York), 19 pt body on
  iOS with platform mapping per the CaptureSurface per-platform rule.
- Semantic colors preferred over literals everywhere the background isn't
  pinned (existing rule); the token layer is where pinned values live.

## Screens

### Entry detail (PR 2; closes #55, #103)

Top-to-bottom: nav bar (back = journal name, title = tappable date, `⋯`
trailing next to the #101 paging chevrons) → thumbnail strip (only when
images exist; tap → full-screen viewer, unchanged) → transcript
immediately, serif, voice-marked rendering kept → pinned bottom play bar
(48 pt play circle, scrubber, elapsed/total; omitted when no audio).

The `⋯` sheet (attached to the screen's outer view — never a `Section`,
per the known iOS 26 trap): header (full date + "Recorded … · duration"),
rows Journal (→ picker sheet), Backdate (→ existing editor), Edit
transcript, Mark voices, Revision history, then Move to Trash in red,
visually isolated. This is where every #55 bubble goes.

**#103 rides along**: verify the list→detail path pins `.id(captureID)`
the way #101's paging destination does; add the missing pin and a repro
UI test if it doesn't.

**Image-first entries (#107 affordance, same PR)**: an entry with images
but no audio shows, in place of transcript + play bar: "No words yet",
one line of invitation, and a 72 pt red record button that starts the
ordinary capture pipeline into this entry. No typed-text path (owner
ruling on #107).

### Journal picker sheet + library (PR 3; closes #18)

`JournalPickerSheet`: rows of 52 pt cover thumb (neutral mic/monogram
tile when coverless — never a broken image), name, "range · N entries",
checkmark on current, divider, "New Journal…" (reuses the existing
name-prompt flow). Presented from capture's journal name and detail's
`⋯` → Journal row.

Library: cover header band (190 pt, cover image with bottom gradient
scrim, serif journal title + range/count overlaid; coverless = quiet
`paperInset` band, ink title, one "Add Cover" affordance → existing
cover picker). Entry rows: 56 pt thumb (entry's own first image, else
neutral tile), "MMM d" + weekday · duration, two-line serif snippet;
month dividers within the year sections. Floating 60 pt record button
(bottom-trailing) starts capture into this journal. Sidebar journal rows
adopt the same row anatomy.

### Capture landing (PR 4; closes #108)

Idle: journal name + chevron (→ picker sheet), long date, 76 pt record
button in a 96 pt halo ring, "tap to record", last-entry card
(NavigationLink to detail), a bottom pull-up/disclosure that reveals the
demoted controls (backdate, voices) — recovery banners re-surface
automatically when present; they are not merely tucked away. Build stamp
moves to About only.

Recording: journal + date compact at top; live transcript fills the
middle (serif, current sentence full-white, earlier text dimmed); bottom
bar = red dot + timer + "Recording", level meter, voice-marker /
76 pt stop / paragraph-marker row. Same `CaptureLayoutModel` phase
structure; this is a re-skin + re-arrangement, not a state-machine
change. All capture invariants hold: nothing hangs off view lifecycle;
`CaptureScreenModel` untouched except where the demoted controls need a
disclosure flag.

## Image lifecycle (rules, from the mocks' Images page)

- A journal cover appears as: library header band, picker-row thumb.
  Entry-row thumbs use the entry's own first image, never the cover.
- Coverless/imageless states are quiet neutrals — no placeholder icons
  shouting absence, no broken-image glyphs.
- Full-screen viewer: studio-dark, "n of m", page dots, save; unchanged
  mechanics.

## Testing

- Token layer: unit tests pin contrast floors and platform type mapping
  (pattern: `CaptureLabelColorTests`, `EntitlementsParityTests`-style
  loudness).
- Each screen PR: UI tests via `openPlace`; existing suites
  (`EntryPagingUITests`, `NavigationUITests`) must keep passing —
  `testLaunchLandsDirectlyOnCaptureWithNoTaps` pins decision 1.
- #103 gets a red-first repro test (stash trick if needed).
- RaconteUI suite split by class per the 10-minute-cap rule.

## Out of scope

- macOS-specific layout polish beyond what the shared SwiftUI gives
  (no `Image` in `Menu` labels — picker is a sheet partly for this).
- Attach-image → invite-recording *capture-side* flow redesign beyond the
  detail-screen affordance (rest of #107's creation-flow pass).
- Sync hardening items (#91, #85).
