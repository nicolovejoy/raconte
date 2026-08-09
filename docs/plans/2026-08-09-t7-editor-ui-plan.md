# T7 — transcript editor UI (implementation plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> Every task: red-first evidence or a mutation check is REQUIRED in the completion report.

**Drafted against unmerged PR #45** (branch `t6/revision-chain`, HEAD `d4fe63f9`, read from
the worktree `/Users/nico/src/raconte-t6`). Every `file:line` below cites **that worktree**,
not `main`. **Re-verify all cites after PR #45 merges** — and before dispatching Task 1,
run the same check the T6 build ran: if a cite disagrees with the code, the code wins and
the disagreement gets written back here.

**Goal:** the editor. Read the current transcript, change it, and have the change land as a
new human revision through the T6 machinery that already exists — plus the four things the
project ledger attached to T7: marker correction, the §7 audit log, typed-word correction
(#37), and keyboard-first editing on iPad/Mac. Plus the prerequisites T6's Gate B parked
(#39/#40/#41) and the rendering minors the voice-attribution build left behind.

**Specs:**
- `docs/plans/2026-08-03-t6-revision-chain-design.md` — §2.5 (drafts), §3.3 (splice), §4.8
  (read-only), §6 (merge/accept/decline/revert), §7 (audit log — T7 builds it), §12 (owner
  decisions), **§15 + §15b (as-built rulings — these supersede the sections they name)**.
- `docs/plans/2026-08-08-revision-chain-implementation-plan.md` — what T6a–e built.
- `docs/plans/2026-08-08-revision-chain-code-maps.md` — pre-T6 citation authority; still
  correct for everything outside `Raconte/Transcription/`.
- `docs/plans/2026-08-08-voice-attributed-rendering-plan.md` — shipped rendering; its
  hazards list still governs anything touching `markers.jsonl`.
- `docs/plans/2026-08-08-capture-landing-decisions.md` §1 — the keyboard-first note.
- Issues #37, #39, #40, #41.

**Tech stack:** Swift 6 strict concurrency, XCTest, XcodeGen (`xcodegen generate` after
adding files — sources are directory globs, no `project.yml` edit). Suite baseline **930
unit tests** on the T6 branch; re-baseline against `main` after the merge.

---

## 0. What already exists (do not rebuild it)

The whole write path is built and tested. T7 is a caller, plus one new writer
(`entry-log.jsonl`) that lives outside the chain.

Store (`/Users/nico/src/raconte-t6/Raconte/Transcription/TranscriptRevisionStore.swift`):

- `listing(captureDirectory:)` :76 — three answers, never collapses to `[]`.
- `loadChain(captureDirectory:)` :107 → `ChainLoad(revisions:unreadableFiles:listingUnreadable:)`.
- `validatedHead(captureDirectory:)` :234 — the O(1) scan cache. **Zero production readers today.**
- `persistHead(captureID:)` :270 — the only head writer; silent no-op on a missing capture (§15.4).
- `append(_:captureID:)` :312 — create-once; never throws after the revision file is durable (§15.6).
- `writeDraft(captureID:text:now:)` :460 — atomic `draft.json`; snapshots `parentID`/
  `basedOnMachineID`/`openedAt` atomically (§15b.14); refuses on a degraded chain (§15b.15).
- `closeDraft(captureID:reason:now:)` :518 — no-op when `text == current`'s text (F7);
  otherwise splices against **`draft.parentID`'s** revision (§15b.12) and mints `.userEdit`.
- `closeStaleDrafts(now:)` :570 — **no caller** (#41.1).
- `promoteIfNeeded` :623 / `promoteCorpus` :702 — wired at finalize (`CaptureView.swift:469`),
  launch (`CaptureView.swift:229` → `LibraryScreenModel.promoteCorpusOnce()` :366) and
  entry-open (`EntryDetailView.refresh()` :92, promote-after-first-read).

Pure cores: `TranscriptChain` (ordered / humanTip / ancestry / isAttached / current /
forkedHumanLineage / plainText), `TranscriptSplice.spans(parent:editedText:)`
(`TranscriptSplice.swift:41`), `TranscriptMerge.accept` :20 / `.decline` :33 / `.revert` :43 /
`.degradingOverlaps` :60 — **all four with no caller** (#41.2).

Read path: `EntryTranscriptLoader.load` (`Raconte/Library/EntryTranscript.swift:79`) prefers
the chain's `current` and falls through to `live.jsonl`; `EntryDegradation.revisionUnreadable`
(`EntryListItem.swift:46`) is the §4.8 read-only signal;
`EntryDetailView.transcriptDisplay` :255 is the pure rendering decision.

### Five facts found in the T6 code that the ledger's T7 assumptions do not carry

Read these before planning any task; three of them change scope.

1. **Voice rendering switches itself off at the first human revision.**
   `EntryTranscript.swift:120` computes paragraphs only when `current.source == .machineLive`.
   That was the correct T6 call (attributing `markers.jsonl` over post-edit text would label
   stale words), but it means **the editor's first save silently deletes the BN/LN
   rendering** from an entry that had it. Task 5 exists because of this; shipping the editor
   without it is a user-visible regression on the owner's primary use case.
2. **The read path carries no revision identity.** `EntryTranscript` is
   `(state, text, degradations, paragraphs)` — no revision id, no chain listing, no
   draft-present flag, no read-only flag beyond the degradation bit. The editor cannot
   open, save, or show history off today's loader. Task 2 adds a second read.
3. **There is no per-capture stale-draft close.** `closeStaleDrafts(now:)` :570 walks the
   whole captures root with synchronous IO on the actor. #41 says to wire it at "launch +
   entry-open"; the entry-open call site needs a per-capture variant, not a corpus walk.
   Task 1 adds it.
4. **`TranscriptRevisionStore` has no merge glue.** The T6 plan's "`func apply(_ merge:…)`
   is just `append()`" was never written; a merge caller calls `append` directly. Fine —
   but the machine-lineage precondition #41.2 demands has nowhere to live yet. Task 1 puts
   it in `TranscriptMerge` itself, where it cannot be bypassed by a second caller.
5. **§7.2's bypass is still open.** `EntryMetadataStore.write(_:captureID:)`
   (`Raconte/Library/EntryMetadataStore.swift:51`) is still non-private, and the static
   `write(_:url:)` :101 is still the sanctioned seam. §7.2 assigns closing the instance one
   to T6/T7; T6 did not. Task 7 does.

---

## 1. Decisions locked here (implementers do not re-litigate)

1. **Whole-revision accept, whole-text edit** — owner §12.6. No per-hunk merge UI, no
   in-editor diff view. `degradingOverlaps` stays uncalled and tested.
2. **The editor edits the flattened text of `current`** (`TranscriptChain.plainText`) and
   hands it back as one string to `writeDraft`. Everything else — anchors, span structure,
   `sourceRevisionID` — is `TranscriptSplice`'s job and must not be second-guessed in the UI.
   (Whether the *presentation* is one text view or per-paragraph views is owner Q2; the
   store contract is one string either way.)
3. **The 2 s debounce is the editor's**, per §12.1: keystrokes → 2 s quiet → `writeDraft`.
   The 90 s / 60 min rules are the store's and already built. Never call `writeDraft` per
   keystroke — see #40.2.
4. **`entry-log.jsonl` is local-only, unsynced, and dies with the entry** (§7, D4). It never
   fails the write it audits (§7.2). No `seq`. No `deviceID`.
5. **Raw taps are never modified** (markers design). Whatever marker correction ships, it is
   additive to `markers.jsonl` or a sibling file — never an edit of an existing record.
   The *shape* is owner Q3.
6. **The read path never writes** (design rule 9). The editor's open path may write (it is a
   user action, not a read), but nothing on the scan/render path may — including anything
   Task 3 adds for #40.
7. **Refuse, don't degrade, on a damaged chain.** §15b.15 already makes the write half
   refuse; T7 owns the read half — a chain with any unreadable revision opens **read-only
   with a stated reason**, never as an editable text box over partial text.
8. **Never write "fixes #N" as prose in a commit message** (GitHub closes it on merge).

---

## 2. Tasks

Ordering rationale: prerequisites and read model first (Tasks 1–3), then the editor itself
behind Gate A (Tasks 4–6), then the audit log and history panel (7–8), then the parked
minors (9).

---

### Task 1 — #41 prerequisites: stale-draft wiring + merge guards

Small, mechanical, unblocks everything. No UI.

**Files**
- Modify: `Raconte/Transcription/TranscriptRevisionStore.swift` (:570 area)
- Modify: `Raconte/Transcription/TranscriptMerge.swift` (:20/:33/:43)
- Modify: `Raconte/Library/LibraryScreenModel.swift` (:366 area), `Raconte/Capture/UI/CaptureView.swift:229`,
  `Raconte/Library/UI/EntryDetailView.swift:92`
- Test: `RaconteTests/TranscriptDraftLifecycleTests.swift` (extend),
  `RaconteTests/TranscriptMergeTests.swift` (extend)

**Interfaces**

```swift
// TranscriptRevisionStore — sibling to closeStaleDrafts(now:), same rules, one capture.
@discardableResult
func closeStaleDraftIfNeeded(captureID: String, now: Date) async -> String?
// nil when: no draft, draft fresher than policy.sessionEndSeconds, capture trashed/missing,
// or the close threw (a degraded chain, §15b.15 — the draft stays, nothing is minted).

// TranscriptMerge — the #41.2 precondition, at the mint site so no caller can skip it.
enum TranscriptMergeError: Error, Equatable { case notMachineLineage(String) }
static func accept(current:machine:id:createdAt:deviceID:) throws -> TranscriptRevision
static func decline(current:machine:id:createdAt:deviceID:) throws -> TranscriptRevision
static func revert(current:toMachine:id:createdAt:deviceID:) throws -> TranscriptRevision
// Each throws .notMachineLineage(machine.id) when machine.source.isHumanLineage.
// Rationale (#41): a human revision id written into basedOnMachineID is permanent and
// poisons §6.4 propagation forever.
```

**Wiring** — `closeStaleDrafts(now:)` at launch, beside `promoteCorpusOnce()`
(`LibraryScreenModel.swift:366`, called from `CaptureView.swift:229`), **after** the corpus
promotion and **before** `sweepTrash()`. `closeStaleDraftIfNeeded` at entry-open, in
`EntryDetailView.refresh()` (`:92`), **before** the transcript read — a recovered draft that
mints a revision must be visible in the text the screen then shows. Never from
`LibraryScanner` or any scan path.

**Steps**
- [ ] **1.1** Red test: a draft older than `sessionEndSeconds` on capture X closes with
  `.recovered` via `closeStaleDraftIfNeeded`; a fresh draft on X does not; a stale draft on
  capture Y is untouched by the X call (the whole point of the per-capture variant).
- [ ] **1.2** Red test: `closeStaleDraftIfNeeded` on a capture whose chain has an unreadable
  revision returns nil, leaves `draft.json` on disk, mints nothing (§15b.15).
- [ ] **1.3** Red tests for the merge guards, one per entry point: a `.userEdit` revision
  passed as `machine` throws `.notMachineLineage`; `.machineLive` and `.machineRetranscribe`
  pass; **`.unknown("x")` passes** (it is machine lineage by `isHumanLineage`, §15/T6a rule
  — assert it explicitly so a future "tighten this" doesn't silently change lineage law).
- [ ] **1.4** The §6.3 adopt-verbatim pin (#41, §15b.13): `accept` and `revert` over a
  machine revision whose spans are `.inherited` and `.none` (not `.exact`) — assert the
  adopted spans keep those anchors byte-for-byte. **Mutation check:** force `.exact` in
  `adopt` → this test must fail and no other test may.
- [ ] **1.5** Launch + entry-open wiring, with a model-level test that a stale draft is
  closed by the time `EntryDetailView.refresh()`'s transcript read returns.
  **Mutation check:** move the close to after the read → the test must fail.
- [ ] **1.6** Full suite + commit `feat: wire stale-draft recovery; guard merge lineage (T7 prereq, #41)`.

---

### Task 2 — the editor's read model

The one new read the editor, the history panel and the storage stat all share. Pure
additions; the existing `EntryTranscriptLoader` path is untouched.

**Files**
- Create: `Raconte/Library/EntryChainSnapshot.swift`
- Modify: `Raconte/Library/LibraryScreenModel.swift` (a `nonisolated func chainSnapshot(for:)`
  beside `transcript(for:)` :396)
- Test: `RaconteTests/EntryChainSnapshotTests.swift`

**Interfaces**

```swift
/// Everything a screen needs to decide whether/what it may edit — one disk read, off the
/// main actor, writing nothing. Deliberately separate from EntryTranscript: the row path
/// must never pay for this (see #40.1 and Task 3).
struct EntryChainSnapshot: Sendable, Equatable {
    enum Editability: Sendable, Equatable {
        case editable
        case readOnlyUnreadableRevision(file: Int)   // §4.8
        case readOnlyListingUnreadable(String)       // §4.5a
        case readOnlyTrashed
        case readOnlyNoTranscript                    // nothing promoted, nothing to edit
    }
    var editability: Editability
    var currentRevisionID: String?
    var currentText: String                 // TranscriptChain.plainText(current), "" when none
    var currentSource: RevisionSource?
    var revisionCount: Int
    var isForked: Bool                      // TranscriptChain.forkedHumanLineage
    var openDraft: TranscriptDraft?         // resume-in-progress, and Task 8's "unsaved" marker
    var detachedMachineRevisions: [TranscriptHeadSummary]  // §12.8 — visible, labeled
    var chainByteSize: Int64                // #39
}
```

**Rules**
- Trashed check first (sidecar `trashedAt`), then listing, then `unreadableFiles`, then
  `current`. Same precedence as the store's write guards, so "the editor let me start typing
  and then the save refused" is structurally impossible.
- `detachedMachineRevisions` = every revision where `!TranscriptChain.isAttached` — labeled
  "machine transcript, not applied" in the UI (§12.8). Summaries, not bodies.
- Writes nothing. Ever. It is a read.

**Steps**
- [ ] **2.1** Red tests, one per `Editability` case, each from a real on-disk fixture
  (trashed sidecar; `transcript/` as a file; one undecodable `canonical-1.json`; empty
  capture; healthy chain).
- [ ] **2.2** Red test: chain with rev0 machine → rev1 userEdit → detached retranscribe M ⇒
  `currentRevisionID == rev1`, `detachedMachineRevisions == [M]`, `revisionCount == 3`.
- [ ] **2.3** Red test: an open `draft.json` is returned; a capture with none returns nil.
- [ ] **2.4** The read-path-writes-nothing test, copied from T6 Task 3.6: byte + mtime
  snapshot of the whole capture directory across a `chainSnapshot` call.
- [ ] **2.5** Full suite + commit `feat: EntryChainSnapshot — the editor's read model (T7)`.

---

### Task 3 — #40 read costs and #39 storage visibility

Do this before the editor, not after: #40.2 is a whole-chain decode every 2 s *while the
owner types*, and the editor is what makes it happen.

**Files**
- Modify: `Raconte/Library/LibraryScanner.swift:188` (`transcriptSummary`)
- Modify: `Raconte/Library/EntryTranscript.swift:79`
- Modify: `Raconte/Transcription/TranscriptRevisionStore.swift:460` (`writeDraft`)
- Test: `RaconteTests/LibraryScannerTests.swift` (extend), `RaconteTests/TranscriptDraftLifecycleTests.swift`

**Work**
1. **#40.1 — route row summaries through `validatedHead`** (:234), which exists precisely
   for this and has no production reader. The row needs `characterCount`/`firstLine`, not a
   body; `loadChain` stays the detail screen's path. Keep the `live.jsonl` fallback exactly
   as-is for entries with no chain. `.skip`-mode rows must stop decoding revision bodies
   entirely.
2. **#40.2 — short-circuit `writeDraft`'s chain decode.** The full `loadChain` there exists
   only to answer the A2b question "would this write create `transcript/` for no content?"
   — which is moot the moment `transcript/` already exists (the overwhelmingly common case,
   and always true while editing a promoted entry). Check directory existence first; decode
   only when it is absent. The §15b.15 degraded-chain refusal must **still fire on every
   write** — that guard is not the thing being skipped, and a test must pin it.
3. **#39 — one honest number.** `chainByteSize` on `EntryChainSnapshot` (Task 2) plus a
   `revisionsByteSize` stat on `DirectorySnapshot` beside `liveTranscriptByteSize`. Surface
   is owner Q7; the number lands here regardless, with a test.

**Steps**
- [ ] **3.1** Red perf-contract test (assert on behaviour, not timing): instrument via a
  fixture with an undecodable `canonical-1.json` + a healthy head — a `.skip` scan produces
  the row from the head and does **not** raise `.revisionUnreadable`… *or* it does; decide
  by writing the test that states today's answer first, then change deliberately. Whichever
  way, the row's degradation semantics must be identical before and after this task —
  `EntryDegradationTableTests` is the guard.
- [ ] **3.2** Mutation check for #40.1: point `transcriptSummary` back at `loadChain` → the
  new "row never decodes a revision body" test must fail. (Simplest honest instrument: a
  fixture whose `canonical-0.json` is valid JSON with a body that would be expensive/
  distinctive to decode, asserted absent from the row's output — or a counting seam. Do not
  assert on wall-clock time.)
- [ ] **3.3** Red test for #40.2: `writeDraft` on a capture with an existing `transcript/`
  performs no chain decode (seam-counted), and still throws on a degraded chain.
- [ ] **3.4** `revisionsByteSize` test + `Mirror` tripwire update on `DirectorySnapshot` if
  one guards it.
- [ ] **3.5** Full suite + commit `perf: route row summaries through the head cache; drop per-write chain decode (T7, #39/#40)`.

---

### Task 4 — the editor, v1

The one that matters. Everything above exists so this task is thin.

**Files**
- Create: `Raconte/Library/UI/TranscriptEditorView.swift`
- Create: `Raconte/Library/TranscriptEditorModel.swift` (the testable part — all logic here,
  the view is a thin binding, per the `transcriptDisplay` precedent at `EntryDetailView.swift:255`)
- Modify: `Raconte/Library/UI/EntryDetailView.swift` (entry point + read-only states)
- Modify: `Raconte/Library/LibraryScreenModel.swift` (draft passthroughs)
- Test: `RaconteTests/TranscriptEditorModelTests.swift`

**Interfaces**

```swift
@MainActor @Observable
final class TranscriptEditorModel {
    enum State: Equatable { case loading, editing, readOnly(EntryChainSnapshot.Editability), failed(String) }
    private(set) var state: State
    var text: String                     // bound to the text view
    private(set) var hasUnsavedChanges: Bool

    func open() async                    // chainSnapshot → resume draft.text if present, else currentText
    func textChanged()                   // restarts the 2 s debounce; never writes directly
    func flush() async                   // debounce fired, or app backgrounded → writeDraft
    func done() async -> Bool            // flush, then closeDraft(.sessionEnd); false on failure
    func cancel() async                  // §2.5 has NO discard: cancel == done. See owner Q1.
}
```

**Rules**
- **Resume beats reload**: an open `draft.json` whose text differs from `current` is what the
  editor opens with (that is what the store's `writeDraft` snapshot fields are for). Show it
  as a plain state, not an alert.
- **Debounce 2 s** (§12.1), cancelled and re-armed per keystroke. Flush on: debounce fire,
  `scenePhase` leaving `.active`, and `done()`. Every flush is `writeDraft`; only `done()`
  and the store's own stale/hour rules call `closeDraft`.
- **A failed `writeDraft`/`closeDraft` is loud** — same contract the 2026-08-03 detail-trash
  bug forced (`moveEntry`/`setBackdate`/`trashEntry` all return `Bool` and every call site
  alerts). No `_ = try?` on an editor save, ever, and never dismiss-then-write.
- **Read-only states render as sentences, not disabled text boxes**: which revision file is
  unreadable, or that the entry is trashed, or that there is nothing transcribed to edit.
- **Keyboard-first (iPad/Mac)** — owner preference, `2026-08-08-capture-landing-decisions.md`
  §1. v1: ⌘S = flush, ⌘Return / Esc = done, `.defaultFocus` on the text view, and the
  editor is a full-screen surface on macOS/iPad regular width rather than a sheet. Specific
  bindings are owner Q9.
- **Detail screen stays the reader.** The editor is a separate surface; the detail screen
  gains an Edit affordance and nothing else. Do not make the transcript section editable
  in place.

**Steps**
- [ ] **4.1** Red tests over `TranscriptEditorModel` with a fake/injected store: open on a
  healthy chain → `.editing` with `currentText`; open with a draft → draft text; open on
  each read-only case → `.readOnly` with the matching reason and `text` unmodifiable.
- [ ] **4.2** Red test: N `textChanged()` calls inside the debounce window produce exactly
  **one** `writeDraft`. **Mutation check:** remove the debounce → the test must fail.
  (Inject the clock/scheduler; no `Task.sleep` in the test.)
- [ ] **4.3** Red test: `done()` with unchanged text mints nothing and deletes the draft
  (the store already does this — the test pins that the editor doesn't work around it);
  `done()` with changed text mints exactly one `.userEdit` revision whose `plainText` equals
  the edited text (the round-trip postcondition §15b.11 makes law).
- [ ] **4.4** Red test: a `writeDraft` throw surfaces as `.failed` and the editor does not
  dismiss; a `closeDraft` throw makes `done()` return false.
- [ ] **4.5** Red test: background (`scenePhase` change) flushes; a subsequent open resumes
  the flushed text.
- [ ] **4.6** View wiring + a UI test on the simulator: open entry → Edit → type → Done →
  the detail screen shows the new text. (`RaconteUI` scheme; the repo has **no `TextEditor`
  anywhere today** — expect a first-use surprise or two on focus and toolbar behaviour.)
- [ ] **4.7** Full suite + commit `feat: transcript editor v1 — draft, debounce, mint (T7)`.

---

### GATE A: adversarial review — the first user-facing write path into the chain

Opus, whole-branch so far. Attack: the debounce/flush/close ordering under backgrounding and
kill; resume-vs-reload; every failure surfacing (the fire-and-forget-during-dismissal class
of bug that shipped once already); the read-only precedence in `EntryChainSnapshot` vs the
store's write guards; and #40.2's short-circuit against §15b.15. Reviewer re-runs the suite
independently and **writes throwaway probe tests to confirm findings before reporting** (the
Gate A/B lesson). Also audit that new fixtures exercise the non-degenerate path — the
failure mode shared by Gate A I2, T6d's vacuous lattice test, and Gate B's C1.

---

### Task 5 — voice attribution survives an edit

Without this, Task 4 ships a regression: `EntryTranscript.swift:120` drops paragraphs the
moment `current.source != .machineLive`.

**Files**
- Modify: `Raconte/Transcription/TranscriptAttribution.swift` (add a span-based entry point)
- Modify: `Raconte/Library/EntryTranscript.swift:79-125`
- Test: `RaconteTests/TranscriptAttributionTests.swift` (extend),
  `RaconteTests/TranscriptAttributionLoadTests.swift` (extend)

**Design.** Today attribution maps snapped marker frames onto `TranscriptConsolidator`'s
committed results, which carry frames. A revision's spans carry frames too — with an honesty
grade. So:

```swift
/// Attribute over a revision's spans instead of the machine's committed results.
/// Spans whose anchor has no usable bounds (.none/.unknown, and zero-length .inherited
/// insertion points) cannot be placed against a marker frame — they inherit the voice of
/// the nearest preceding placeable span and are never allowed to START a paragraph on
/// their own evidence.
static func attribute(spans: [TranscriptSpan], snapped: [SnappedMarker]) -> [Paragraph]
```

Non-negotiables carried from the rendering plan's hazards: an unreadable `markers.jsonl`
assigns **no** voices, ever; zero usable markers → `paragraphs == nil`; an empty result →
`nil`, never an empty paragraph list. And the whole-record join rule generalises to a
whole-span join rule — a no-marker entry must still render byte-identically to
`TranscriptChain.plainText(current)`.

**Steps**
- [ ] **5.1** Red: an edited revision (rev0 promoted, one word retyped) with two voice
  markers still yields the same two paragraphs, with the edited word in the right one.
- [ ] **5.2** Red: a `.none`-anchored span (typed from nothing) between two `.exact` spans
  joins the preceding paragraph and never opens a new one.
- [ ] **5.3** Red: no-marker edited entry → `paragraphs == nil`, text byte-identical to
  `plainText`. **Mutation check:** make the span join use a different separator → fails.
- [ ] **5.4** Red: delete the `current.source == .machineLive` gate at `EntryTranscript.swift:120`
  and prove the old failure mode is gone — i.e. write the test that used to justify the gate
  (markers over post-edit text) and show it now passes for the right reason.
- [ ] **5.5** Full suite + commit `feat: attribute voices over revision spans, not just the live log (T7)`.

---

### Task 6 — marker correction + #37 typed-word correction

**Blocked on owner Q3** (correction shape) and **Q11** (whether markers appear inline in the
editor). Do not dispatch before those are answered.

**#37 is mostly already solved by Task 4**: a Swahili word the transcriber mangled is
retyped in the editor, spliced like any other change, and the audio stays ground truth.
What Task 6 owes it is (a) an explicit acceptance test that a retyped out-of-vocabulary word
produces a `.inherited`-anchored span over the replaced word's frames rather than losing the
anchor, and (b) a decision on whether corrections are *collected* anywhere for T8's
contextual-string biasing (#38) — owner Q8. Do not build the collection until it is answered;
building it wrong is worse than not having it.

**Marker correction** — the built-in constraint is that raw taps are immutable. The two
shapes to put to the owner (Q3):
- **Additive records in `markers.jsonl`** — a new `StructureMarker.kind` (e.g. `retract`,
  referencing a seq; `voiceCorrection` with a frame). Preserves append-only and the raw-tap
  rule; `MarkerLogReader` already preserves unknown kinds on disk and ignores them for
  rendering, so an older build degrades to "shows the uncorrected version" rather than
  breaking. But it needs a writer on a path that is currently capture-only.
- **A sibling overlay file** (`marker-edits.jsonl`) — leaves the capture-time log
  untouched by construction, at the cost of a fourth reader and a fourth three-answer enum.

Recommendation to the owner: **additive records in `markers.jsonl`**, because the snapping
rule already re-derives boundaries from raw taps on every read and a correction is just one
more raw fact about the same timeline.

**Steps** (shape assumes the recommendation; revise on the owner's answer)
- [ ] **6.1** Red: correction-kind decode/encode round trip; an older-build reader (unknown
  kind) ignores it and renders the uncorrected result — assert both directions.
- [ ] **6.2** Red: a voice correction at frame F changes the paragraph split; the original
  tap record is byte-unchanged on disk after the write.
- [ ] **6.3** Red: a retract of a mis-tapped paragraph marker removes that split, and a
  retract of a nonexistent seq is ignored, not an error.
- [ ] **6.4** Red (#37): retype `"Ellen"` → `"LN"` mid-transcript; assert the resulting span
  is `.inherited` over the replaced span's **full** parent bounds (F17), not `.none` and not
  a synthesized sub-range.
- [ ] **6.5** Marker-correction UI in the editor + a UI test.
- [ ] **6.6** Full suite + commit `feat: marker correction + typed-word correction (T7, #37)`.

---

### Task 7 — the metadata audit log (§7)

Independent of everything above; can run in parallel with Tasks 5–6.

**Files**
- Create: `Raconte/Library/EntryLog.swift` (`EntryLogRecord`, `EntryLogCause`, writer, reader)
- Modify: `Raconte/Library/EntryMetadataStore.swift` (:51 make instance `write` private; :58
  `update` gains the diff-and-append)
- Path already exists: `SegmentLayout.entryLogFileName` :17 / `entryLogURL` :149 (beside
  `entry.json`, **not** in `transcript/`).
- Test: `RaconteTests/EntryLogTests.swift`, `RaconteTests/EntryMetadataStoreTests.swift` (extend)

**Shape** — §7.1 verbatim: `at`, `field`, `from`, `to`, `cause`, `origin`. No `seq`, no
`deviceID`. `from`/`to` are the fields' on-disk encodings as strings (`"1998-03"`, ISO8601,
a ULID, `"true"`).

**Writer rules** — §7.2, all five load-bearing:
1. Inside `EntryMetadataStore.update` :58, by diffing before/after the mutation closure.
2. **Ordered after** the sidecar `AtomicFile.replace` returns. The log never claims an edit
   the sidecar does not hold.
3. Bare `O_APPEND` open → write → close, **with the torn-tail newline fuse** (if the last
   byte is not `\n`, write a lone `\n` first). Copy `LiveTranscriptStore.swift`'s fuse; this
   is required explicitly, not by analogy.
4. **Append failure is silent** — debug console only. `EntryDegradation` is scan-derived and
   has nowhere to carry it (§7.2 B5).
5. A mutation that changes nothing writes nothing.

Plus: `EntryMetadata` has **six** fields (`journalID`, `originalDate`, `trashedAt`,
`detectedDate`, `detectionRan`, `multiVoice` — `EntryMetadata.swift:47/57/61/76/87/97`).
The `Mirror` field-count tripwire goes beside the differ, counting **6**, with a comment
naming what to do when it fires (copy `RecoveryExecutorTests.swift:206`'s pattern).

**Steps**
- [ ] **7.1** Red: round-trip + lenient/strict decode; unknown `cause` decodes as `.unknown`.
- [ ] **7.2** Red: a backdate edit through `update` appends exactly one record with the right
  `from`/`to` encodings; a no-op mutation appends nothing.
- [ ] **7.3** Red: the torn-tail fuse — plant a file whose last line lacks `\n`, append, and
  assert **both** records survive. **Mutation check:** remove the fuse → the test fails and
  both records are lost (the bug `LiveTranscriptWriter` documents).
- [ ] **7.4** Red: a failing append (unwritable path) does not fail the metadata write —
  sidecar updated, `update` returns normally.
- [ ] **7.5** Red: ordering — an append is never observable before the sidecar write lands.
- [ ] **7.6** Make instance `write` private; fix fallout; keep the static seam and document
  it as read/test-only (§7.2 B4).
- [ ] **7.7** `Mirror` tripwire at 6 fields, with the comment.
- [ ] **7.8** `cause: .rejected` — `EntryMetadata.setOriginalDate` returns `false` for a
  future backdate and callers discard it; log the rejected attempt (§7.1 nit).
- [ ] **7.9** Full suite + commit `feat: per-entry metadata audit log (T7, design §7)`.

---

### Task 8 — revision history panel + revert

The §12.8 answer ("detached revisions visible, clearly labeled") needs a surface, and revert
gives `TranscriptMerge` its first production caller — with Task 1's guards already in place.

**Files**
- Create: `Raconte/Library/UI/RevisionHistoryView.swift`
- Modify: `Raconte/Library/LibraryScreenModel.swift` (a `revert(captureID:toRevisionID:)`
  passthrough → `TranscriptMerge.revert` → `store.append`)
- Test: `RaconteTests/RevisionHistoryModelTests.swift`

**Content** — from `EntryChainSnapshot` (Task 2), no new read:
- The chain in `(createdAt, id)` order; each row labeled machine vs human, and detached rows
  labeled "machine transcript, not applied".
- `chainByteSize` (#39) shown here, with the growth alarm if the owner picks a threshold (Q7).
- **Revert to a machine revision** — the only merge action meaningful before T8. Accept and
  decline stay uncalled until retranscription exists.
- A fork indicator when `isForked` (concurrent edits that never converged). Read-only in v1.

**Steps**
- [ ] **8.1** Red: ordering, labeling, detached marking, over a fixture chain.
- [ ] **8.2** Red: revert to rev0 mints a `.merge` whose spans are byte-equal rev0's (anchors
  included, §15b.13) and becomes `current`; the reverted-from revision still exists on disk.
- [ ] **8.3** Red: revert refuses on a degraded chain and on a trashed capture.
- [ ] **8.4** Red: attempting to revert to a **human** revision throws `.notMachineLineage`
  (Task 1's guard, exercised through a real caller).
- [ ] **8.5** Full suite + commit `feat: revision history panel + revert (T7)`.

---

### Task 9 — parked rendering minors + docs

The three residuals from the voice-attribution reviews, plus the paperwork.

- [ ] **9.1** The **trim vs "byte-identical" docs claim**: the rendering plan claims
  no-marker entries render byte-identically; promotion now trims run whitespace (§15b.10).
  Reconcile the claim with what the code does and pin whichever is true with a test.
- [ ] **9.2** **Cross-paragraph text selection** is lost with per-paragraph `Text`. Either
  restore it (one `AttributedString`/`Text` with paragraph breaks) or record the trade
  explicitly in the view's doc comment. Owner-visible; see Q12.
- [ ] **9.3** **`hasApproximateBoundary` is symmetric and unpinned by tests** — add the test.
  Whether it gets a UI affordance is owner Q12.
- [ ] **9.4** Docs: append a **§16** to the T6 design recording T7's as-built rulings (the
  same way §15/§15b record T6's); update `docs/overview.md` §5 and the roadmap; close #37,
  #39, #40, #41 with what actually shipped and what moved to T8.
- [ ] **9.5** Full suite + commit `docs: T7 as-built rulings; close T7 prerequisite issues`.

---

### GATE B: adversarial whole-branch review

Opus over the full T7 delta against this plan, the T6 design (§2.5, §3.3, §4.8, §6, §7) and
§15/§15b. Reviewer re-runs the suite independently, audits that every named test exists and
tests what its name says (the fabricated-evidence lesson from #25 step 3), and probe-confirms
findings with throwaway tests. Specific things to attack:
- Data safety: can any editor path lose a keystroke that the owner saw accepted? Kill the app
  at every point between keystroke, debounce, `writeDraft`, `closeDraft`, and `append`.
- Does anything on a read/scan path now write? (`validatedHead` routing is the new risk.)
- Does the audit log ever fail the write it audits, or claim an edit that didn't land?
- Do the new fixtures exercise the non-degenerate path?

Then: PR, left open for Nico to merge (auto-mode cannot `gh pr merge`).

---

## 3. Open questions for the owner

Numbered so they can be answered by number. **1, 2 and 3 block Tasks 4 and 6; the rest can
be answered while earlier tasks run.**

1. **What ends an edit?** §2.5 has no "discard" — a draft closes to a revision or to
   nothing, and there is no undo of a close. So an editor "Cancel" would have to mean
   "Done", which is a lie. Options: (a) only a Done button, navigating away = Done;
   (b) Done + an explicit "Revert my changes" that closes to nothing by restoring the
   text before closing. Recommend (a) for v1 — history + revert is the undo story.
2. **One text box or per-paragraph editing?** Whole-text is far simpler and is what
   `TranscriptSplice` expects. But your entries render as BN/LN paragraphs, and a single
   flattened text box loses that structure while you edit it (paragraph breaks come from
   markers, not from newlines in the text). Options: (a) one plain text view of the
   flattened transcript, paragraphs reappear after saving; (b) per-paragraph text views,
   joined back into one string on save; (c) one text view that renders labels as
   non-editable decorations. Recommend (a) for v1, (b) as the likely v2.
3. **How should a mis-tapped marker be corrected?** Recommendation: append correction
   records to `markers.jsonl` (raw taps stay untouched forever; the snapping rule already
   re-derives everything on read). Alternative: a separate overlay file. Also: should you be
   able to **add** a voice/paragraph boundary that was never tapped — and if so, does it
   anchor to a word boundary you pick in the text, or to a time you scrub to?
4. **Editing a trashed entry:** refuse outright (recommended), or allow with a warning?
5. **Read-only degraded chain:** the editor refuses to open when any revision file is
   unreadable (§4.8). Should the screen offer anything beyond the explanation — e.g. "show
   me the live transcript instead", read-only?
6. **Tap-a-word-to-play-the-audio (#13) in T7 v1, or later?** The anchors exist for it now.
   It needs `PlaybackSeek`'s long-standing `Int` vs `Int64` width mismatch fixed first, and
   span-to-word offset mapping the current `Paragraph` type doesn't carry. Recommend later.
7. **#39 storage visibility:** where should the number live — entry detail, the revision
   history panel, a diagnostics screen, or all three? And what threshold should the growth
   alarm use (total chain bytes? revisions per entry?)? Context: text is dwarfed by audio;
   this is early warning, not capacity.
8. **#37 follow-through:** should typed corrections be *collected* (a per-journal
   vocabulary list) to feed T8's contextual-string biasing (#38), or is edit-time
   correction alone enough for now? Collecting is cheap; guessing the schema wrong is not.
9. **Keyboard-first specifics (iPad/Mac):** confirm ⌘S = save-now, ⌘Return / Esc = done,
   autofocus on open, full-screen editor rather than a sheet on regular width. Anything
   else you expect from a "real" text editor — find/replace, word count, undo stack?
10. **Audit log visibility:** is `entry-log.jsonl` developer/diagnostics-only for now
    (written, exported, never shown), or do you want a "changes to this entry" list on the
    detail screen? It is deleted with the entry either way (§7).
11. **Are markers visible inside the editor** (¶ and BN/LN shown inline as structure you
    can move), or is the editor plain text with marker correction as a separate mode?
    Q2 and Q3 collapse into this one if the answer is "visible".
12. **Approximate boundaries + cross-paragraph selection** (Task 9): should an approximate
    voice/paragraph cut get a visible affordance now? And is losing cross-paragraph text
    selection (a side effect of per-paragraph rendering) worth fixing in T7?

---

## 4. Explicit non-goals for T7

Named so they are not re-argued mid-build:

- **Per-hunk merge, and any diff UI.** Whole-revision only (§12.6). `degradingOverlaps`
  ships tested and uncalled.
- **Accept / decline.** No machine revision arrives until T8; `TranscriptMerge.accept` and
  `.decline` keep zero callers, with Task 1's guards already in front of them.
- **Retranscription itself** (T8), and #38 contextual biasing.
- **Capture-time typed words** (#37 option 2) — the expensive shape; edit-time first.
- **Search / FTS**, export, sync (M4/M5).
- **The capture-landing redesign** — separate track; only the keyboard-first note feeds here.
- **`backdateOrigin`** (`2026-08-03-backdate-precedence-ux.md`). The audit log reads it if
  it exists and logs `origin: nil` if it does not (§7.3). T7 does not build it.

## 5. Self-review notes (plan author)

- Spec coverage: §2.5 → Tasks 1/4, §3.3 → 4/6, §4.8 → 2/4, §6.3/§6.5 → 1/8, §7 → 7,
  §12.6/§12.8 → 8, §15b.12–15 → 1/2/4. §6.1/§6.2/§6.4 arrival wiring is T8's.
- Issue coverage: #37 → 6, #39 → 3/8, #40 → 3, #41 → 1.
- Ledger coverage: whole-revision accept v1 → 4/8, marker correction → 6, audit log → 7,
  typed-word → 6, keyboard-first → 4, parked rendering minors → 9.
- The one scope item the ledger did **not** name and this plan adds: Task 5. It is not
  optional — without it the editor deletes the voice rendering on first save.
- Deliberately not sized: Tasks 4 and 6 are the only ones with real UI risk (the repo has
  no `TextEditor` today, and no snapshot harness), so both keep their logic in a testable
  model and their views thin.
