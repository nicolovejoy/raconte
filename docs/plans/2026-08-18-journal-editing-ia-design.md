# Journal editing IA — design

Date: 2026-08-18
Status: approved by owner, unbuilt

## Origin

Two problems arrived together.

**The bug.** On macOS, once a journal has a cover photo, its capture screen renders the
cover full-bleed behind the whole setup region and the journal picker stops working —
you cannot select a different journal. Filed as **#69**, root cause proven this session
(see §9). The picker's cover thumbnail lives inside a `Menu` label, and on macOS a `Menu`
label discards SwiftUI's sizing of a resizable `Image` and paints it at intrinsic size.

**The design complaint.** Owner, on being shown the fix options:

> it strikes me that editing the name and image and so forth for journals doesn't
> necessarily belong naturally in the journal picker for the capture screen. I think the
> Journal picker should just be built for purpose and maybe include create new journal.
> But there should be an interface where we edit a journal and that's where we add the
> image or edit the name and so forth the dates. And that should probably be right off of
> the list of journals page I would think, not on the current capture screen.

He is right, and the bug is a symptom of it: the capture header's cover is decoration
welded into a control, on a screen where the only question is *which journal am I
recording into* — a question the name already answers. Moving journal editing to its own
surface removes the broken construct as a side effect.

## Owner rulings

1. **Sequencing:** merge PR #64 (nav) first, then build this against the nav sidebar.
   Not a surgical fix now. m4 Gate A stays blocked in the meantime; accepted.
2. **Journal date range is stored, not just derived.** A half-transcribed 1998 journal
   must not advertise itself as an Aug 2026 journal.
3. **Stored wins when set; derived is the fallback.** Not a union — a union silently
   invents a span nobody typed and hides the disagreement.
4. **A date conflict is flagged, never blocked.** An entry whose date falls outside its
   journal's span is marked as such, and otherwise behaves normally.
5. **The journal gets a header on its entries screen**, cover at a real size, tapping
   through to the editor. Not a toolbar-only button, not a context menu.
6. **The capture picker keeps "New Journal…"** — you meet a new paper journal at the
   moment you sit down to read it. Renaming one, or finally photographing its cover, is
   housekeeping for later.
7. **The journals list also gets a `+`** which creates a journal and pushes straight into
   the editor — the one path where you have the metadata to hand.
8. **Leave room for more journal-level metadata.**
9. **Losing cover-setting for part of this process is acceptable** (owner: only a couple
   dozen entries exist so far, no images of concern; he is waiting on a working system
   before ingesting the paper journals). So #68 need not block; it sequences after.

## Data model

`Journal` gains one optional field:

```swift
/// The span the PAPER journal covers, as its owner knows it — independent of how much of
/// it has been read in so far. Nil means "we only know what has been recorded."
struct JournalSpan: Codable, Sendable, Equatable, Hashable {
    var start: PartialDate
    var end: PartialDate?     // nil = open-ended: a journal still being written
}

var span: JournalSpan?
```

**`PartialDate`, never `Date`.** Same reasoning that forced backdates onto `PartialDate`
in #14: a year-only value stored as a `Date` re-derives a different year after a westward
timezone change. "1998", "Mar 1998" and "4 Mar 1998" are all expressible, and `PartialDate`
is already `Comparable` and `Codable`.

**Decoding is additive and lenient** (`decodeIfPresent`, garbage → `nil`), **encoded only
when non-nil**, so every registry on disk today keeps producing byte-identical output.
This is the `voiceLabels` / `modified` precedent in `Journal.swift` exactly, and the house
decoder rule from M2 design §11 (Swift's synthesized decoder ignores property defaults, so
additive fields must be hand-decoded).

**The `modified` LWW map gains a `"span"` key**, joining `name` / `voiceLabels` / `cover`.

**Validation lives in the model**, like `JournalError.emptyName`: an inverted span (end
before start, compared at their coarsest common precision) is rejected, so the registry can
never hold one. `JournalDateRange.coarser` already does the precision math and should be
shared, not re-implemented — standing branch rule: call the shared primitive, never copy it.

## Display rules

- **Span set** → it is the journal's date line everywhere: sidebar row subtitle, Library
  chip subtitle, journal header.
- **Span nil** → today's derived `JournalDateRange`, unchanged.
- **The editor is the one place that shows both** — the stored span (editable) and a
  read-only line giving the derived range and entry count, so "what is actually in here"
  is visible where you would go looking for it, without adding a second date string to
  every row in the app.

A richer "progress" readout ("1998–2001 · 24 entries, Mar–Aug 1998 read") was considered
and deferred, not precluded.

## Out-of-span flag

A pure, precision-aware `JournalSpan.contains(_ date: PartialDate) -> Bool`, surfaced as a
marker on the entry — in the journal's entry list and on the entry detail screen.

- Only when the journal **has** a span. No span means no claim, so no conflict.
- **Never blocks.** The entry saves, files, syncs and renders normally. Consistent with how
  this app treats every other degraded state: say what is true, refuse nothing.

## Surfaces

**1. Capture screen picker** — `JournalHeaderView`, `CaptureView.swift:1251-1296`.
The `Menu` label becomes name + chevron, no cover. Menu contents: the journals, plus
"New Journal…". Rename / Cover Photo / Voice Labels are removed. **This is what
structurally fixes #69** — no `Image` remains inside a macOS `Menu` label.

