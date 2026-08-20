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

**The `modified` LWW map gains a `"span"` key**, joining `name` / `voiceLabels` / `cover` —
**but not on this branch.** `main` has no `Raconte/Sync/` and `Journal` on main has no
`modified` field at all; the whole sync layer lives only on `m4/sync`. See §"Branch split"
below: `span` lands on main without a stamp, and its sync wiring is a tripwire-enforced
task on `m4/sync`.

**Validation lives in the model**, like `JournalError.emptyName`: an inverted span (end
before start, compared at their coarsest common precision) is rejected, so the registry can
never hold one. `JournalDateRange.coarser` already does the precision math and should be
shared, not re-implemented — standing branch rule: call the shared primitive, never copy it.

## Display rules

- **Span set** → it is the journal's date line everywhere: sidebar row subtitle and
  journal header. (As built: this spec originally also named a "Library chip subtitle"
  as a third surface — that chip no longer exists. See As-built below.)
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
- **The unknown-key drop hazard** (§8) — filed as #70.
- **Any progress readout** beyond the editor's derived line.
- **The out-of-span flag itself** — cut from the build branch by the owner on 2026-08-18 and
  filed as **#71**. Ruling 4 above still stands and is unchanged; only its delivery moved.
  `JournalSpan.contains(_:)` still ships in the build branch, so #71 is purely the two
  surfaces (`LibraryEntryRow`, `EntryDetailView`).

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

## Branch split

`main` has no `Raconte/Sync/`, and `Journal` on main has no `modified` field. The sync layer
— `SyncIngest`, `SyncRecordBuilders`, `RemoteJournal`, `JournalMerge`, the LWW stamp map —
exists only on `m4/sync`. About 90% of this design needs none of it: the span type,
validation, `contains(_:)`, display precedence, the out-of-span flag, the journal header,
the editor, the sidebar `+` and the #69 picker fix are all pure core or UI, and depend on
**nav**, which is now on main.

Owner ruling: **build on main; wire sync separately, enforced by a tripwire.**

- **On main:** everything above. `Journal.span` lands with no `modified` key, because that
  field does not exist on this branch.
