# Home: the bookshelf landing (#108)

2026-08-29. Owner-approved direction from the #108 design session. Fallback, if this
stalls: move `launchPlace` to `.allEntries` (option B) — one-line change, no new screen.

## Problem

Cold launch lands directly on CaptureView — the near-black studio surface, zero taps
(`PlaceRouting.launchPlace = .capture`, pinned by
`testLaunchLandsDirectlyOnCaptureWithNoTaps`). That was designed for one intent
(speak now). The owner's launches are mixed — review, edit, add — and the studio
surface is the wrong arrival for all but one of them. Owner: "not a very beautiful
experience." One deliberate tap to start recording is acceptable (ruled in session).

## Design

A new `Place.home`, the new `launchPlace`. Paper background (ink tokens), light-first —
the studio dark stays capture's own.

Top to bottom:

1. **Recovery banners** — if interrupted recordings exist, their banners sit at the
   top of Home. Banner only; the app never auto-jumps to capture (ruled: the jump is
   the old abruptness back).
2. **Face-out covers** — up to 3 journals as modest cover cards, tappable →
   that journal's library view.
3. **Spines** — every remaining journal as a tight vertical list: name only, bookish
   typographic treatment (serif/small-caps on paper, hairline separators — typography,
   not shelf art). Tap → journal library view.

   Mocked and owner-picked (2026-08-29, canvas
   https://claude.ai/code/artifact/e7f3285c-e0dd-4d39-949a-c49956c486f6): quiet
   serif list rows (New York, 17pt) with a small per-journal colored spine tick and
   chevron; the literal standing-shelf variant was considered and rejected. Corners
   run square-ish throughout: cover cards 8pt, New entry button 12pt (continuous),
   not pills.
4. **New entry** — one clear button → `.capture`. The single action on the screen.

### Ordering

Journals ranked by most recent capture activity: newest `createdAt` (capture date, not
`effectiveDate` — backdating an old entry must not reorder the shelf) among the
journal's entries, descending. Journals with no entries rank last. All ties broken by
the existing sidebar display order. First 3 of that ranking get covers; a journal
without a cover image still ranks normally (its card renders the existing
placeholder treatment).

### Edge cases

- ≤ 3 journals: all face-out, no spines section.
- No journals at all (fresh install — Lori): recovery banners if any, then the New
  entry invitation with one short line. Capture's existing no-journal/default-journal
  behavior is reused untouched.

### Deliberately omitted (v1)

No recent-entries strip, no stats, no greeting, no last-entry teaser. The "Last entry"
row stays on capture. If Home feels too spare in use, a recent-entries strip is a
clean later addition.

## Mechanics

- `Place.home` added to the enum; sidebar row **Home** above Capture, house-ish SF
  symbol; `PlaceRouting.launchPlace = .home` (SidebarView's selection initializer
  reads the same constant — stays in sync for free).
- Mac/iPad: Home is the first sidebar row and default selection; nothing else moves.
- **Recovery rehoming**: the interrupted-recording scan currently mounts from
  CaptureView's `.task { await model.bootstrap() }`. With Home as launch root that
  never runs until the user visits capture. The scan must run at launch regardless —
  per the standing rule, driven by model-owned observation, not a view's lifecycle.
  Home renders banner state from the capture model; tapping a banner routes to
  capture with that recovery active.
- No persistence of "last place viewed" — Home is the fixed landing, like capture was.

## Testing

- `testLaunchLandsDirectlyOnCaptureWithNoTaps` inverts: launch lands on Home, no taps.
- Cover/spine split at the 3 boundary (2, 3, 4 journals); activity ordering including
  the backdate-does-not-reorder case and the empty-journal-ranks-last case.
- Navigation: cover → journal, spine → journal, New entry → capture.
- Load-bearing: interrupted recording → banner appears on Home at launch; tap →
  capture with recovery active. (Recovery must not silently depend on visiting
  capture.)
- Fresh-install empty state renders the invitation, no crash on zero journals.
