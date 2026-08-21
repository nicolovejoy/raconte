# Journal Order + Delete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Journals list in the same, stable order on every device and every surface (#79), and empty test journals can be deleted, with the deletion propagating over sync instead of resurrecting (#80).

**Architecture:** Phase A (#79) is mechanical: one pure display-order helper applied at every listing surface, plus a model-to-model observer so the capture picker tracks sync-adopted journals without relaunch. Phase B (#80) adds empty-journal deletion through all three layers — store (guarded remove), sync (outbound record deletion via the already-existing-but-unwired `enqueueDeletes`, plus the inbound deletion-ingest branch), UI (editor delete row) — with a non-empty-local-journal ignoring a remote delete rather than orphaning entries.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, CKSyncEngine (`Raconte/Sync/`).

**Spec:** Issues #79 and #80 (they carry the verified mechanism analysis, file:line, from 2026-08-21 @ `082e30e9`); `docs/plans/2026-08-17-m4-sync-design.md` for sync semantics. Owner questions below are pre-ruled with recommended defaults — confirm them at session start (numbered, answer by number) before dispatching Phase B.

## Owner questions (Phase B only — Phase A needs no rulings)

1. **v1 deletes only EMPTY journals** (zero entries, *including trashed ones*)? Recommended: yes — disposal of a non-empty journal's entries is undefined (the store's own comment warns orphans happen exactly here) and your stated need is empty test journals. Non-empty deletion becomes its own later design (relates to #35 friction tiers).
2. **Affordance = destructive "Delete Journal" row at the bottom of the journal editor, behind a confirmation dialog** (not a swipe on the sidebar)? Recommended: yes.
3. **Accepted v1 race:** a peer that edits the journal while offline *after* the delete re-pushes and resurrects it (last-writer semantics). Recommended: accept and document; the alternative (deletion tombstone records with their own LWW) is real work #80 can grow into if it ever bites.

## Global Constraints

- **Workspace:** ALL work in the worktree `/Users/nico/src/raconte-m4`, branch `m4/sync`. Never touch the main checkout.
- **Models:** Sonnet implementers AND Sonnet task reviews; Opus for the final gate only.
- **Run every test suite in the FOREGROUND.** Never background a build/test run — notifications never reach subagents; 10 prior implementers stalled that way. Never pipe xcodebuild through `head`.
- Unit suite: `xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=iOS Simulator,name=iPhone 17' test`. UI suite: scheme `RaconteUI`, same destination. macOS runs need `CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements`, never `CODE_SIGNING_ALLOWED=NO`.
- New test file ⇒ `xcodegen generate` first, or `-only-testing` silently passes with "Executed 0 tests".
- Baseline at `082e30e9`: 1555 unit / 43 UI, all green. Known laptop-local intermittent: `BuildStampTests.testLoadedImageUUIDFindsARealLoadedMachOImage` (macOS only).
- Commit messages reference issues as "for #79" / "for #80" — never a close-verb + number.
- **A background sync pull must never change the user's capture target or pop navigation.** (#67's class. `PlaceRouting.resolve` already handles a deleted journal's place; deletion is the one case where a forced `router.select` is CORRECT.)
- Stash note: `stash@{0}` on the worktree is inert SyncCoordinator scaffolding — leave it alone.

---

## Phase A — deterministic journal order (#79)

### Task A1: canonical display order everywhere

**Files:**
- Modify: `Raconte/Library/Journal.swift` (add the helper near `JournalRegistry`), `Raconte/App/Place.swift:51` (+ its doc comment at `:34`), `Raconte/Capture/UI/CaptureScreenModel.swift` (every site that assigns/patches its `journals` array: bootstrap `:739/:750`, `createJournal` `:432`, rename `:446`, labels `:463`), `Raconte/Library/LibraryScreenModel.swift:194` (rescan load path)
- Test: `RaconteTests/JournalOrderingTests.swift` (new), plus updating `RaconteTests/PlaceRoutingTests.swift:14-17` and `RaconteTests/JournalStoreTests.swift:55`

**Interfaces:**
- Produces: `extension Array where Element == Journal { var displayOrdered: [Journal] }` — sorted by `createdAt` ascending, ties broken by `id` ascending (ULID = creation-time order anyway). All later tasks and all UI surfaces list journals ONLY through this.

- [ ] **Step 1: Write the failing tests.** Core cases in `JournalOrderingTests`:
  - Interleaved histories converge: registry A built as [create J1, applySyncMerge-adopt J2] and registry B built as [create J2, applySyncMerge-adopt J1] produce IDENTICAL `displayOrdered` id sequences. (Advance the injected clock between mints — frozen-clock ties order by random ULID suffix and flakes.)
  - Tie on createdAt breaks by id, pinned with two journals minted at the same frozen instant.
  - `LibraryScreenModel` and `CaptureScreenModel` expose journals in display order after a rescan/bootstrap that stored them unsorted on disk (write a shuffled `journals.json` fixture).
- [ ] **Step 2: Run, confirm each fails for the stated reason** (helper missing / surfaces unsorted), not a compile error — add the helper stub first if needed so the assertions run.
- [ ] **Step 3: Implement.** The helper plus application at every site listed above. `Place.swift:34`'s "in registry order (locked)" doc comment is superseded by owner report 2026-08-21 — rewrite it to name display order and cite #79. Update `PlaceRoutingTests` to feed unsorted journals and expect ordered rows; keep `JournalStoreTests.swift:55` as-is (registry storage stays insertion-ordered — presentation sorts, storage does not; that separation is deliberate, do not sort `journals.json`).
- [ ] **Step 4: Full unit suite green.** Run UI suite too — sidebar row-order changes can shift what `openPlace` walks past.
- [ ] **Step 5: Commit** `feat: journals list in createdAt order on every surface (for #79)`.

### Task A2: capture picker tracks sync-adopted journals

**Files:**
- Modify: `Raconte/Capture/UI/CaptureScreenModel.swift` (the bootstrap-once `journals` copy at `:421-423`, `didBootstrap` at `:286`)
- Test: extend `RaconteTests/JournalCaptureContextTests.swift` (or sibling)

**Interfaces:**
- Consumes: `LibraryScreenModel.journals` (refreshed by sync via `SyncCoordinator.swift:120` → `library.rescan()`); the model-to-model observer precedent from the #62 receipt-reconcile work (see `CaptureScreenModel`'s existing observation wiring — the nav redesign moved exactly this kind of concern onto the model, never a view hook).

- [ ] **Step 1: Write the failing test:** adopt a new journal into the store via `applySyncMerge` and drive the library rescan; assert `CaptureScreenModel.journals` contains it (in display order) WITHOUT relaunch/re-bootstrap. Second assertion, the #67-class guard: the capture-selected journal (`currentJournal`) is UNCHANGED by the refresh; third: if the selected journal's *name* changed remotely, the picker label shows the new name.
- [ ] **Step 2: Confirm red for the right reason.**
- [ ] **Step 3: Implement** via the model's own observation of `library.journals` (withObservationTracking or the existing observer seam — mirror the receipt-reconcile pattern in this same file; never `.onChange` on a view). Re-resolve the journals list; keep selection by id; if the selected id has left the registry (deletion — Phase B makes this reachable), fall back through the existing `resolveCurrentJournal()` rules.
- [ ] **Step 4: Full unit suite green; UI suite green.**
- [ ] **Step 5: Commit** `fix: capture picker tracks the library's journals after sync ingest (for #79)`.

---

## Phase B — delete empty journals (#80) — confirm rulings 1-3 first

### Task B1: store-level guarded delete

**Files:**
- Modify: `Raconte/Library/Journal.swift` (`JournalRegistry.remove(id:)`), `Raconte/Library/JournalStore.swift` (replace the deletion-is-absent comment at `:191-192` with `deleteJournal(id:)`), `Raconte/Library/LibraryScreenModel.swift` (the emptiness check lives HERE — the store cannot see entries; check the journal has zero items AND zero trashed entries from the scan, then call the store), `Raconte/Library/JournalCoverStore.swift` (cover file cleanup)
- Test: `RaconteTests/JournalStoreTests.swift`, `RaconteTests/LibraryScreenModelTests.swift`

**Interfaces:**
- Produces: `JournalStore.deleteJournal(id:) async throws` — refuses (`JournalError`) when the id is unknown or it is the last remaining journal; removes from registry, deletes `journals/<id>/` cover dir, fires the sync delete hook (B2's `noteLocalDelete`). `LibraryScreenModel.deleteJournal(id:) async -> Bool` — the ONLY caller; enforces emptiness (items + trashed) before delegating, alerts on false like `trashEntry` does.

- [ ] **Step 1: Failing tests:** delete removes from registry + `journals.json` bytes; unknown id throws; last-journal refusal; emptiness guard refuses when the journal has a trashed entry (the orphan-on-restore case — name the test for it); cover file gone after delete.
- [ ] **Step 2: Red for the right reasons.**
- [ ] **Step 3: Implement.** Follow the store's setter shape (load → mutate → save → hook). Every mutator returns/throws honestly — no `_ = try?` (the #62 lesson).
- [ ] **Step 4: Suite green. Step 5: Commit** `feat: delete an empty journal — store guard, registry remove, cover cleanup (for #80)`.

### Task B2: sync propagation — outbound delete + inbound deletion ingest

**Files:**
- Modify: `Raconte/Sync/SyncCoordinator.swift` (a `noteLocalDelete` hook beside `noteLocalChange`), `Raconte/Sync/CloudEngineControl.swift` (wire the zero-caller `enqueueDeletes` at `:254`; implement the journal half of the ignored-deletions branch at `:296-300`), `Raconte/Sync/SyncIngest.swift` (deletion handler: remove the journal locally)
- Test: `RaconteTests/SyncJournalIngestTests.swift`, `RaconteTests/SyncCoordinatorTests.swift` (a spy for `enqueueDeletes` already exists at `:266`)

**Interfaces:**
- Consumes: B1's `deleteJournal` hook fire. Produces: a journal deleted on device A disappears on device B at its next fetch.

- [ ] **Step 1: Failing tests:** local delete enqueues the journal's record ID for deletion (spy); an inbound deletion for a journal id removes it from the registry; **an inbound deletion for a journal that is NOT empty locally is IGNORED and the journal re-pushed** (never orphan local entries to a remote delete — this is the load-bearing rule, mutation-check it: an implementation that deletes unconditionally must fail this test); inbound deletion for an unknown id is a no-op; deletion of the capture-selected journal re-points capture (A2's fallback path — assert through the model).
- [ ] **Step 2: Red. Step 3: Implement.** Entry/artifact deletions stay out of scope: the `:296-300` branch handles JOURNAL record names only and keeps ignoring the rest (Task 11 of the m4 plan still owns those) — say so in the comment.
- [ ] **Step 4: Suite green. Step 5: Commit** `feat: journal delete syncs — outbound record deletion, guarded inbound ingest (for #80)`.

### Task B3: UI — delete from the journal editor

**Files:**
- Modify: `Raconte/Library/UI/JournalEditorView.swift` (destructive row + `confirmationDialog`; disabled with an explanatory footnote when the journal has entries or is the last journal — a visible-but-refusing affordance, not an invisible one), navigation: deleting pops the editor and the journal's place (PlaceRouting.resolve's id-left-registry path — the one surviving forced `select`, per the #67 guard's own comment at `ContentView.swift:93-107`)
- Test: `RaconteUITests/JournalEditorUITests.swift`

- [ ] **Step 1: Failing UI test:** create an empty journal via sidebar `+`, delete it from the editor through the confirmation, assert the sidebar row is gone and navigation landed somewhere sane (not a blank detail). Second test: a journal WITH an entry shows the disabled affordance. Remember the `.sheet`-on-`Section` trap (attach dialogs to the outer view) and put accessibility identifiers on interactive elements, not containers.
- [ ] **Step 2: Red via the git-stash method if needed. Step 3: Implement. Step 4: Unit + UI suites green. Step 5: Commit** `feat: delete an empty journal from its editor (for #80)`.

### Task B4: Gate (OPUS)

- [ ] Re-run both suites independently, foreground; verbatim counts.
- [ ] Probes: (1) delete-then-sync round trip in tests — journal deleted locally does not resurrect after an ingest cycle that includes the peer's stale copy... verify what actually happens and document which rule saved it (the enqueueDeletes push racing the stale save is the interesting window); (2) mutation — remove the not-empty-locally guard from deletion ingest, the named test must fail; (3) A1 convergence test discriminates — reverse the sort, tests fail; (4) A2 — delete the observer wiring, the no-relaunch test fails; (5) sweep: any journal-listing surface added since #79's audit that bypasses `displayOrdered`.
- [ ] Triage the ledger's deferred minors. Verdict READY/BLOCKED; one fix wave max, then adjudicate.

## After the gate

Fresh signed builds for both devices (macOS: `~/Desktop/Raconte-m4sync.app` via ditto + dylib-UUID check; iPhone via `devicectl` wireless install — first attempt after reconnect may need the `device info details` tunnel-open retry). Owner smoke: delete a test journal on one device, watch it vanish from the other; confirm the journal lists now match everywhere.
