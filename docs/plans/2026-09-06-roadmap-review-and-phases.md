# Roadmap review + proposed phases (2026-09-06)

Written unattended after the build 14 Mac smoke, at the owner's request. **This is a
proposal, not an approved plan** — it exists to be argued with. Nothing here is scheduled
and no branch has been cut.

Sources: all 40 open issues, `docs/overview.md`, `docs/native-rebuild-plan.md`, and the
state of `main` at `b81a3031` (read the code, not the docs, for what is actually built).

## What is actually true today

Verified against `main`, not against the doc prose:

- **M1–M4 are in and dogfooding.** Capture, live transcription, journals/library/trash,
  markers + voice rendering, T6 revision chain, T7 editor, Mark voices, nav split-view,
  and CloudKit sync (`Raconte/Sync/` is on main, 11 files).
- **There is no search.** Zero hits for FTS5 or any search surface anywhere in the app.
  M3 shipped without it; `overview.md` folds it into M5. A grepless archive.
- **There is no export.** The plan of record calls export "a v1 acceptance criterion, not
  a later feature." It does not exist.
- **There is no migration script.** `scripts/` holds TestFlight and provisioning tooling
  only. The frozen entries on recountly.org have never been brought over.
- **T8 retranscription does not exist** beyond comments anticipating it.

So the three things the original plan called non-negotiable for v1 — export, migration,
search — are the three things not built. Everything shipped since M4 has been polish on
top of an archive that cannot yet be searched, exported, or completed.

That is the single most important finding in this review, and it drives the ordering below.

## The proposed order, and why

Seven phases. The argument for each ordering decision is stated, because the ordering is
the only part worth disagreeing with — the contents are mostly forced.

### Phase 1 — Don't lose words

**Why first:** these are the only open issues where the failure mode is *the owner's
recorded words are gone*. Everything else is inconvenience. This phase is small.

- **#85 — asset-arrival guards discard instead of park.** A land-or-park violation.
  CKSyncEngine never redelivers a consumed record, so a refuse-and-return is permanent,
  silent loss. Already recorded as a standing lesson; still open in code.
- **#91 — child record NOT_FOUND with no archived state waits for a launch-only
  reconcile on iOS.** Same family: an arrival that cannot be used yet must be kept, not
  dropped and hoped for.
- **#81 — one corrupt `entry.json` blocks deleting its journal, with no in-app repair
  route.** The owner can reach a state he cannot get out of without a developer.
- **#2 — capture is not gap-honest:** dropped input buffers compress time instead of
  inserting silence. This corrupts the frame clock, which is the master clock every
  marker, transcript timestamp and playback position is measured against. A quiet
  correctness bug under the whole marker story.
- **The M4 acceptance gate has, as far as this review can tell, never been run.** The
  plan of record defines it precisely: delete the app from a Mac, reinstall, and confirm
  the full archive reconstructs from CloudKit. Sync has shipped to TestFlight and been
  smoked, but that is not the same test. **Open question for the owner: has this been
  done?** If not, it belongs here, because Phase 2 tears down the only other copy of the
  data.

**Gate:** #85 and #91 each need a test that proves the park-and-retry path, not just that
the drop stopped. The reinstall gate is manual and must be run on a machine whose local
container has actually been deleted.

### Phase 2 — Bring the archive home

**Why second:** recountly.org is still deployed and still holds entries that exist
nowhere else. Every week it stays up is a week of two half-archives, and the teardown
cannot start until export exists and migration has run. This phase also produces a real
corpus for Phase 4's search to be tested against, which is a genuine reason to do it
before search rather than after.

- **Open-format export + verification.** Per-entry directories (`audio.m4a`,
  `transcript.md`, `entry.json`, photos), manifest, checksums. The spec is already
  written in `plans/2026-07-29-data-model-and-migration.md`. Export is the longevity
  story — CloudKit is only transport.
- **Migrate the frozen web entries.** Counted directly against the live Neon database on
  2026-09-06 — **36 entries, 4 journals, 34 audio files, 39.5 MB, 53k characters of
  transcript, 63 minutes of audio.** The breakdown matters:
  - **12** in a journal called "Testing" — 3-17 second clips, genuinely disposable.
  - **18** in "2026 learning to use this tool" — real personal entries, 1,300-10,600
    characters each.
  - **6** attached to no journal, mixed real and test.
  - **23 of the 34 audio files carry an `imp_` prefix** (`imp_2025_AUG_07_07.49.mp4`).
    These are the "23 paper-archive imports" the plan of record names. They are the
    largest files (up to 6 MB) and belong to no journal, which is why the
    "Nicholas' travel notes 1998" journal reads as empty.

  **A full backup was taken before any teardown: `~/recountly-export-2026-09-06/`** —
  all rows as JSON with full transcripts, every audio file, and a sha256 manifest. The
  teardown is therefore no longer urgent, but the migration is no longer optional: this
  is real material, not test data.

  One-evening script: the exported JSON + audio files → the local store. Note the schema
  gap — the web model has no revision chain, no markers and no voice attribution, so
  every migrated entry lands as a single machine revision with no marker data. Decide
  whether migrated audio gets re-transcribed on device (which would give it real frame
  anchors) or keeps the web transcript as-is with `none`-grade anchors.
