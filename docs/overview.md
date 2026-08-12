# Raconte — how it works (current plan, plain words)

A map of the system as it stands and where it's going. Mental models only — the
reasoning and history live in the linked design docs. Updated 2026-08-09.

## The one idea

**The audio file is the truth. Everything else — transcript, dates, voices,
paragraphs — is an interpretation of it, and every interpretation can be redone
without losing anything a human did.**

Every design choice below is that idea applied to one more layer.

## The layers

```mermaid
flowchart TB
    A["Audio on disk\n(indestructible capture)"] --> B["Machine transcript\n(live log, replaceable)"]
    B --> C["Revision chain\n(your edits, permanent)"]
    A --> M["Your taps\n(markers: voice, paragraph)"]
    M --> D
    C --> D["What you see\n(rendered entry)"]
```

- Lower layers never depend on upper ones. A transcription bug can't hurt audio;
  a rendering bug can't hurt an edit.
- Machine output is always replaceable. Human input (edits, taps, dates) is never
  overwritten by a machine.

## 1. A capture: recording that survives anything

While you record, raw audio is appended to disk in ~20-second chunks. Kill the
app at any instant and at most the last unflushed buffer (≤ 0.2 s) is lost.
When you stop, the chunks are encoded to one `recording.m4a`, and the raw chunks
are deleted only after the m4a is verified playable. If encoding ever fails, the
raw chunks stay — they're playable themselves.

On every launch, a recovery scan walks the capture folders and finishes whatever
was interrupted. Nothing real is ever auto-deleted; you get a "Recovered
recording" banner with Keep as the default.

**The master clock is the frame count** — the running tally of audio samples
since recording began. Marker taps, transcript timestamps, and playback position
all use it, so "second 42 of the transcript" is literally second 42 of the m4a.

Details: [M1 capture design](plans/2026-07-29-m1-capture-design.md)

## 2. An entry: a capture plus your metadata

An entry is a capture directory plus a small `entry.json` sidecar holding what
*you* said about it: which journal it belongs to, its date, whether it's in the
trash, whether it's a two-voice entry. The sidecar is deliberately a separate
file so metadata edits can never disturb the hardened recording machinery.
A missing sidecar just means "all defaults" — never an error.

One capture directory, complete:

```
captures/<id>/                     # id is a ULID — sorts by creation time
  manifest.json                    #   machine state: format, phase, transcript ref
  entry.json                       #   your state: journal, date, trash, voices
  final/recording.m4a              #   the audio — the ground truth
  segments/…                       #   raw chunks (only until encoding finishes)
  transcript/
    live.jsonl                     #   what the machine heard, as it heard it
    markers.jsonl                  #   your taps, raw
    canonical-0.json, -1.json …    #   the revision chain (see §5)
    head.json                      #   cache of "what's current" — disposable
    draft.json                     #   an edit in progress (only while editing)
```

**The library is a scan of these folders — there is no database.** SQLite +
full-text search arrives later (M3 completion) and only ever as a rebuildable
index, never a second source of truth.

**Trash** is a 30-day soft delete: a tombstone in the sidecar, restorable, then
swept. Permanent deletion first renames the whole directory into a staging area
so a half-finished delete can't resurrect an entry. Nothing in the app ever
writes into a trashed or deleted capture.

Details: [M3 dogfood plan](plans/2026-08-02-m3-dogfood-mvp-plan.md),
[staged removal](plans/2026-08-05-staged-removal-build-prompts.md)

## 3. Dates: when it was spoken vs. when it was written

Every entry has two dates:

- **capturedAt** — when you recorded it. Automatic, exact, never edited.
- **originalDate** — the date on the paper page you were reading. Optional,
  edited freely, can be just a year ("1998") or a month ("1998-03"). Stored as
  that string, so timezone math can never shift a year-only date. The library
  browses by this date.

Three things can propose an originalDate: you dialing one in, carry-over from
the previous entry in the same sitting, and a date the app hears spoken at the
start of a recording ("March 4th, 1998"). **Decided rule (partly unbuilt): what
you typed always wins; then what the recording says; then carry-over.** Today
the app doesn't yet record *how* a date arose, so a carried date blocks spoken
detection for the rest of a sitting — that fix (`backdateOrigin`) is designed
but not built.

Details: [backdate precedence](plans/2026-08-03-backdate-precedence-ux.md)

## 4. Markers: your taps are measurements

