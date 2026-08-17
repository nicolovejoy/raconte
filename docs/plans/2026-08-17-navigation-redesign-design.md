# Navigation redesign — one paradigm, addressable places

Date: 2026-08-17. Status: **owner-approved** (in-chat, same day — the paradigm, the map
of places, and both hack retirements were each ruled on explicitly). Supersedes the
implicit "capture is the permanently-mounted stack root" architecture. Cites are against
`m4/sync` @ `63651ac3` (identical to main for every file named here — verified during
the freeze investigation).

## 1. Problem

Owner verdict: "the whole navigation is broken" — specifically **"can't tell where I
am"** and **"the Mac feels wrong."** The code agrees:

- The entire app is one `NavigationStack` (`ContentView.swift:28`) with `CaptureView`
  permanently mounted as its root. There is **no path binding** — no programmatic
  push/pop, no deep links, no state restoration. `dismiss()` appears in exactly two
  places app-wide.
- Most "screens" are not screens. Arming/recording/receipt/recovery are boolean-gated
  branches of one 1,759-line `CaptureView.swift` switched by `CaptureLayoutModel`.
- **Reachability depends on capture phase**: the Debug button and the Library door exist
  only in the idle branch of the setup band (`CaptureView.swift:888-894`, `:1095-1120`).
  The owner failed to find the Library door twice; the Debug modal-trap incident
  (2026-08-17) is the same failure class.
- **Zero Mac idiom**: no `#if os(macOS)` anywhere in the navigation graph, no menu bar,
  no `Commands`, no keyboard route to anything, Esc works on exactly one screen.
- The Debug screen is a sheet with **no dismiss affordance**; macOS refuses ⌘Q while a
  sheet is up ("App termination blocked by modal sheet" ×4 in the unified log), which
  reads as a hard freeze. Structural fix belongs here, not in a patch.

## 2. Paradigm (the ruled synthesis)

**`NavigationSplitView` on both platforms, with Capture as the default sidebar
selection at launch.**

- **Mac**: a real sidebar app. Browse flows use the Mail idiom — sidebar / entry list /
  entry detail. Selecting **Capture** shows the capture surface across the full content
  area (dark, as today).
- **iPhone**: the same graph, collapsed to a stack. Because Capture is pre-selected,
  the phone still launches **directly into the capture screen** — instant-on preserved.
  The only visible change from today: a back chevron that reveals the places list.
- Navigation becomes **state** (sidebar selection + a path per column), so every screen
  is an addressable place. This is what fixes "can't tell where I am" at the root, and
  what makes "open the entry that just synced" possible later (M4).

Owner considered same-paradigm-everywhere vs capture-first-phone and ruled for this
synthesis on the explicit condition that the two load-bearing view-mount hacks are
**removed, not relocated** (§5).

## 3. Map of places

Sidebar (top level; on iPhone this is the collapsed root list):

1. **Capture** — default selection at launch on both platforms. While the coordinator
   is in a capturing phase, the row shows a live indicator (red dot + elapsed time) so
   a recording is never invisible from anywhere in the app.
2. **Journals** — one row per journal, cover thumbnail + name (owner approved
   rows-per-journal over a single Library item). Selecting one shows that journal's
   entry list (existing `LibraryView` machinery, journal-scoped).
3. **All Entries** — the current cross-journal Library.
4. **Trash** — the existing `TrashView`.
5. **Debug** — `#if DEBUG` only, bottom of the sidebar. A real place, not a modal:
   ⌘Q always works, no dismiss affordance needed, reachable in every capture phase.

Within the detail column, the existing pushes are unchanged in kind: entry list →
entry detail → transcript editor / Mark voices / revision history. All their
save-on-back contracts (back-is-Done, `onDisappear` flush, parent-reported save
failure) are preserved as-is (`EntryDetailView.swift:91-141`,
`TranscriptEditorView.swift:66-79`).

**What dissolves:** the toolbar Library button and the Library door
(`ContentView.swift:32-36`, `CaptureView.swift:1095-1120`) — the sidebar replaces
both. This retires the standing "library door visual pass" backlog item. The capture
screen's journal *picker* (which journal you record into) stays — that is capture
configuration, not navigation.

**The receipt** stays a mode of the Capture place, per the standing ruling (stays
until dismissed, never a timer). Change: it no longer hides the exits. Sidebar/back
affordances remain reachable while a receipt shows; the receipt can never trap the
user the way it hid the Library door.

## 4. Navigation state

- A `NavigationSplitView` with typed sidebar selection
  (`Place` enum: `.capture`, `.journal(id)`, `.allEntries`, `.trash`, `.debug`) and a
  real path binding for the detail column (`LibraryDestination` continues:
  `.entry(id)`, `.trash` folds into places).
- Launch always selects `.capture` (instant-on beats restoring a browse location; a
  future session may add restoration — structure permits it, nothing depends on it).