**2. Journal header on the entries screen.** Selecting a journal row shows the journal
itself above its entries: cover, name, span, entry count. **The header itself is the
affordance** — tapping it opens the editor (ruling 5), rather than a separate Edit button.
This is also where the cover finally earns its space: you want to see it when choosing or
reviewing a journal, not while recording into one. Exact cover size is a plan-level
decision, but it must be large enough to recognise the photograph — the 34 pt crop it
replaces is the thing that was not working.

**3. Journal editor** — a pushed screen, not a sheet. Name, cover (set / replace / remove),
span (start + optional end at `PartialDate` precision), voice labels, and a read-only line
showing the derived range + entry count.

Pushed rather than presented because it holds enough to make a sheet cramped, and because
this project has had repeated trouble with sheets on macOS: #68's empty picker, the Debug
modal trap (no dismiss affordance, ⌘Q refused while a sheet is up), and the backdate sheet
that had to become a popover before Escape and click-away worked.

**4. Journals list `+`** — creates a journal, then pushes into the editor.

"The journals list" is the **nav sidebar** after PR #64 (`SidebarView.swift`), where
journals are already first-class rows carrying a cover thumbnail and a date-range subtitle.
The `+` belongs in the sidebar's own toolbar, not as a row in the places list — a row would
sit among Capture / All Entries / Trash / Debug, which are destinations, and this is an
action. Note this is a second creation path alongside the capture picker's "New Journal…"
(ruling 6) and the existing ⌘N; all three must converge on one model call, not three.

## Scope boundaries

Not in this work:

- **Journal delete** — #35 has its own friction design (easy / confirm / locked).
- **Backfilling spans onto existing journals** — they stay nil and show the derived range,
  exactly as today.
- **The unknown-key drop hazard** (§8) — files as its own issue.
- **Any progress readout** beyond the editor's derived line.

Folded in while the picker is already open:

- **#65** — `capture.journalPicker`'s accessibility identifier is invisible because the
  container identifier overwrites it. That control is being rebuilt anyway.

Sequenced after, not blocking (ruling 9):

- **#68** — the macOS cover picker sheet renders empty. Once Cover Photo leaves the capture
  menu the editor is the only cover path, so until #68 is fixed **macOS cannot set a cover
  at all.** Owner has accepted that gap.

## Risks and open issues

**Unknown keys are dropped, not preserved.** `Journal`'s decoder ignores unknown keys, so a
build that does not know about `span` silently drops it when it re-encodes that journal.
Harmless today. Under M4 sync, with two devices on different builds, it becomes a real
lost-update: the phone writes a span, the laptop's older build rewrites the journal for an
unrelated reason, the span is gone. Pre-existing — `voiceLabels` has the same exposure —
so it is not fixed here, but it should be filed, and it worsens with every field added to
this record (ruling 8 makes that a certainty).

**The #69 fix cannot be pinned by a UI test.** The bug is macOS-only, and this project
cannot run macOS UI tests (they need interactive automation permission; the suite is
simulator-only per the Commands section). The honest pin is a source-scanning test
asserting no `JournalCoverThumbnail` is constructed inside `JournalHeaderView`'s `Menu`
label, reusing the `strippingComments` helper in `RaconteTests/SourceScanning.swift` — a
naive grep over this repo's prose would be satisfied by the comment explaining the fix.
That is weaker than a frame assertion, and is recorded as such rather than dressed up.

## Testing

Pure core, TDD red-first:

- span validation (inverted rejection at coarsest common precision)
- `JournalSpan.contains(_:)` across precision combinations
- display precedence (span wins; derived fallback)
- out-of-span detection
- decoder leniency (absent / garbage → nil, identity fields still strict)
- byte-identical encoding for untouched registries

View wiring follows this repo's convention: unit-untestable, RED verified by stashing the
production files and running the new UI tests against the stashed-out code.

## Sequencing

1. Nico merges **PR #64** (nav) to main.
2. `m4/sync` takes main — with the `ContentView.onChange(of: journals)` guard, or a
   background CKSyncEngine journals pull pops the user out of whatever they are reading.
   `ContentView.swift` + `CLAUDE.md` conflict there (accepted, nav design §10).
3. This work builds on main. **The capture-picker change is task 1**, so #69 dies early
   rather than riding to the end of the branch.

Until step 3, #69 is live on `Raconte-m4sync.app` and m4 Gate A stays blocked. That is the
accepted cost of ruling 1.

## Appendix — #69 root cause evidence

A standalone six-variant SwiftUI harness on macOS 26.6, using a real 768×1024 cover from
the container, in the same near-black `ScrollView` / `VStack(spacing: 28)` / `.padding(24)`
shell as `setupRegion`:

- **A** — thumbnail inside `Menu` label (production shape): **BROKEN**, full-bleed image,
  name + chevron displaced out of the window
- **B** — identical `HStack`, no `Menu` wrapper: correct, 34 pt
- **C** — thumbnail outside the `Menu`, label is text + chevron: **correct**
- **D** — thumbnail inside a `Button` label (`LibraryView.swift:185` chip shape; also the
  nav sidebar row shape): correct, 30 pt
- **E** — thumbnail rebuilt to report no intrinsic size upward (`Color.clear.frame(...)`
  + `.overlay(image)`): **STILL BROKEN**
- **F** — production shape + `.menuStyle(.button)`: **STILL BROKEN**

E and F are the load-bearing results: **there is no in-place clamp and no menu style that
fixes this.** The image must leave the `Menu` label — which is what §"Surfaces" item 1
does. The harness was throwaway; it is not kept in the repo.

Same class as the `DatePicker(.compact)` popover this project hit twice: the system draws
the control, and our modifiers do not reach inside it.