Your paper journals are two-voice conversations (print vs. cursive — "big Nico"
`bn` and "little Nico" `ln`). No machine can recover which voice is which, so
you mark it live: a **switch-voice** button and an **end-paragraph** button
while recording, each tap confirmed by a haptic (you're looking at the page,
not the screen).

The rule that makes this safe: **a tap is stored as the raw audio frame where it
happened, and it is never modified.** On *read*, taps are snapped to the nearest
silence between words (±0.75 s, tuned from your real tap data). If a better
snapping rule ships later, it re-derives better boundaries from the untouched
raw taps. If there's no gap to snap to, the boundary is kept and flagged
approximate.

Voices are a per-journal "Two voices" toggle, remembered across launches.
Paragraph marking works regardless of the toggle.

Rendering: the detail screen cuts the transcript into paragraphs at every
paragraph tap and every voice switch — `BN:` prose in italic, `LN:` regular.
Entries with no markers render exactly as before.

Details: [markers design](plans/2026-08-05-capture-structure-markers-design.md),
[voice rendering](plans/2026-08-08-voice-attributed-rendering-plan.md)

## 5. The transcript: a chain of snapshots, and editing it (T6 + T7)

The mental model is closest to **a tiny git for one entry's transcript**:

- A **revision** is a complete snapshot of the transcript text — not a diff.
  It's one immutable file (`canonical-0.json`, `canonical-1.json`, …), written
  once, never edited. Higher file numbers do NOT mean newer.