- **Tear down the web app** per the checklist in the plan of record: verify the export
  first, then retire the Vercel project, Neon, Blob and domain routing. Keep the domain.

**Gate:** the export must round-trip — a verification pass that reads the exported
package back and confirms every entry, every revision and every audio file is present and
checksums clean. Do not tear anything down on the strength of "the script finished."

### Phase 3 — A design system

**Why third, and why not later:** the owner asked for this directly today (#149 — "need
a design system I think"). More importantly, every remaining phase is UI work. Doing the
token layer *after* the image work and the editor rebuild means doing that work twice, or
never. This is the cheapest it will ever be.

- **#149 — the backdate sheet UX pass** is the presenting symptom. Its concrete cause is
  already diagnosed: a blanket `.opacity(0.45)` stacking on top of `.disabled`, not a bad
  colour. That is a two-line fix; the issue is the absence of a rule that would have
  prevented it.
- **Extend the existing token layer rather than starting one.** `InkTone`/`InkSurface`
  already exists from the #118 re-skin and is used by seven screens. What it lacks is
  explicit **text roles** — primary / secondary / disabled — defined for both the pinned
  near-black capture surface and the ambient surfaces, each with a stated contrast floor.
- **Sweep the literals.** Remaining `Color(white:)` values and bare `.opacity()` on text.
- **Codify the platform traps as lint-able rules**, since they keep recurring: `.callout`
  is 16 pt on iOS and 12 pt on macOS (state floors in points); no `Image` inside a macOS
  `Menu` label; controls on the capture surface must pin `.environment(\.colorScheme,
  .dark)`.

**Gate:** a contrast test over the token pairs, so "too light" becomes a failing test
rather than a smoke observation. This is the only phase whose deliverable is partly a
constraint on future phases.

### Phase 4 — Make the archive readable

**Why fourth:** with a complete corpus (Phase 2) and a design language (Phase 3), this is
where the app becomes the reading surface it is meant to be. Search is the headline; the
rest is the navigation and hierarchy work the owner has been flagging since August.

- **Search — FTS5 + snippets and highlighting.** M3's unfinished half. Feature parity
  with what the frozen web app already does. Must be a rebuildable index, never a second
  source of truth.
- **#148 — Open from the receipt should leave the capture space** and land on the entry
  inside its journal. Today the sidebar stays on Capture, so the detail view has no
  journal context at all. Filed today with a screenshot.
- **#86 — entry detail: sidenav becomes the entry list** (highlight + scroll to current).
  Currently parked; it is the same navigation problem as #148 seen from the other side,
  and they should be designed together.
- **#55 — detail screen visual hierarchy:** too many identical bubble buttons. Directly
  downstream of Phase 3.
- **#106 — view a journal's cover full-screen** (now carrying the lightbox proposal from
  the closed #147), and **#120 — choose the visible slice of the cover photo.**
- **Trash friction:** #83 (drop the confirm, use a lingering undo row), #27 (swipe-to-
  trash blinks), #35 (per-journal deletion friction: easy / confirm / locked).

**Gate:** search needs a corpus test against the migrated entries, including the
paper-archive imports with year-only dates — the case most likely to break bucketing.

### Phase 5 — Images

**Why fifth:** it is a coherent cluster that shares one flow, and it is genuinely
deferrable. Doing it as one phase avoids three separate passes over the same picker.

- **#109** simple crop + a review of image-storage efficiency
- **#121** crop tool at capture time, for covers and entry images
- **#134** repeated photos for the same purpose without re-entering the flow
- **#107** image-first entries: no way to add a transcript, title or text afterwards
- **#17** cover-image polish deferred from #14 (thumbnail decode caching, colour profile,
  rescan scope)
- **#68** macOS journal cover picker sheet renders empty — PhotosPicker row absent. A
  live platform bug; pull it forward if it blocks anything in Phase 4.

