# Bulk select: trash, move, restore and delete several entries at once

Issue: #128

Owner request 2026-08-30: *"bulk delete of entries for a test folder. really helpful.
select a few, delete (or move, or what not)"*. Shape ratified the same session:
multi-select with bulk actions, in the entry lists **and** in Trash.

## Why Trash is in scope

Bulk-trashing twenty test entries and then clearing them one at a time moves the tedium
rather than removing it. The round trip has to be bulk at both ends.

## What already exists

The risky half is built and tested — do not reimplement it.

- `LibraryScreenModel.trashEntry(_:now:)`, `restoreEntry(_:)`,
  `deleteEntryPermanently(_:)`, `moveEntry(_:toJournal:)` — all single-entry, async,
  returning `Bool`.
- `emptyTrash() -> EmptyTrashResult` (`:962`) already loops a destructive operation and
  reports `(deleted, failed)`. **This is the partial-failure pattern to follow**, not one
  to invent.
- `LibraryView` has swipe-to-trash, `pendingTrashCaptureID` / `pendingMoveCaptureID`
  confirmation state, and `journalChoices(for:)` — the move destination list is already
  computed; reuse it.
- `TrashView` has per-row Restore / Delete Now and a whole-trash "Empty Trash".

## The one non-obvious problem

**`trashEntry` and `moveEntry` each call `await rescan()` before returning.** A bulk loop
over them rescans the whole library once per entry. Every bulk operation must call a
core that does not rescan, and rescan exactly once at the end. `emptyTrash` already works
this way — copy its structure.

`moveEntry` also calls `promoteProvisionalDefaultAfterEntrySave` per entry. It is
idempotent (its own doc says so), and a bulk move targets ONE journal, so call it once
after the loop, not N times.

## Design decisions

**Selection state lives on the view, not the model.** A `@State Set<String>` of capture
ids. This is the deliberate inverse of the capture-screen invariant: selection *should*
die when you navigate away. Nothing about it must survive the view.

**Selection is by capture id, so it spans the year/month grouping for free.** The list is
grouped, the selection is flat.

**Mode is explicit.** A "Select" toolbar button enters it; "Done" leaves it and clears the
selection. In select mode a row tap toggles that row instead of opening the entry.

Tapping the whole row — not a checkbox — is also how this dodges a known repo trap:
`.tap()` on a toggle inside a `List` hits the row's merged label frame at its centre,
which for a full-width row is the label, not the control, so the tap silently does
nothing in XCUITest.

**Bulk trash confirms, naming the count** ("Move 7 entries to Trash?"). This deliberately
diverges from #83's direction for single-swipe trash. A seven-entry action is not a
one-entry action, and the count in the prompt is what makes a mis-selection visible before
it lands. Bulk Delete Now confirms too — that one is not recoverable.

**Partial failure is reported, never swallowed.** Each bulk operation returns
`(succeeded, failed)` like `EmptyTrashResult`. When `failed > 0`, an alert states both
counts, **and the failed ids stay selected** so the owner can retry or investigate exactly
those. A bulk operation must never report plain success when some entries did not move.
(#81 is a live example of a single corrupt `entry.json` blocking an operation.)

**"Select All" applies to what is currently on screen** — the active journal scope and
filter — not to every entry in the archive.

## Tasks

### Task 1 — `BulkSelection`, pure

New `Raconte/Library/BulkSelection.swift`: a value type over `Set<String>` with
`toggle`, `selectAll(_:)`, `clear`, `isSelected`, `count`, `isEmpty`, and an
`isActive` mode flag. No I/O, no SwiftUI.

Tests: `RaconteTests/BulkSelectionTests.swift`. Cover at least two ids (a one-element
fixture cannot catch an operation that ignores its argument), toggling the same id twice,
select-all over a list that partially overlaps an existing selection, and clear.

### Task 2 — bulk operations on `LibraryScreenModel`

Extract the non-rescanning core of `trashEntry`, `restoreEntry` and `moveEntry` (keep the
existing public functions working exactly as they do now — they are called from several
places). Add:

- `bulkTrash(_ ids: [String], now: Date = Date()) async -> BulkResult`
- `bulkRestore(_ ids: [String]) async -> BulkResult`
- `bulkMove(_ ids: [String], toJournal: String?) async -> BulkResult`
- `bulkDeletePermanently(_ ids: [String]) async -> BulkResult`

`BulkResult` carries `succeeded: Int`, `failed: [String]` — the ids, not just a count, so
the view can keep them selected. One `rescan()` after the loop in each.

`bulkDeletePermanently` must keep `deleteEntryPermanently`'s re-read-and-refuse rule: it
re-reads each sidecar and refuses unless it still says trashed. Do not shortcut it because
the caller "already knows" — the row is a snapshot.

Tests: `RaconteTests/BulkOperationsTests.swift`. **The partial-failure test must actually
make some entries fail** — inject a store that throws for specific ids — and assert both
that the good ones landed and that `failed` names exactly the bad ones. A fixture where
everything succeeds does not test this and will pass without exercising the code. Also
assert the rescan count is 1, not N; that is the whole point of Task 2.

### Task 3 — select mode in `LibraryView`

Toolbar "Select" / "Done". In select mode: rows show selection state, a row tap toggles,
navigation is suppressed, swipe actions are suppressed, and a bottom bar shows
"n selected" with **Move…** and **Trash**. Move reuses `journalChoices`.

Identifiers: `library.select`, `library.selectDone`, `library.selectAll`,
`library.bulkMove`, `library.bulkTrash`, `library.selectionCount`. Put them on leaf
controls only — a container identifier flattens its descendants and makes them
unqueryable, which has bitten this repo three times.

### Task 4 — select mode in `TrashView`

Same mode, actions **Restore** and **Delete Now**. Leave the existing whole-trash "Empty
Trash" alone. Identifiers `trash.select`, `trash.bulkRestore`, `trash.bulkDeleteNow`.

### Task 5 — UI tests and the macOS pass

`RaconteUITests/BulkSelectUITests.swift`: enter select mode, select two entries, trash
them, assert both are gone from the list and present in Trash; then bulk-restore them.

Reach screens with `openPlace(app, "sidebar.…")` — never hard-code a navigation tap.
Verify on macOS too; the bottom action bar is the part most likely to differ.

## Traps

- **A new test file does not run until `xcodegen generate`** — *locally*. The suite reports
  green at the OLD count. Check the executed count went UP; exit code 0 proves nothing.
  **This is a local trap only:** both CI jobs install a pinned XcodeGen and run
  `xcodegen generate` themselves, and `project.yml` sources by directory
  (`sources: [RaconteTests]`), so a file added in a PR is picked up on CI automatically
  (verified 2026-08-30). An agent without a Swift toolchain can still land this correctly —
  read the executed count off CI rather than skipping the check.
- **The `RaconteUI` suite exceeds a 10-minute command cap.** Split by class with
  `-only-testing`, foreground only. Never background it.
- macOS unit tests use the `Raconte-nocloud.entitlements` override. Never
  `CODE_SIGNING_ALLOWED=NO` — that unsandboxes app-hosted tests onto the real archive.
- Do not change `trashEntry` / `moveEntry` / `restoreEntry` signatures. Several callers
  depend on them, including the capture screen and the detail screen.

## Out of scope

- Changing single-swipe trash confirmation (#83).
- Bulk edit of anything other than journal membership and trash state.
- Selecting across Trash and the entry lists simultaneously — they are separate screens
  with separate selections.