- Every revision names its **parent**, so revisions form a chain. Two kinds:
  **machine** revisions (the transcriber produced this) and **human** revisions
  (you edited, or you accepted/declined a machine's proposal).
- **"Current" is computed, never stored**: the newest revision on the human
  side of the chain wins. `head.json` just caches that answer — delete it and
  the same answer is re-derived from the revision files.
- If any revision file is unreadable, the entry becomes **read-only** rather
  than letting you edit a version with a sitting silently missing from it.

```mermaid
flowchart LR
    live["live.jsonl\n(machine log)"] -- "promotion\n(automatic)" --> r0["rev 0\nmachine"]
    r0 -- "you edit\n(splice)" --> r1["rev 1\nhuman"]
    r1 --> r2["rev 2\nhuman"]
    r2 -- "revert" --> r0
    retr["retranscription\n(T8, future)"] -. proposes .-> m2["rev M\nmachine"]
    m2 -- "accept / decline\n(T8, future)" --> r3["rev 3\nhuman"]
    r2 --> r3
```

**Promotion** (automatic, invisible): the live machine log is folded into
revision 0, so the chain always starts from what the machine actually heard.
Runs at finalize, at app launch, and when you open an entry.

**Editing (T7 — built, on `t7/editor-ui`, pending Gate B + PR).** A full-screen,
plain-text editor (Done only — no discard; see revert below for the undo story).
While you type, your text sits in a `draft.json`. When the edit session ends
(done, 90 s idle, 60 min cap, or crash recovery), the draft is **spliced**
against the text you were editing — a diff figures out which pieces you kept
and which you changed — and a new human revision is minted. An unchanged draft
mints nothing. **Voice attribution survives edits** (Task 5): BN/LN paragraph
rendering re-derives from the edited revision's own spans, not just the
untouched machine transcript, so editing a two-voice entry no longer silently
flattens it to one voice.

**Word-level audio anchors.** Each piece of text in a revision (a *span*)
remembers which audio frames it came from, with an honesty grade:

- **exact** — the machine measured these frames for exactly this text
- **inherited** — edited text; frames borrowed from the words it replaced
- **none** — typed from nothing; no audio claim at all

Edits can only *degrade* precision (exact → inherited → none), never invent it.
The one exception: accepting a machine revision adopts its measured anchors
verbatim. This is what will make tap-a-word-to-play-the-audio honest (#13).
One more exception, owner-ruled and landing as **Task 9b** (still in flight): a
wholesale word replacement with zero character overlap ("Ellen" → "LN") will
**inherit** the replaced word's frames rather than degrading to a zero-length
`none` point — the retyped word IS the heard word, corrected, and a zero-length
anchor asserts something untrue about where it lives in the audio.

**Marker correction (T7 Task 6).** Mis-tapped voice/paragraph markers are fixed
in their own mode, not inline in the editor: retract a stray tap, correct a
voice at an existing boundary, or add a boundary that was never tapped at all
(anchored to a word you pick in the text). Raw taps on disk are never touched —
corrections append to `markers.jsonl` as their own record kind, and every
reader folds them in before snapping/attribution runs.

**Revision history + revert (T7 Task 8).** A separate screen lists the WHOLE
chain — current, its ancestors, and every detached machine revision, clearly
labeled — and lets you revert to any of them. Revert mints a new revision (nothing
is ever destroyed); it is the editor's entire undo story, since the editor itself
has no discard.

**Metadata audit log (T7 Task 7).** Journal moves, backdates, and trash/restore
are appended to `entry-log.jsonl` — written and exported, no UI yet (deliberate
v1 scope; see §7 of the T6 design).

**Retranscription (T8, future):** a better model re-reads the m4a and proposes a
new machine revision. It never touches your text — you **accept** it (it becomes
current), **decline** it (recorded, stays visible off to the side), or later
**revert** to it using the mechanism T7 already built. All three are just new
revisions; nothing is ever destroyed.

Details: [T6 design](plans/2026-08-03-t6-revision-chain-design.md) (§15/§15b =
T6 as-built rulings, §16 = T7 as-built rulings),
[T6 build plan](plans/2026-08-08-revision-chain-implementation-plan.md),
[T7 build plan](plans/2026-08-09-t7-editor-ui-plan.md)

## Where the project is

```mermaid
flowchart LR
    M1["M1 capture ✅"] --> M2["M2 live transcript ✅"] --> M3["M3 journals + library ✅\n(search pending)"] --> T6["T6 revision chain ✅"] --> T7["T7 editor UI\n◀ Gate B + PR next"] --> T8["T8 retranscribe"] --> M4["M4 iCloud sync"] --> M5["M5 reading polish\n+ export + migration"]
```

Shipped and dogfooding on the phone: indestructible capture, live on-device
transcription, journals, backdates with spoken-date detection, library, trash,
markers with voice rendering, and the revision-chain storage layer (T6, PR #45
merged). Built on branch `t7/editor-ui`, not yet merged: the editor itself,
voice attribution surviving edits, marker correction, revision history +
revert, and the metadata audit log — everything in §5 above except Task 9b
(splice-inherit) and the whole-branch Gate B review + PR.

Next, in order:

1. **T7 — Task 9b, then Gate B, then PR.** Task 9b lands the splice-inherit
   ruling (§16.5 of the T6 design); Gate B is the adversarial whole-branch
   review; Nico merges the PR (auto-mode can't `gh pr merge`). Deferred out of
   T7 on purpose (owner-ruled, non-goals in the T7 plan): per-hunk merge/diff
   UI, accept/decline (no machine revision arrives until T8), collecting typed
   corrections into a vocabulary list for #38's biasing (#37 stays edit-time
   only), tap-a-word-to-play (#13), cross-paragraph text selection.
2. **T8 — retranscription** from the m4a, plus contextual biasing so "LN" stops
   transcribing as "ellen" (#38), and the accept/decline UI T7 deliberately
   left uncalled.
3. **Capture-landing redesign** — approved direction: global journal focus,
   journal rows with per-journal settings, post-stop receipt, marker thumb bar,
   icon-blue accent ([decisions](plans/2026-08-08-capture-landing-decisions.md)).
   Owed first: the BN/LN serif-vs-sans font mock. Then Mail-style swipe (#27)
   gated by per-journal delete friction (#35).
4. **M4 — CloudKit sync** (private iCloud DB). Done = delete the app, reinstall,
   everything comes back. Only after this: migrate the 36 frozen recountly.org
   entries in and tear the web app down
   ([data model + migration](plans/2026-07-29-data-model-and-migration.md)).
5. **M5 — reading polish**, search, verified open-format export.

## Reading the docs

The design docs are decision records — they keep their history, superseded
sections and all, which is why they're hard to skim. Rules of thumb:

- **This file** is the current model. When it disagrees with an old doc
  section, a newer amendment (like T6's §15/§15b) usually explains why.
- The plan of record for milestones is
  [native-rebuild-plan.md](native-rebuild-plan.md); the M3 plan supersedes its
  M3/M4 ordering.
- [user-journeys.md](user-journeys.md) is the intent document — nine
  walk-throughs of how you actually use it.
- Anything named `…-build-prompts.md` or `…-implementation-plan.md` is an
  executed build recipe kept for the record.