### Phase 6 — The unified editor and T8

**Why sixth:** the largest design surface left, with two design rulings still open
(recorded in `overview.md`), and the least urgent — the current editor works.

- **#60 + #59 — one editor showing visible paragraph and voice structure**, replacing
  Mark voices mode. Undo falls out of it. `overview.md` names this as the successor to
  the current split.
- **T8 — retranscription** from the m4a: a better model proposes a machine revision, and
  the accept/decline UI that T7 built the mechanism for but never called.
- **#38 — "LN" transcribing as "ellen"**, via contextual-string biasing. Small, and it
  irritates on every two-voice entry.
- **#44 — verify SpeechTranscriber never splits runs without whitespace**; add a
  `join == result.text` fallback if it does. A promotion-correctness precondition for T8.
- **#13 — tap a word, play from that moment.** The anchor honesty grades that make this
  possible already ship; nothing consumes them yet.
- **#104 — edit an entry's date after capture**, **#46 — mark an entry as reviewed**,
  **#133 — merge and split entries.** Adjacent editorial capabilities; #133 is
  substantially the largest and may deserve its own design pass.
- **#137 — Mac editing mode: how recording and text interact.** A design question, not a
  task; it should be answered before the unified editor is specced, not after.

### Phase 7 — Standing debt

Not a phase so much as a list to draw from whenever a branch is already open in the
neighbourhood. Nothing here is user-visible.

- **#67 — nav redesign deferred follow-ups.** Eleven triaged items, not one task. Two are
  worth pulling forward on their own: item 2 (a background sync pull can pop the user out
  of an entry they are reading — now reachable, since sync has shipped) and item 3 (the
  whole sidebar re-evaluates once per second while recording, O(journals × allEntries) on
  the MainActor). Closing this issue means doing all eleven.
- **Test-coverage gaps:** #78 (journal editor UI tests use a single-journal corpus, so a
  stale header after switching journals is uncovered), #76 (unconfirmed: `JournalSpanEditor
  .populate()` may reseed from a stale span if its Section recycles), #29
  (`CaptureMachine`'s effect list is not authoritative), #66 (alert TextField AX
  identifiers do not bridge onto UIAlertController).
- **#50 — `writeDraft` decodes the whole chain on every debounced write.** Needs a
  body-free readability check. Grows with the archive; cheap now, annoying later.
- **#71 — flag entries dated outside their journal's span.** The span type and containment
  check already ship; only the two display sites are missing. Genuinely small.
- **#1 — background recording continues silently**, **#26 — user-initiated pause/resume**,
  **#63 — no marker feedback on macOS** (the dash-dot haptic is iOS-only).
- **#51 — two human-lineage revisions minted inside one millisecond** are randomly
  ordered. The local half was hardened in #145; the cross-device tie remains.

## What this proposal is arguing for

Three claims, stated plainly so they can be rejected:

1. **The project's stated v1 criteria are the unbuilt part.** Export, migration and search
   were called non-negotiable in the plan of record and are the three largest gaps. Recent
   work has been polish on an incomplete archive.
2. **Finishing the archive should precede improving it.** Phases 1 and 2 exist because a
   second copy of the data still lives on a service that is meant to be torn down, and
   because the sync path can still drop an arrival permanently.
3. **The design system is worth doing before the remaining UI work, not after.** Not
   because it is urgent, but because it is the only item whose cost rises with every phase
   that ships without it.

## Open questions for the owner

1. **Has the M4 acceptance gate been run** — delete the app from a Mac, reinstall, confirm
   the full archive reconstructs from CloudKit? Phase 2 tears down the other copy, so this
   is load-bearing.
2. ~~How many entries are actually on recountly.org?~~ **Answered 2026-09-06: 36 entries,
   34 audio files, of which 23 are the paper-archive imports. Backed up to
   `~/recountly-export-2026-09-06/`.** The owner's initial recollection was that this was
   all test data; it is not — 18 entries are substantive personal journal entries. The
   remaining question is narrower: **should migrated audio be re-transcribed on device**
   (earning real frame anchors and marker-ready spans) **or carried over as-is** with the
   web transcript and `none`-grade anchors?
3. **Does the phase order above match where your attention is?** The honest alternative is
   to lead with Phase 3 and Phase 4 — the design system and the reading surface — because
   that is what you actually see every day, and let migration wait. That is a legitimate
   choice; it just means the web app stays up longer.
4. **Is #133 (merge/split entries) a v1 capability or a v2 one?** It is the largest single
   item in Phase 6 and would benefit from being cut or promoted deliberately rather than
   sitting mid-list.
