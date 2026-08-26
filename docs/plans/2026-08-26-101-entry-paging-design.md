# #101 — Next/previous entry paging on the detail screen (design)

2026-08-26. Issue: https://github.com/nicolovejoy/raconte/issues/101
Owner decisions taken live 2026-08-26; implementation intended for a later
(Sonnet-class) SDD session working from the companion plan.

## Problem

Reading a journal one entry at a time means backing out to the list and drilling back
in for every entry. From an open entry, the owner wants to move to the adjacent entry
without leaving the detail screen.

## Decisions (all owner-confirmed)

1. **Interaction: both swipe and buttons.** Horizontal swipe on iOS (platform idiom)
   plus always-visible chevron toolbar buttons on every platform; macOS adds menu
   commands with key equivalents.
2. **Ends: disable.** Previous is disabled on the first (newest) entry, Next on the
   last (oldest). No wrap, no bounce.
3. **All Entries: page the list you came from.** Paging follows whatever list the
   entry was opened from — All Entries pages across journal boundaries.
4. **Ordering: the list's own current order** (`EntryListItem.sortedByEffectiveDate`
   — effectiveDate descending, captureID-descending tie-break; deterministic, no
   coin-flips). Neighbors are computed from the LIVE `LibraryScreenModel.items` at
   render/tap time rather than a push-time snapshot: within a paging session with no
   data changes the order is identical, and when data DID change (entry deleted,
   backdate edited), the live order is the only truth that never navigates to a
   removed entry.
5. **Commit-before-page-turn: inherited, not rebuilt.** The page turn is expressed as
   navigation (below), so the departing screen's existing `onDisappear` safety nets
   (BackdateField-pattern double-commit, `playback?.stop()`) fire exactly as they do
   for a sidebar pop. No new commit machinery.

## Mechanism: replace the top of `detailPath`

The detail screen is pushed as `LibraryDestination.entry(id)` on
`AppRouter.detailPath`. A page turn REPLACES that top element:

```swift
// AppRouter
func replaceTopEntry(with captureID: String) {
    guard case .entry = detailPath.last else { return }
    detailPath[detailPath.count - 1] = .entry(captureID)
}
```

Why this and not an in-place `@State` swap inside `EntryDetailView`:

- `EntryDetailView` builds four sub-models once in `init`, keyed to `captureID`
  (its own doc comment explains why). Swapping state in place would strand them on
  the old entry.
- Navigation-expressed paging makes the old view genuinely disappear, so every
  existing on-disappear commit contract fires for free (decision 5).
- `ContentView`'s destination builder already degrades an unresolvable id to
  `ContentUnavailableView` (#32) — the deleted-neighbor race is pre-handled.
- The router owns the mutation, so the Mac menu command targets router+model like
  every existing command (no new plumbing into the pushed view).

**Identity hazard (the one sharp edge, must not be skipped):** replacing a path
element's value at the same depth does not reliably give the destination view a fresh
identity, and `EntryDetailView`'s `@State`/init-once models would go stale. The
destination builder therefore pins identity explicitly: `EntryDetailView(...)
.id(captureID)`. The paging UI test exists specifically to prove content actually
changes on a page turn.

## Scope gate: when paging renders at all

"The list you came from" is `LibraryScreenModel.items` under its current
`journalScope` — and any sidebar selection clears `detailPath`, so while a detail
screen is up, the model's scope IS the scope of the list it was entered from…
**except** for details pushed from the Capture place (recent-entry row, post-stop
receipt), where `PlaceRouting.journalScope` is nil and the model's scope is leftover
from some earlier place. Rule: paging controls render only when the CURRENT place has
a journal scope (`.allEntries` / `.journal`). Capture-pushed details show no paging.

An entry that has left its list's scope while open (journal reassignment — the
documented stale-`item` case) computes no neighbors: both buttons disable. Accepted.

## Pure core

```swift
enum PagingDirection { case previous, next }

enum EntryPager {
    // nil when captureID is absent from orderedIDs or the neighbor falls off either end
    static func neighborID(of: String, in orderedIDs: [String],
                           direction: PagingDirection) -> String?
    // The whole gate in one testable place: place must have a journalScope AND the
    // path top must be .entry. Used by the view (via its inputs) and the Mac commands.
    static func pagingTarget(place: Place, detailPath: [LibraryDestination],
                             orderedIDs: [String],
                             direction: PagingDirection) -> String?
}
```

`orderedIDs` is `model.items.map(\.captureID)` — newest first, so **previous = index-1
(toward newer/top), next = index+1 (toward older)**. Chevrons match the vertical list:
up = previous, down = next. Swipe matches page-turning: left = next, right = previous.

## Surfaces

- **Toolbar (all platforms):** `ToolbarItemGroup(placement: .primaryAction)` with
  chevron.up / chevron.down buttons, identifiers `detail.previousEntry` /
  `detail.nextEntry`, disabled per decision 2.
- **iOS swipe:** `.simultaneousGesture(DragGesture(minimumDistance: 30))` on the
  detail `ScrollView`, horizontal-dominance guard (`|dx| > 1.5·|dy|`).
  `simultaneousGesture` because a plain `.gesture` loses to the ScrollView's pan.
  **Simulator caveat (repo memory): device gestures and simulator gestures differ;
  the gesture is NOT UI-tested — buttons are the tested path, the swipe is
  owner-smoked on device.**
- **macOS Go menu:** "Previous Entry" ⌥⌘↑, "Next Entry" ⌥⌘↓, after Back. ⌥⌘
  deliberately: a menu shortcut beats the responder chain (the no-global-Esc lesson),
  and bare or ⌘-only arrows collide with text-editing bindings in any presented
  editor. Disabled via the same `pagingTarget` gate. Router-targeting via a small
  `AppServices` extension (`entryPagingTarget` / `pageEntry`).

## Known edges (accepted, recorded)

- Menu paging while the transcript editor sheet is presented (macOS) tears the editor
  down via the identity change; its `onDisappear` `finishIfNeeded()` flush commits
  first (same idempotent contract as any dismissal). Rare, safe, accepted.
- No paging from Trash (no detail push exists there) or Capture-pushed details
  (scope gate above).
- Replace-top does not animate directionally like a page curl; it re-renders the
  destination. Cosmetic; acceptable for v1.

## Testing

- Unit (TDD): `EntryPagerTests` — neighbor at middle/first/last, absent id, empty
  list; `pagingTarget` gating matrix (place without scope → nil even with a valid
  path; `.journalEditor` top → nil; empty path → nil; happy path → id). Router:
  `replaceTopEntry` replaces only an `.entry` top (no-op on empty path and on
  `.journalEditor` top). Commands: pure-half additions to `AppRouterCommandTests`.
- UI (simulator, buttons only): `EntryPagingUITests` using the existing
  `RACONTE_UITEST_SEED_MARKER_ENTRY` seed (three entries) — open the top entry from
  All Entries, Previous disabled; Next twice reaches the last entry, Next disabled;
  Previous re-enables. Order-agnostic assertions (position-based, not content-based).
- Device smoke (owner): swipe left/right pages on iPhone; ⌥⌘↑/⌥⌘↓ on Mac; backdate
  edit + immediate page-turn persists the edit.