- The two-enum destination separation (`RootDestination` / `LibraryDestination`,
  `ContentView.swift:78-84`) is superseded by `Place` + one detail-column destination
  enum. The unresolvable-entry guard (`ContentUnavailableView`, `entry.unavailable`,
  issue #32) carries over verbatim.

## 5. Hack retirements (owner's condition — removed, not relocated)

1. **#62 receipt reconcile.** Today: `.onChange(of: model.library.allEntries)` on the
   always-mounted `CaptureView` (`CaptureView.swift:826-832`). New: the rule moves
   into the model layer — `LibraryScreenModel`'s rescan path notifies
   `CaptureScreenModel.reconcileReceipt()` directly (model-to-model, no view
   involved). "A receipt whose entry left the library is cleared" becomes a model
   invariant that holds regardless of what is mounted. The three existing #62 unit
   tests already pin the model behavior and must stay green; the deliberate
   restore-does-NOT-revive pin stays.
2. **iOS idle-timer hold.** Today: `onAppear`/`onDisappear`/`onChange` choreography on
   the capture view (`CaptureView.swift:833-854`). New: one scene-level rule at the
   app root — *coordinator phase is capturing ⇒ `isIdleTimerDisabled = true`* —
   observed off the model, independent of which screen is visible. Recording
   navigated-away-from keeps the screen awake, which the view-mount version only
   achieved by re-application.

**Recording survives navigation** — the coordinator already lives in
`CaptureScreenModel`, owned at the app root (`ContentView.swift:18-25`); unmounting
the capture view must not touch it. The sidebar's live indicator (§3) is the
visibility guarantee. A UI test pins: start recording → navigate to All Entries →
return → same recording still running, elapsed time advanced.

## 6. Debug place rework

Same harness, reshaped as a screen (`DebugMenuView.swift`):

- Build info (`BuildStamp.currentBuildDisplayString()`) promoted to the **top** — it
  is the row the owner actually visits.
- The nine transition-breakpoint toggles and the Kill-now button move **below**, under
  an explicit "Harness — can wedge or kill the app" section header. Fencing is
  presentational (a section boundary + warning label), not functional — it is a DEBUG
  screen.
- `BuildStamp` work runs off the main actor (`.task` already exists; make the call
  genuinely async). Not the freeze cause, fixed on principle.

## 7. Mac commands & keyboard (currently: none)

`Commands` on the `WindowGroup`:

- ⌘1–⌘5: select sidebar places (Capture, first journal group / All Entries, Trash,
  Debug per availability).
- Esc / ⌘[: back within the detail column (Esc must not fight the transcript editor's
  existing Esc-closes contract, `TranscriptEditorView.swift:60` — editor wins when
  focused).
- ⌘N: new journal.
- Standard menu bar so Mac reflexes (About, Quit, Window) behave.

## 8. Invariants preserved (any implementer/reviewer checks these)

1. **Color pins**: scoped `.environment(\.colorScheme, .dark)` sites stay exactly as
   scoped (`CaptureView.swift:1313, 1456, 1549, 1714, 1170`); `preferredColorScheme`
   remains forbidden anywhere in the capture subtree.
2. **Foreground-style resets** at every presentation boundary out of the capture
   surface (`CaptureView.swift:899, 1335, 1343, 1358, 1367, 1502`;
   `PrecisionDatePicker.swift:226-229`) — the white-on-white alert class.
3. **One `LibraryScreenModel` app-wide** (`ContentView.swift:6-8`; asserted
   `CaptureView.swift:165-166`). The sidebar and every list resolve entries through it.
4. **UI-test identifiers live on links, never on rows inside them**
   (`library.entryLink`, `capture.recentRow`); **no identifier on control-bar
   containers** (flattening trap, hit three times).
5. **Back-is-Done** semantics on editor / Mark voices / revision history stay
   push-based — converting any to a sheet changes the save contract.
6. **`EntryDetailView` keeps its own `item` copy** (`EntryDetailView.swift:10-15`) —
   journal reassignment must not blank a pushed detail.
7. Detail sub-models built once in `init`, never re-minted per body evaluation
   (`EntryDetailView.swift:27-47`).
8. The capture screen's internal content (bands, control bar, marker buttons, §53/§Option-B
   geometry and its `CaptureControlsUITests` pins) is **out of scope** — this design
   changes the frame around screens, not the screens.

## 9. Test strategy

- Pure model for place/selection logic (new `Place` routing model) — TDD, exhaustive
  switch, no `default`.
- The #62 model-invariant tests carry over and must pass against the model-to-model
  wiring with no view in the loop.
- UI tests: recording-survives-navigation (new, §5); every existing UI test that
  traverses `capture.libraryButton` / `capture.libraryDoor` reroutes through the
  sidebar — expect wide but mechanical fallout; identifiers for sidebar rows follow
  invariant 8.4.
- Mutation checks per repo convention; RED verified via git stash for view-wiring
  halves (repo memory: swiftui-verify-red-via-stash).

## 10. Out of scope

- Capture-screen internals (control bar, bands, receipt content) — unchanged.
- Journal management surface (rename/cover/labels stays in the capture journal menu
  for now; may later move to sidebar context menus).
- State restoration and real deep links (structure permits; nothing built).
- Multi-window Mac (`openWindow`) — the split view must not preclude it.
- M4 sync Tasks 6–12 (separate branch `m4/sync`; a merge of either branch will
  conflict in `ContentView.swift` — accepted, resolve at second merge).