- **On `m4/sync`:** a `Mirror`-based field-count tripwire over `Journal`'s sync round-trip,
  modelled on the one `writeCapturedManifest` already carries (M2 T2.5, issue #7). **Written
  before the wiring**, so it is red first. Its job is to fail whenever `Journal` carries a
  field the sync layer does not, which means that when `m4/sync` merges main and picks up
  `span`, the suite goes red until `span` is wired through all six sync sites
  (`SyncJournalField`, `SyncRecordBuilders.journalRecord`, `RemoteJournal`,
  `RemoteJournal.init?(record:)`, `JournalMerge.adopted(remote:)`, `JournalMerge.merge`) and
  given its `modified["span"]` key.

This is what turns the two-branch split from the exact hazard #70 describes into a caught
error. See #70 for the probe results behind it.

## Sequencing

1. ~~Nico merges **PR #64** (nav) to main.~~ **Done 2026-08-18** — main at `20beecc7`;
   `nav/split-view` worktree, local branch and remote branch all deleted.
2. This work builds on main. **The capture-picker change is task 1**, so #69 dies early
   rather than riding to the end of the branch.
3. `m4/sync` takes main — with the `ContentView.onChange(of: journals)` guard, or a
   background CKSyncEngine journals pull pops the user out of whatever they are reading.
   `ContentView.swift` + `CLAUDE.md` conflict there (accepted, nav design §10). The
   tripwire task above lands on this branch.

Until step 2, #69 is live on `Raconte-m4sync.app` and m4 Gate A stays blocked. That is the
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

## As-built (2026-08-19)

All nine code tasks are built (unit 1319 → 1368, iOS UI 35 → 43; commits `a6fdbc03` ..
`fee194fe`). This section records where the build differed from the spec above, and why.

### "Library chip" was already gone before this branch started

The Display rules section named three span-display surfaces, including "Library chip
subtitle". That surface does not exist — the nav redesign folded journal selection into
`SidebarView` before this branch began; `LibraryView.swift`'s own header comment records
it: "nav T5 dropped the journal filter chips and the Trash link — both are sidebar places
now" (`Raconte/Library/UI/LibraryView.swift:15-16`). The real surfaces are the sidebar row
subtitle and the journal header (`JournalHeaderCard`), plus the editor's own two lines
(the stored span, editable, and the derived range, read-only). All of them read through
one function — `LibraryScreenModel.dateLine(forJournal:)` — which is the "one rule, one
place" the spec asked for, just with one fewer call site than planned.

### Editor field order: shipped wrong by one task, fixed by the next

The editor's field order is name → cover → span → voice labels → the read-only derived
line (`Raconte/Library/UI/JournalEditorView.swift:42-96`). Task 7 shipped span above
voice labels but below where cover was meant to land (cover did not exist yet). Its own
task review flagged the miss and assigned the fix to Task 8 rather than spending a fix
round on a one-line reorder, since Task 8 was about to edit the same `Form` to add the
cover section anyway. Task 8 landed all five fields in the documented order in one
commit. `JournalEditorSourceTests.testFieldsAppearInDesignOrder` now pins the order by
scanning the file, so a future edit that reorders a section fails loudly.

### `JournalError.invalidSpan`: added to satisfy an interface list, then deleted as dead code

Task 3 added `JournalError.invalidSpan` because the plan's interface list named it. Task
7 traced every possible caller and found none: both `JournalRegistry.setSpan` and
`JournalStore.setSpan` take an already-constructed `JournalSpan?`, so an inverted pair is
refused earlier — by `JournalSpan.init(start:end:)` throwing `JournalSpanError.inverted`,
a different type entirely, before a `JournalError` could ever apply. The case was deleted
rather than left unreachable and untested; `Journal.swift:94-100` records the reasoning
in place so nobody re-adds it later just to match an interface list. If a future editor
path ever mints spans by hand-assembling a value that bypasses `JournalSpan.init`, this
is the case that would need to come back.

### Decoder ruling: an inverted span found on disk decodes to `nil`, not a thrown error

`Journal.init(from:)` decodes the field as
`span = (try? container.decodeIfPresent(JournalSpan.self, forKey: .span)) ?? nil`
(`Journal.swift:59`). Because `JournalSpan.init(from:)` re-validates the same inversion
invariant the throwing initializer enforces, a structurally valid JSON object whose `end`
precedes its `start` throws from inside that same `decodeIfPresent` call — and `try?`
treats that identically to malformed JSON. Both are "a damaged span", and a damaged span
costs only the span: the three identity fields (`id`/`name`/`createdAt`) stay strict and
decode normally regardless, so one journal's corrupt span can never fail the whole
registry. This app cannot itself produce an inverted span on disk — `JournalSpanEditor`
only ever calls the throwing initializer — so this state is reachable only by external
file corruption (hand-editing `journals.json`, a bad sync merge, etc.), not by anything
the UI can do.

### #67 is very likely fixed here, ahead of the `m4/sync` merge that was supposed to fix it

Spec §"Branch split" named the `ContentView.onChange(of: journals)` guard as work for
`m4/sync` alone. It shipped on THIS branch instead, as a side effect of fixing a hazard
Task 9 found in its own feature (the sidebar `+`'s create-then-push-editor sequence was
losing its own push): `library.journals` changes on every rescan — creating a journal,
renaming one, setting a cover, setting a span — and `router.select` unconditionally
cleared `detailPath`, so ANY of those mutations popped whatever was pushed, including an
open editor mid-edit. Fixed by guarding the call
(`Raconte/App/ContentView.swift:108-113`):

```swift
.onChange(of: services.library.journals) { _, journals in
    let resolved = PlaceRouting.resolve(router.place, journals: journals)
    if resolved != router.place {
        router.select(resolved)
    }
}
```

`PlaceRouting.resolve` (`Raconte/App/Place.swift:135-142`) is an identity function for
every `Place` case except `.journal(id)` when that id has vanished from the registry, so
`resolved != router.place` can only be true in the genuine-deletion fallback — an
unrelated rename/cover/span/create now leaves `router.select` uncalled and `detailPath`
untouched. An independent task reviewer mutation-verified this both directions: reverting
the guard to the old unconditional call fails
`testRenamingFromTheOpenEditorDoesNotPopTheEditorItself` ("the editor was popped by its
own in-place rename"); restoring it passes.

This reads as a full fix for #67, not a partial one, but it was **not** closed by this
branch — an issue gets closed by a human confirming it, not inferred from a related fix
landing elsewhere. Whoever performs the `m4/sync` ← `main` merge should read
`ContentView.swift:95-113`'s comment before re-deriving this guard from scratch — it is
already there, already pinned, and the spec's own deferred-work list is now stale on this
one point.

### `JournalSpan` endpoints are units, not instants — and the first cut mishandled the edge

The spec's data-model section already states the underlying trap: `PartialDate` is
`Comparable` by `anchorDate`, which fills absent components with the FIRST, so "2001"
anchors to 1 Jan 2001 and a naive comparison would call everything after New Year's Day
2001 outside a "1998 – 2001" journal. The as-built fix (`Raconte/Library/JournalSpan.swift`)
expands `start` to the earliest instant of its precision's unit and treats `end` as an
**exclusive** upper bound — the first instant of the unit immediately *after* `end`'s —
with containment as `date >= lowerBound && date < exclusiveUpperBound`.

The first cut got this wrong in a way worth naming: it built an *inclusive* upper bound
by subtracting a fixed 1.0 second from the exclusive one, which excluded the final second
of every span (`23:59:59.000`–`23:59:59.999` of the true last day was wrongly outside a
year- or month-precision end bound). Fixed in the Task 2 review's fix round
(commit `6e62ce43`) by keeping `calendar.dateInterval(of:for:).end` untouched and switching
the comparison to strict `<`, plus edge-anchored tests (exact sub-second `DateComponents`
instants, not noon fixtures, since noon fixtures cannot discriminate an off-by-one).
Mutation-verified against three distinct regressions: restoring the subtraction, and
flipping either comparison direction — each caught by a different, correctly-reasoned
subset of the containment tests.

### A convention worth naming: write-through commit on a screen that can be popped without warning

`PlaceRouting.detailPath(afterSelecting:from:path:)` (`Place.swift:125-129`) always
returns `[]` — any sidebar click, and on the Mac any of ⌘1-4, pops whatever is on the
detail stack with no chance for that screen to intervene. `JournalEditorView` therefore
cannot hold a Done-button-shaped batch of unsaved edits (the same discipline
`BackdateField`/`BackdateEditorContent` already used for exactly this reason). Each field
commits itself on **two** deliberately redundant triggers:

- **Losing focus** (`onChange` of a `FocusState`, or a picker/toggle's own `onChange`) —
  the ordinary case, fires the instant a real tap moves elsewhere on the same screen.
- **`onDisappear`**, via an **unstructured `Task {}`, never `.task`** (SwiftUI cancels
  `.task` on disappear) — the safety net for the case this screen exists to guard
  against: the screen is torn down by a sidebar/⌘-place switch before any focus-loss
  event has a chance to fire. Same shape that let a transcript-editor draft survive its
  entry being popped from underneath it (nav branch, Gate B).

This shipped as a one-off justified by a comment on `JournalEditorView`
(`Raconte/Library/UI/JournalEditorView.swift:9-21`). It is really a general answer to
"how does a pushed, always-editing screen behave under a routing layer that can pop it
unconditionally at any time" — any future screen with the same shape (pushed, not
sheeted, no Done button, sitting under `PlaceRouting`) should reach for the same two
triggers rather than re-deriving them.

### Two SwiftUI/XCUITest traps found on this branch

**A `.sheet` attached to a `Form`'s `Section` silently never presents, on iOS 26.** The
plan's own code sketch attached `JournalCoverPickerSheet`'s `.sheet(isPresented:)`
directly to `Section("Cover")`; built exactly as sketched, tapping "Add a cover photo…"
did nothing observable — no sheet, no navigation bar, confirmed with a live accessibility
tree dump. Moving the identical modifier to the enclosing `Form` fixed it immediately,
verified by re-running the same UI test. **The mechanism was never pinned** — the task
reviewer checked for state-ownership or stale-binding explanations (the `@State` binding
is the same value in both positions) and found none, but nobody traced this into
SwiftUI's internals. Treat it as an observed behaviour with a reproduction, not an
explanation: attach `.sheet`/`.fullScreenCover` to a screen's outer view, never to a
`Form` child.

**`.tap()` on a `Toggle` inside a `Form` hits the merged label+switch accessibility
frame's centre — which for a full-width row is the label, not the switch — so the tap
never registers.** Confirmed by probing every layer down to a bare `Toggle` with nothing
else on screen and reading its accessibility `value` directly after a synthesized tap
(stayed `"0"`). This is an XCUITest-harness gap, not a production defect: a real finger
tap anywhere on a Settings-style `Form` row does flip the control. Worked around with a
trailing-edge coordinate tap (`coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy:
0.5))`, where the switch actually renders) — validated on iPhone 17 simulator only, so
the hardcoded normalized offset is fragile for a wider row (iPad) and would need
re-tuning if iPad UI coverage is ever added.
