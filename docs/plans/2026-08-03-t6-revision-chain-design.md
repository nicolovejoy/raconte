# M3 T6 — the revision chain (design, rev 2)

Plan of record: `docs/plans/2026-08-02-m3-dogfood-mvp-plan.md` (T6, lines 92–94). Builds on
`docs/plans/2026-07-30-m2-transcription-design.md` §3 (transcript on disk), §5
(retranscription), §11 (replay, decoder rule, the three-answer rule), §12. Forward contract
with `docs/plans/2026-07-29-data-model-and-migration.md` §1–§3 (GRDB, CloudKit, export).
Issue #13 is a hard constraint on the format and is designed for here, not built here.

**Rev 2, 2026-08-03.** Rev 1 went through two adversarial passes; every code citation held,
every failure was inferential, and both reviewers landed on the same named failure mode:
rev 1 reasoned about *steady state* instead of this codebase's two recurring bite marks —
**concurrent unserialized readers on one tree**, and **a failed read collapsing into
"empty."** Rev 2 is designed around those from the start rather than patched. §13 is the
changelog and the finding map.

---

## 0. The governing rules this design inherits

Restated because every decision below is downstream of one of them.

1. **Audio is ground truth; text is a derived, replaceable interpretation**
   (`native-rebuild-plan.md:12-14`). A revision is an interpretation, not a fact.
2. **Human edits are never destroyed by a machine pass** (M3 plan line 29,
   `native-rebuild-plan.md:25-28`). The chain must be able to say "a machine disagrees with
   you" without acting on it.
3. **Transcript time = capture-frame time = position in `final/recording.m4a`** (M2 §2).
   The only durable anchor. `analyzerStart`/`analyzerEnd` are revision-local and
   cross-revision incomparable (`TranscriptRecord.swift:77-81`).
4. **Disk is the single authority** (M3 plan, "Architecture stance"). A database is a
   rebuildable cache, never a second truth.
5. **Degrade, never skip; three answers, not two** (M2 §11.3). Absent ≠ unreadable, and a
   failed read is never "empty".
6. **Quarantine, never delete**, for anything irreplaceable (`RecoveryPlanner.swift:84-86`,
   `DirectorySnapshot.swift:72`).
7. **Hand-written decoders**: additive lenient, identity strict; no `schemaVersion` until
   there is something to migrate (M2 §11.4).
8. **One implementation of any rule.** Two implementations that must agree forever is how
   they stop agreeing (M2 §11.2).
9. **The read path never writes.** Added in rev 2. `LibraryScanner` is nonisolated,
   stateless, and reads through static seams by construction, and
   `LibraryScreenModel.swift:74-78` states in its own words that *"scans overlap"* —
   `rescan()` is called from thirteen sites. Any write reachable from a scan is a write
   racing an unknown number of copies of itself, plus `TrashSweeper`'s atomic rename of
   the whole capture directory into `trash-pending/` via `StagedRemover.stage`
   (`TrashSweeper.swift:89`, `StagedRemoval.swift:39-61`) — the purge that actually
   deletes the bytes runs later, outside every scanned tree.

---

## 1. Goals / non-goals

**Goals.**

- An on-disk revision chain per capture that represents machine and human lineages
  honestly, is append-only, is rebuildable from the files themselves, and **converges on
  two devices without rewriting any file**.
- A promotion path from `live.jsonl` (revision zero, in a different format) to an
  addressable canonical revision, display-identical to what the entry already shows.
- A batching rule that turns keystrokes into revisions (M3 plan: "per editorial session or
  per hour, whichever is shorter").
- A text representation that carries capture-frame anchors through human edits and degrades
  them monotonically and visibly — the format half of issue #13.
- Exact semantics for a machine retranscription arriving under human edits (T8), including
  accept, decline, and revert.
- A decision on where metadata edits are audited, and the shape of whichever is chosen.
- Forward-compat with the GRDB/CloudKit schema, with tensions named rather than designed
  around.

**Non-goals.**

- The editor UI, the revision-history panel, the diff presentation (T7).
- The retranscription *worker* — the second finalize-queue job kind, the ~two-analyzer
  budget, the coverage-gap trigger (T8; M2 §5, §9 T6).
- Tap-to-play itself (#13). This doc makes it buildable; it does not build it.
- Real punctuation and spacing repair. Rev 1 claimed it; rev 2 explicitly gives it up
  (§4.2, F16/C3) and leaves it to a future machine revision.
- Search/FTS (recorded in §9, built with GRDB).
- The journal switcher (#18). It touches this work only in that entry-detail chrome gains a
  revision affordance and both should land in one T7 design pass. No format impact.

---

## 2. The revision model

### 2.1 What a revision is

An immutable, addressable, self-describing document holding **the whole transcript text of
one entry at one point in its editorial history**, as an ordered array of anchored spans,
plus its provenance and its parentage. Written once, never modified, never deleted.

Not a diff. Storing diffs would make reading revision *n* an O(n) fold with a second
implementation of the splice rules (rule 8). Whole-text revisions are O(1) to read; §9.5
prices them honestly.

Two axes of provenance, deliberately separate:

- **`source`** — who authored *this* revision: `machineLive`, `machineRetranscribe`,
  `userEdit`, `merge`, `import`.
- **`basedOnMachineID`** — which machine revision this text descends from. Carried by every
  human-lineage revision. Without it a retranscription diff has no base and degenerates
  into a two-way diff that reads every correction the owner made as a conflict (§6.3).

`source.isHumanLineage` is `userEdit | merge | import` — **one predicate in one place**, not
a set literal repeated at each site. `import` counts as human because the migrated web
transcript is the owner's text (§8.3).

### 2.2 One chain, two lineages, no local ordering

One append-only chain per capture: `transcript/canonical-<n>.json`. `SegmentLayout` already
declares this naming and its inverse parser (`SegmentLayout.swift:116-133`).

**`n` is a filename and nothing else.** It is not an order, not an identity, and it does not
appear in the file body. Rev 1 stored `revision: Int` in the body and ordered by it; that
broke three ways at once (A1, F2): a synced-in revision written at the next free local `n`
either has to be rewritten (immutability gone) or permanently contradicts its own filename
while being a strict-decode identity field; two devices that interleave differently by `n`
resolve "highest" differently and never converge; and §9.1's own escape hatch guaranteed
data loss.

**The total order is `(createdAt, id)`** — `createdAt` is an instant, `id` is a ULID, and
ULIDs are already lexicographically time-sortable (`ULID.swift:3-5`). Device-independent,
stable, computed identically everywhere. Every "highest", "latest", "downstream", and "tip"
in this document means this order and only this order.

The machine lineage is the subsequence with `source ∈ {machineLive, machineRetranscribe}`;
the human lineage is `isHumanLineage`. They interleave in one chain because ordering-in-time
is the one fact that must never be ambiguous, and because a merge genuinely has two parents
(`parentID` on the human side, `basedOnMachineID` on the machine side).

### 2.3 Attachment and "current" are read-time derivations

Rev 1 stored `detached: Bool` at write time. That field is **gone** (A1, F1, F2): a flag
computed against one device's chain is wrong the moment another device's revision arrives,
and it cannot be corrected without rewriting an immutable file.

Given the readable revisions of one capture, ordered by `(createdAt, id)`:

```
humanTip    = last revision with source.isHumanLineage        (nil if none)
ancestry(R) = transitive closure of R over parentID and basedOnMachineID

attached(R) = R.source.isHumanLineage
            || humanTip == nil
            || humanTip.id ∈ ancestry(R)

current     = the greatest attached revision under (createdAt, id)
```

In words: **a machine revision is detached iff it does not descend from the human tip.** A
human revision is always attached — a person only ever appends on top of what they were
looking at.

Walked against the failures that killed rev 1:

- *F1's machine-after-machine.* rev0 machineLive → userEdit A → userEdit B →
  machineRetranscribe M1 (parent rev0) → machineRetranscribe M2 (parent M1). humanTip = B;
  ancestry(M2) = {M1, rev0}; B ∉ it ⇒ M2 detached. Rev 1's rule made M2 *attached* and
  silently ate two sittings of edits.
- *A1's data loss.* B edits offline (Y); A, not having seen Y, retranscribes (M, later
  `createdAt`). After sync both devices hold {rev0, Y, M}. humanTip = Y on both;
  ancestry(M) = {rev0} ⇒ M detached on both; current = Y on both. The correction survives,
  and the "a newer machine transcript is available" marker appears — **on A too, where M was
  current before the sync**. Attachment flipping on arrival is the correct behaviour and
  costs no file rewrite, which is exactly why it must be derived.
- *A1's divergence.* A mints userEdit X, B mints userEdit Y concurrently. Both are human,
  both attached; current = the later of the two by `(createdAt, id)` — **the same one on
  both devices**. Converged.

That last case is last-writer-wins on human text, which is real and is named, not hidden:
when two human-lineage revisions exist and neither is in the other's ancestry, the entry is
**forked**. `forkedHumanLineage` is a derived predicate and a surfaced marker; the losing
sitting is still a revision on disk, listed in history, and mergeable by hand. Multi-device
editorial is gated behind T9 by the M3 plan (line 35), so this is a marker, not a merge
engine — but a silent LWW would have been rule 2 broken by omission.

**Cost note.** The derivation is O(revisions) with an ancestry walk. It runs when the detail
screen or the editor opens, never on the library scan — the scan reads `head.json`'s
`current` summary (§4.3).

Rejected, again and for the same reason as rev 1: a `currentRevision` pointer in the
manifest. It would be a fourth unserialized manifest writer — `finishCurrentCapture()`
documents the three existing ones in its own comment (`CaptureView.swift:405-412`), and
`FinalizerWorker` reads and writes across its encode+verify awaits, silently reverting
anything written into that window.

`TranscriptRef.latestRevision` (`Manifest.swift:109`) is declared and never written — the
sole construction site passes `nil` (`LiveTranscription.swift:135`). It stays unwritten and
is documented as deprecated-in-place. Under §2.2 there is no "latest revision number" worth
recording anyway.

### 2.4 Promotion — `live.jsonl` → `canonical-<n>.json`

The live log **is** revision zero, in a deliberately dumber format (M2 §3, §11.2).
Promotion mints the first canonical revision from it.

Definition: fold the log through `LiveTranscriptReader.consolidate`
(`LiveTranscriptStore.swift:287-293`) — the one implementation of the overlap/revocation
rules — then map `TranscriptConsolidator.committed` into spans (§5.2).

Properties:

- **Deterministic and idempotent** in content: the same log yields the same spans, so a
  re-promotion after a crash is semantically identical. `createdAt` and `id` differ between
  attempts, which is why promotion must not be re-attempted blindly — see §5.1's once-only
  rule.
- **Display-identical.** Promotion changes no glyph on screen. New in rev 2 (F16, C3) and
  enforced by construction: `plainText` uses the *same join function* as
  `TranscriptConsolidator.committedText`, factored out and called by both paths (§4.2).
- **Never destructive.** `live.jsonl` is kept forever (decided, §12.D3). It is the crash
  evidence, the `committedRecords` cross-check (`LiveTranscriptReader.completeness`), and
  the only record of the analyzer's own timebase.
- **Never a prerequisite for reading.** A capture with a log and no canonical revision still
  renders exactly as today, via `EntryTranscriptLoader.load` (`EntryTranscript.swift:41-61`).

Correction to rev 1 (C4): a crashed promotion **does** leave a stray
`canonical-<n>.json.part` behind — `AtomicFile.replace` writes `.part`, fsyncs, closes, then
renames (`AtomicFile.swift:26-49`), and its own doc comment names the stray-`.part` case as
the on-disk situation recovery must tolerate. That stray keeps `transcriptPresent` true and
the directory quarantined, which is correct: a `.part` is exactly the file you must not
delete (`DirectorySnapshot.swift:207-215`).

Why promote at all, given the log already renders:

1. `LibraryScanner` re-reads and re-consolidates every capture's log on **every** scan, by
   its own admission (`LibraryScanner.swift:40-45`).
2. Editing needs a stable base to diff against.
3. Spans need an owner: `TranscriptRun` bounds are optional per the SDK
   (`TranscriptRecord.swift:29-38`), so the anchor lattice (§3.2) must be resolved once, at
   promotion, not re-derived per read.

### 2.5 Batching keystrokes into revisions

The editor does not write revisions. It writes a **draft**: `transcript/draft.json`, one
JSON document rewritten via `AtomicFile.replace`, debounced ~2 s idle and forced on editor
blur, scene-phase change, and window close. The file is created lazily at the first append —
never at editor open (§4.4, rule A2b).

A draft closes into a revision at the earliest of:

- **session end** — defined *purely from disk*: `now - lastWriteAt > 90 s`. Rev 1 said
  "editor dismissed, entry deselected, or the app backgrounded", which is UI state the store
  actor cannot see and which two implementers would read differently (F7). The editor may
  *ask* the store to close a draft immediately when it is dismissed; that is an
  optimisation, and the 90 s rule is the definition.
- **the hour cap** — 60 minutes since `openedAt`. On close a fresh draft opens continuing
  the same edit, so a long sitting yields hourly revisions.
- **an incoming machine revision** for the same entry — see §12.Q4, which asks whether this
  should instead queue.

A draft whose text equals **current** closes to nothing: the file is deleted and no revision
is minted. Rev 1 compared against the draft's *parent*, which mints a byte-identical
duplicate when a crash lands between the revision write and the draft delete (F7).

Crash mid-draft: the draft survives (atomic replace). Stale drafts are closed by an explicit
store call at launch and at entry-open — **never from the library scan** (rule 9, §4.6).

A draft is irreplaceable human text and is protected by the existing quarantine guard for
free: `transcriptPresent` is "any file at all" in `transcript/`
(`DirectorySnapshot.swift:207-216`).

"Session or hour, whichever is shorter" (M3 plan line 28) is satisfied exactly. The 90 s
grace and the 2 s debounce are the two numbers this design invents (§12.Q1).

---

## 3. Time anchoring (#13) — the part that drives the format

Issue #13: tap a sentence, play the audio of what was actually said there; the work is
"keeping anchors valid across human revisions."

### 3.1 Per-span, not per-token

A revision's text is an ordered array of **spans**. A span is a contiguous stretch of text
sharing one anchor and one provenance.

Machine revisions start at the transcriber's own run granularity —
`SpeechAnalyzerEngine.runs(of:inputRate:)` (`SpeechAnalyzerEngine.swift:187`) flattening
`AttributedString` runs into `TranscriptRun` (`TranscriptRecord.swift:39-55`). Word-level in
practice on the mini, but **the SDK guarantees nothing**: runs need carry no time range, and
timed runs need not be contiguous (`TranscriptRecord.swift:29-38`, M2 §11.5.2); M2 §10.7 is
still open.

So: do not re-tokenize into words ourselves. A word-level model we synthesize would be a
second, worse implementation of an alignment we do not have (rule 8).

### 3.2 The anchor lattice

Each span carries `anchor: exact | inherited | none`.

- **exact** — frames came from a transcriber run over unedited text. Tapping plays the words
  that were said.
- **inherited** — the text has been edited, inserted, or was never individually timed; the
  frames are those of an enclosing or neighbouring span. Tapping plays *near* the words.
  Presented as approximate.
- **none** — no frame information exists anywhere upstream (imported text, an insertion with
  no preceding anchor). Not tappable.

**Anchors degrade monotonically under `userEdit`.** Only a machine revision mints `exact`;
the only routes back up are `merge`-adopted machine spans (§6.3) and revert (§6.5), both of
which carry text and frames across *together*, unmodified, from a single measurement. Rev 1
stated the invariant without the merge exemption and then wrote a property test that
contradicted §6.3 (F18); §10 now scopes it correctly.

The anchor kind is stored rather than inferred from "has frames", because "has frames"
cannot distinguish a measured anchor from an inherited one, and showing an inherited anchor
as exact is precisely the lie #13 is about.

### 3.3 Splice rules

A human revision is produced by diffing the draft text against **current**'s flattened text
and rewriting the span array:

- **Unchanged span** — copied verbatim: same text, frames, `anchor`, `sourceRevisionID`.
- **Span edited in part** — split at the edit boundaries; **both sides drop to `inherited`
  and keep the parent span's full bounds.** Rev 1 had a branch preserving `exact` over a
  sub-range "if the span had per-word bounds", which is unexpressible — `TranscriptSpan`
  carries one frame pair and §3.1 refuses to synthesize word alignment (F17). Deleted.
- **Insertion** — a new span, `anchor: inherited`, frames = a zero-length point at the
  preceding attached span's `frameEnd`; `.none` if there is no preceding anchored span.
  **Exception (§16.5, owner ruling 2026-08-11, as-built Task 9b):** when the inserted
  text is a WHOLESALE, ZERO-CHARACTER-OVERLAP replacement of exactly one parent span
  (every character of that span removed by the diff, nothing else mixed in, immediately
  followed by the new text — e.g. "Ellen" -> "LN"), the new span inherits the REPLACED
  span's own bounds instead of the zero-length point — a real, non-zero-length interval
  when the replaced span had one, or `.none` (never the zero-length-point fallback) when
  it didn't. The retyped word IS the heard word, corrected, not a new word spoken at a
  single instant. Multi-span replacements, partial-span edits, and plain deletions with
  nothing typed in their place all keep the rule as originally stated above.
- **Deletion** — the span disappears. **Frames are not redistributed.** Unclaimed audio is
  honest; stretching a neighbour fabricates alignment.
- **Move** — delete + insert, unless the editor reports a move, in which case frames and
  `anchor` travel with the text. Span order is *reading* order, so frames may then be
  non-monotonic across the array, and **may overlap after a per-hunk merge** (§6.3). Every
  consumer must tolerate both; machine revisions are monotonic and non-overlapping, and code
  will quietly assume that unless told.

**Span-count growth** is bounded at revision close by merging adjacent spans that share
`anchor == .none`, or share `anchor == .inherited` **and** identical bounds **and** identical
`sourceRevisionID`. Lossless. Adjacent `exact` spans are never merged — their distinct frames
are the point.

### 3.4 What a consumer does with this

Tap-to-play (T7/#13, not built here): find the span containing the tapped character; if its
anchor is `.none`, walk back to the nearest span with frames; seek to `frameStart`.

Two concrete gaps, from review (nits): **`CapturePlayback` has no frame-based seek** —
`seek(to:)` takes seconds (`CapturePlayback.swift:162`) — so `CapturePlayback.seek(toFrame:)`
must be added, mirroring `SegmentPlayer.seek(toFrame:)` which already exists; and
`PlaybackSeek.frame(forSeconds:sampleRate:)` returns `Int` (`PlaybackSeek.swift:41`) while
spans store `Int64`. The conversion belongs in `PlaybackSeek`, once, with the width mismatch
resolved there rather than at call sites.

---

## 4. On-disk format

### 4.1 Layout

```
captures/<captureID>/
  manifest.json              capture machine; +1 optional field for T10 (§8.3)
  entry.json                 user metadata sidecar (M3 T1)
  entry-log.jsonl            NEW — metadata audit (§7); local-only, never synced
  final/recording.m4a
  transcript/
    live.jsonl               unchanged; revision zero's raw form, kept forever
    canonical-<n>.json       NEW writer — the revision chain
    head.json                NEW — rebuildable scan cache (§4.3)
    draft.json               NEW — open editor buffer; device-local, never synced
```

`SegmentLayout` additions, alongside the existing `transcriptDirectory` /
`liveTranscriptURL` / `canonicalTranscriptURL(revision:)` / `canonicalRevision(fromFileName:)`:

```swift
static let transcriptHeadFileName  = "head.json"
static let transcriptDraftFileName = "draft.json"
static let entryLogFileName        = "entry-log.jsonl"
static func transcriptHeadURL(captureDirectory: URL) -> URL
static func transcriptDraftURL(captureDirectory: URL) -> URL
static func entryLogURL(captureDirectory: URL) -> URL
```

### 4.2 The revision document

```swift
struct TranscriptRevision: Codable, Sendable, Equatable {
    // Identity — strict on decode.
    var id: String                 // ULID. The only identity, local and synced.
    var source: RevisionSource     // machineLive | machineRetranscribe | userEdit
                                   //   | merge | import | unknown(String)
    var createdAt: Date            // with `id`, the total order (§2.2)
    var spans: [TranscriptSpan]    // may be empty; the KEY must be present

    // Parentage — lenient (absent = root).
    var parentID: String?          // the revision this was authored from
    var basedOnMachineID: String?  // the machine revision this text descends from (§6.4)

    // Machine provenance — lenient; nil on human revisions.
    var generator: String?         // "SpeechTranscriber" | "DictationTranscriber"
    var locale: String?
    var coverageFrames: Int64?
    var skippedRanges: [FrameRange]?

    // Editorial provenance — lenient.
    var deviceID: String?           // stable per-install ULID; §9 provenance
    var closedBy: DraftCloseReason? // sessionEnd | hourCap | machineArrival
                                    //   | recovered | unknown
}

struct TranscriptSpan: Codable, Sendable, Equatable {
    var text: String               // strict
    var anchor: SpanAnchor         // exact | inherited | none; absent OR unknown ⇒ .none
    var frameStart: Int64?         // capture frames; nil iff anchor == .none
    var frameEnd: Int64?
    var confidence: Double?        // omitted entirely when absent; nil is not zero
    var sourceRevisionID: String?  // omitted when == the containing revision's id (§9.5)
}
```

**`revision: Int` is gone** (F2). The filename integer is derived from the path when needed
and never stored.

**`detached: Bool` is gone** (A1, F1, F2). Attachment is derived (§2.3).

`plainText` is **not** stored. It is `spans.map(\.text)` joined by `TranscriptText.join(_:)`
— **the same function `TranscriptConsolidator.committedText` calls**, factored out of
`TranscriptConsolidator.join` (`TranscriptConsolidator.swift:125-129`) in T6a. One
implementation (rule 8), and three consequences that all mattered:

- Promotion changes no displayed text (F16). Rev 1's "spans carry their own whitespace, join
  is plain concatenation" made the same capture render differently before and after
  promotion — a visible text change caused by background housekeeping.
- `SpokenDateDetection` keeps reading the same leading token across the promotion boundary
  (C3). It reads `EntryTranscript.text` (`CaptureView.swift:431`), `SpokenDateParser` is
  gated to raw token 0, and `detectionRan` is a once-only latch
  (`EntryMetadata.swift:78-87`) — so a spacing change would give pre- and post-T6 entries
  different answers from identical audio, permanently.
- A tap on inter-sentence whitespace can no longer play the previous sentence (nit), since
  spans hold no boundary whitespace.

Real spacing and punctuation repair is therefore **still owed** and is explicitly not T6's
(§12.Q5).

### 4.3 `head.json` — an O(1) scan cache, and only a cache

```swift
struct TranscriptHead: Codable, Sendable, Equatable {
    /// What the scan needs. One row, not one per revision.
    var current: TranscriptHeadSummary?   // id, filename n, source, createdAt,
                                          // characterCount, firstLine, isForked
    var revisionFiles: [Int]              // filenames seen, readable or not
    var unreadableFiles: [Int]            // subset that failed to decode (F6)
    var revisionCount: Int
}
```

Rev 1 stored a row per revision with `firstLine`/`characterCount` each, validated on every
scan — reintroducing the O(revisions)-per-entry-per-scan cost it existed to remove, and
unbounded for a heavily edited entry (F15). Rev 2 stores **one** summary; the history panel
reads the revision files directly when it opens, which is the only time anyone needs them.

Rules:

- **Written only from inside `TranscriptRevisionStore`, never from a read** (A2, rule 9).
- **Validated, never trusted.** On read, compare `revisionFiles` against the store's own
  three-answer directory listing (§4.5). On mismatch, absence, or unreadability, the head is
  **rebuilt in memory** and used; persisting the rebuild is queued to the store, not done
  inline.
- `unreadableFiles` is what makes validation a **fixed point** (F6). Rev 1's rebuild dropped
  an undecodable `canonical-3.json`, so the rebuilt set never matched the directory listing
  and every scan re-read the whole chain and rewrote the head, forever. (`.part` files cannot
  cause this: `canonicalRevision(fromFileName:)` requires a `.json` suffix —
  `SegmentLayout.swift:123`.)
- The head holds **no** `nextRevision`. §4.5's allocation rule reads the directory.

### 4.4 Write modes and crash behaviour

| file | mode | crash outcome |
| --- | --- | --- |
| `canonical-<n>.json` | **create-once** (§4.5) | stray `.part`; no revision appears; retry allocates a fresh `n` |
| `head.json` | rewrite, `AtomicFile.replace` | stale-but-valid, or absent → rebuilt |
| `draft.json` | rewrite, `AtomicFile.replace`, debounced, created lazily | last debounced state survives; closed on next explicit store pass |
| `live.jsonl` | append-only, `O_APPEND` | torn trailing line dropped (unchanged) |
| `entry-log.jsonl` | append-only, `O_APPEND`, newline fuse (§7.2) | torn trailing line dropped; tail loss undetectable and accepted |

Whole-document files get `.part` staging because a torn one has nothing to salvage;
line-structured files get `O_APPEND` because every prior line stays valid. That is the split
`EntryMetadataStore` reasons about explicitly (`EntryMetadataStore.swift:16-19`) and
`LiveTranscriptWriter` documents (`LiveTranscriptStore.swift:30-41`).

**A2b — `transcript/` is created only by a write that carries content.** Never by opening a
head, never by opening a draft, never by a read of any kind. This is the T3 lesson verbatim
(M2 §11.6): `LiveTranscriptWriter.open()` `O_CREAT`s a zero-byte log, `transcriptPresent` is
"any file at all", so creating the directory eagerly flips `holdsIrreplaceableArtifacts` →
`RecoveryPlanner` rewrites `.deleteCaptureDirectory` into the on-disk no-op
`.quarantineCaptureDirectory` (`RecoveryPlanner.swift:84-86`, `RecoveryExecutor.swift:68-71`)
→ every sub-0.5 s mis-tap leaves a permanently undeletable directory that
`LibraryScanner.holdsSomethingToShow` then lists as an entry forever. Rev 1 reintroduced it
in two places (head-written-from-a-read, draft-on-open).

### 4.5 Allocating and writing a revision: create-once, three answers

Rev 1 said "create-once via `AtomicFile.replace`". `AtomicFile.replace` is **not**
create-once: it opens the `.part` `O_WRONLY|O_CREAT|O_TRUNC` and finishes with POSIX
`rename()`, which silently replaces an existing target (`AtomicFile.swift:26-49`). There is
no `O_EXCL` in the file. So rev 1's "never overwritten" invariant rested entirely on
`max(n)+1` being right — and rev 1 sourced that from `DirectorySnapshot.canonicalRevisions`,
built from `(try? fm.contentsOfDirectory(...)) ?? []` (`DirectorySnapshot.swift:203`). An
unreadable `transcript/` — permissions, I/O error, a Data-Protection-locked container during
a background wake — yields `[]`, `max(n)+1 == 0`, and the next append **overwrites
`canonical-0.json`**, the machine base every `basedOnMachineID` points at. Precisely
`LiveTranscriptWriter.open()`'s `nextSeq` bug (M2 §11.3), which rev 1 cited as precedent
without inheriting its remedy (A3).

Rev 2, two parts:

**(a) The store does its own three-answer listing.**

```swift
enum TranscriptChainListing: Equatable {
    case absent                    // no transcript/ — the honest "no revisions"
    case unreadable(String)        // it is there and we failed at it
    case present(files: [Int])     // filenames parsed by canonicalRevision(fromFileName:)
}
```

`.unreadable` **refuses to append** and throws, exactly as `LiveTranscriptWriter.open()`
does. Failing costs this edit; continuing costs the chain. `DirectorySnapshot`'s
`canonicalRevisions` stays as-is and is documented as a *display stat only, never an
allocation input*; T6a adds `transcriptDirUnreadable: Bool` beside it, mirroring
`manifestCorrupt`, so the scan can also stop pretending.

**(b) The append is genuinely create-once.** `AtomicFile` gains a `createExclusively`
sibling: write `.part`, fsync, close, then `renamex_np(part, final, RENAME_EXCL)` — available
on both deployment targets — so a name collision returns `EEXIST` rather than silently
replacing. On `EEXIST` the store re-lists, allocates the next free `n`, and retries once; a
second collision throws. `AtomicFile.replace` is unchanged and keeps serving `head.json` /
`draft.json` / `entry.json`, which are meant to be replaced.

`n = max(present files) + 1`, from the listing, inside the actor. The head is never an
allocation input.

### 4.6 Who writes, and what the read path may do

A `TranscriptRevisionStore` actor, shaped like `EntryMetadataStore`
(`EntryMetadataStore.swift:20-54`): serialized across all entries, with `nonisolated static`
**read-only** seams for the format so `LibraryScanner` can read without the write
serialization.

**The scan never writes** (rule 9). Concretely, the three things rev 1 put on the scan path
and where they went:

| rev 1 put on the scan | rev 2 |
| --- | --- |
| head rebuild-and-rewrite | rebuild in memory; persist only from the store |
| lazy promotion "at first read" | explicit store calls: a one-shot launch pass and entry-detail open (§5.1) |
| stale-draft close "on next scan" | same explicit calls, serialized by the actor |

All three skip any capture whose sidecar reports `trashedAt != nil`. Without that,
`TrashSweeper.run()` — a detached task fired right after a scan, staging the whole capture
directory out of `captures/` via `StagedRemover.stage`'s atomic `rename(2)` into
`trash-pending/` (`TrashSweeper.swift:89`, `StagedRemoval.swift:39-61`) — races a concurrent
revision write that **recreates the tree** after the rename has already vacated
`captures/<id>/`, leaving a directory holding one canonical revision, no `entry.json` (so no
`trashedAt`), and no audio → `holdsIrreplaceableArtifacts` true → permanent quarantine → the
entry reappears in the library as live. The owner's deletion undone by an editor buffer
(A2.3).

Nothing else writes into `transcript/` except `LiveTranscriptWriter`, which owns `live.jsonl`
alone.

**Update (#25 staged removal, step 3, landed early):** the read-side half of this rule
shipped ahead of T6. `LibraryScanner.build` now reads `entry.json` before the
durable-content gate and lists a capture whose sidecar reports `trashedAt != nil`
regardless of what else the directory holds, so a half-destroyed trashed capture no longer
reads as live. `EntryMetadataStore.update` also now refuses to write when
`captures/<id>/` is absent (`EntryMetadataError.captureMissing`), closing the ordinary
restore-after-stage ordering flagged by the write-side rule in §0.3.11 of
`docs/plans/2026-08-05-staged-removal-build-prompts.md`.
**T6 still owes the writer-side skip described above** — the head rebuild, promotion, and
stale-draft close paths must each skip a capture whose sidecar reports `trashedAt != nil`
before writing into `transcript/`. Neither of the #25 fixes reaches A2.3: that failure
leaves no `entry.json` behind to read (a canonical revision reappears with the sidecar
gone), so a read-side rule has nothing to consult and this write-side skip is still
load-bearing.

### 4.7 Decoder rules

Hand-written `init(from:)` on `TranscriptRevision`, `TranscriptSpan`, `TranscriptHead`,
`TranscriptDraft`, and `EntryLogRecord` (rule 7).

- **Strict** (throws): `TranscriptRevision.id`, `.source`, `.createdAt`, presence of the
  `spans` key; `TranscriptSpan.text`. A revision we cannot identify is not a revision; a span
  whose text we cannot read is content loss we must not paper over.
- **Lenient**: everything else, including all parentage, all provenance, all frame bounds.
- **One unknown-enum rule for all four enums** (F10). Rev 1 gave it to `source` only, so a
  future `SpanAnchor` case would throw → the span throws → the whole revision is undecodable
  → skipped → and per §4.8 the entry goes read-only. The rule: an unrecognized raw value
  **never throws**. `SpanAnchor` → `.none` (present-but-unknown and absent both, matching its
  "absent ⇒ `.none`" default); `RevisionSource` → `.unknown(String)`; `DraftCloseReason` and
  `EntryLogCause` → `.unknown`. An `unknown` source is treated as **machine lineage**
  (`isHumanLineage == false`) — the conservative reading, since mis-classifying an unknown
  revision as human would push a real human tip out of place.
- **No `schemaVersion`** (M2 §11.4 reasoning verbatim). Add the `Mirror` field-count tripwire
  T2.5 gave `writeCapturedManifest`, over `TranscriptRevision` and `TranscriptSpan`.

### 4.8 An unreadable revision makes the entry read-only

If **any** `canonical-*.json` in the chain fails to decode, the entry renders from the
highest readable attached revision **and the editor refuses to open**, showing why.

Rev 1 let editing proceed on the degraded read: revs 0–5, rev5 transiently unreadable (data
protection, an evicted iCloud file), current falls back to rev4, the owner edits, and the new
revision is diffed against rev4 — rev5's sitting is gone from the text and cannot be
reintegrated (F5).

Read-only-on-any-unreadable rather than "unreadable at-or-above current" for a concrete
reason: **order lives inside the file.** `createdAt` and `id` are in the body, so an
undecodable revision has no knowable position and "is it above current?" is undecidable. The
conservative rule is the only implementable one. It self-heals: the file becomes readable
again when the container unlocks or the asset materializes.

Degradations: `EntryDegradation.revisionUnreadable` alongside the existing
`.transcriptUnreadable` / `.transcriptTruncated` (`EntryListItem.swift:36-42`). If no revision
is readable at all, the entry falls back to `live.jsonl` rendering, and if that fails too, to
`.unreadable` — three answers all the way down.

---

## 5. Promotion, concretely

### 5.1 When

**Once per capture, from exactly two callers, both serialized by the store, neither on the
scan path** (A2, F8):

1. **At finalize** — `CaptureScreenModel.finishCurrentCapture()`, **after
   `recordTranscriptRef(for:)` and before `detectSpokenDate(for:)`**
   (`CaptureView.swift:414-415`). Rev 1 said "after `runFinalizer` returns", which is one
   step too early: the `TranscriptRef` does not exist in the manifest until
   `recordTranscriptRef` writes it (`CaptureView.swift:448-463`), so every revision would
   have been minted with `coverageFrames: nil` and `skippedRanges: nil` — silently, on the
   happy path, for every capture (B1). Placing it before `detectSpokenDate` also keeps
   detection reading the same text it reads today (§4.2).
2. **A one-shot launch pass** for the pre-T6 corpus and for captures killed before finalize,
   plus **entry-detail open** for anything the pass has not reached. "First read" is **not**
   the library scan — rev 1 left that ambiguous, and either reading was bad: yes meant the
   first post-T6 launch promotes the whole corpus through one serialized actor on the
   library-load path; no meant the stated benefit never arrives (F8).

Skipped, always: captures with `trashedAt != nil`; captures with no `final/recording.m4a`
(an abandoned scrap directory holding only a log must not gain a canonical revision and with
it permanent quarantine — F8); captures already holding a canonical revision.

That last clause is the once-only rule, and it is why promotion's content-idempotence is not
enough on its own: two promotions produce two revisions with different `id`s and
`createdAt`s, which is a fork of the machine lineage, not a no-op.

### 5.2 Log → spans

```
records      := LiveTranscriptReader.load(captureDirectory:).records   // torn tail dropped
consolidator := LiveTranscriptReader.consolidate(records)              // the one rule set
for result in consolidator.committed (already ordered by range.start):
    if result.runs is non-empty:
        one span per run
        anchor = .exact  iff both captureFrameStart and captureFrameEnd are present
                 .none   otherwise
    else:
        one span for the whole result, anchor = .inherited, frames = result.range
```

The runless branch is `.inherited`, not `.exact` (C1). `result.range` comes from chunk-stamp
arithmetic whose converter output wanders ~90 ms against its input (M2 §11, the
`emittedInRun` amendment); rev 1 gave the *least* timed case the *strongest* anchor label.
`exact` must never lie.

`sourceRevisionID` is omitted (it equals the containing revision's id). `generator`/`locale`
come from the records, which carry them per-record (`TranscriptRecord.swift:84-85`); if
records disagree — a mid-capture fallback from `SpeechTranscriber` to `DictationTranscriber`,
which `TranscriptionModuleSelector` does not do today but could — the revision records the
last record's generator and the disagreement is dropped. Noted so a reviewer need not
rediscover it.

`coverageFrames` / `skippedRanges` are copied from `TranscriptRef` (`Manifest.swift:98-135`)
so `needsRetranscription(against:)` can be answered from the revision alone once GRDB exists.

---

## 6. Retranscription arriving under human edits (T8)

### 6.1 The write

T8 runs `SpeechAnalyzer` over `final/recording.m4a` (M2 §5) and appends a revision with:

- `source: .machineRetranscribe`
- `parentID` = the previous machine revision's id, **or nil when there is none**
- `basedOnMachineID` = nil (it *is* a machine revision)
- **no attachment flag** — §2.3 derives it, on every device, at every read

There is no `detached` computation at write time and therefore no way for it to be wrong on
another device. That is the whole of the A1/F1/F2 fix.

### 6.2 Attached — the untouched-entry case

No human-lineage revision exists, so §2.3 makes the new revision current and the displayed
text changes. This is machine-over-machine: nothing a person did is at risk, and the
coverage-gap auto-retranscribe (M2 §5 trigger 1) is only useful if it replaces the gappy
text. Confirmed as intended (§12.Q2) — and rev 2 makes it *safe* by defining revert (§6.5),
which rev 1 left impossible (F4).

### 6.3 Detached — the case this design is for

Nothing displayed changes. The entry gains a marker ("a newer machine transcript is
available"). In T7 the owner opens a **three-way diff**:

- **base** = the revision identified by current's `basedOnMachineID`
- **theirs** = the new machine revision
- **mine** = current

**Nil base is a defined reading, not an omission** (F3). It happens in the two most likely
retranscription situations: the live pass failed, so the owner typed the entry and there is
no machine revision at all; and every migrated entry (§8.3), where `canonical-0` is an
`import`. When base is nil the diff degenerates to **two-way, whole-revision granularity
only** — keep-mine or take-theirs, no hunks, because there is no base against which a hunk is
meaningful. Rev 1 declared two-way diffs unacceptable and then routed all ~36 migrated
entries through one.

**Accepting** mints `source: .merge`, `parentID` = current, `basedOnMachineID` = the accepted
machine revision. Adopted machine spans carry `anchor: .exact` and their frames across — the
legitimate route up the lattice (§3.2), sound because text and frames arrive together from
one measurement.

**Per-hunk accept can produce overlapping `exact` spans** (F11): rev A has one run "I went to
the store" over [0,100]; rev B re-segments per word; the owner accepts only the hunk covering
[45,100]. The retained span keeps [0,100] and, if untouched, keeps `exact` — two `exact`
spans over the same audio, the exact lie #13 exists to prevent. Rule: **at merge close, any
retained span whose frame range intersects an adopted span's degrades to `inherited`.**
Cheaper and more honest than clipping, which would invent a boundary.

### 6.4 `basedOnMachineID` propagation

One rule, stated because rev 1 left it to the implementer and the two plausible readings
diverge immediately after a merge (F13):

> A human-lineage revision **copies its parent's `basedOnMachineID`** — except when its parent
> *is* a machine revision, in which case it takes the parent's `id`. A `merge` sets it to the
> machine revision it accepted, declined, or reverted to.

Never recomputed as "nearest machine ancestor". After a merge those two answers differ, and
the stored one is the one that tracks what the owner actually saw.

### 6.5 Decline and revert are recorded actions

Both were missing from rev 1, and both are the same primitive as accept: **a `merge` revision
that changes `basedOnMachineID` and may change no text at all.**

- **Decline** (F12): text byte-identical to current, `basedOnMachineID` = the declined machine
  revision. Without it, the next retranscription's three-way base is two machine generations
  stale and every rejected hunk is re-presented forever; per-hunk decline is worse, since a
  merge claiming `basedOnMachineID = B` while declined regions descend from A makes the next
  base treat the declines as human edits and re-litigate them as conflicts.
- **Revert** (F4): an untouched entry gets an automatic retranscription that is *worse*; it is
  attached and current and the text degrades silently. Revert mints `source: .merge`,
  `parentID` = current, `basedOnMachineID` = the reverted-to machine revision, spans adopted
  **verbatim** — so the restored `exact` anchors are legitimate under §3.2 rather than a
  lattice violation. This is what makes §12.Q2's "yes, replace silently" a safe answer.

§2.5's "a draft equal to current closes to nothing" does not collide with either: that rule is
about a *draft* producing no change of any kind, and a decline changes `basedOnMachineID`.
State it in the code comment; it will look like a bug otherwise.

### 6.6 What is never allowed

- Rewriting or deleting any revision, attached or not.
- Auto-merging text. No rule makes a machine's version of a sentence the owner rewrote better
  than the owner's.
- Making a machine revision current by any route other than §2.3's derivation.

---

## 7. Metadata-edit audit — separate from the chain, and local-only

**Decision: separate.** A per-entry append-only log, `entry-log.jsonl`, beside `entry.json`.
Not revisions in the transcript chain.

Justification, two independent reasons (rev 1 had three; the third was wrong — see below):

1. **Cardinality and lifetime differ.** Metadata edits happen on entries with no transcript at
   all — a text-only migrated entry (§8.3), an entry whose transcription failed. A chain whose
   revisions sometimes carry no text and sometimes carry no metadata is two record types
   wearing one name.
2. **Sync semantics differ, and the difference is documented.**
   `2026-07-29-data-model-and-migration.md:249-251`: transcript revisions never conflict
   (unique recordName per edit) while `Entry` is last-writer-wins on the change tag. Folding
   backdate edits into the chain would turn the highest-churn field in the app into a
   parent-referenced child record per tweak, and would advance `entries.canonicalRevisionId`
   on edits that changed no text.

**Struck (C5):** rev 1's third reason claimed the trash sweep treats `transcript/` specially.
It does not — `TrashSweeper.apply` stages the entire capture directory into `trash-pending/`
via an atomic rename (`StagedRemover.stage`, `TrashSweeper.swift:89`,
`StagedRemoval.swift:39-61`), and the later purge removes it whole; only recovery's
quarantine distinguishes `transcript/`. The conclusion stands on reasons 1–2. Consequence
worth stating plainly: **`entry-log.jsonl` is
deleted with the entry it audits**, so it can never answer "why was this trashed" after the
30-day sweep. If that question matters, the answer is a container-level log, which this design
does not propose.

### 7.1 Shape

```swift
struct EntryLogRecord: Codable, Sendable, Equatable {
    var at: Date
    var field: String     // "journalID" | "originalDate" | "trashedAt"
                          //   | "detectedDate" | "detectionRan"
    var from: String?     // the field's on-disk encoding, or nil
    var to: String?
    var cause: EntryLogCause  // userEdit | detection | carryOver | sweep
                              //   | recovery | sync | rejected | unknown
    var origin: String?   // BackdateOrigin raw value when field == "originalDate"
}
```

Changes from rev 1:

- **`seq` is gone** (B2, F9). Rev 1 gave the log a monotonic `seq` and, by analogy to
  `live.jsonl`, an `open()` that resumes it — which means re-reading the whole file on every
  backdate tweak, and inheriting `LiveTranscriptWriter`'s throw-on-unreadable rule
  (`LiveTranscriptStore.swift:72-91`) in direct collision with §7.2's "append failure never
  fails the metadata write." Dropping `seq` dissolves both: the writer never reads the file,
  so there is nothing to be unreadable and nothing to resume. Interior ordering is `at`.
  **Tail loss is undetectable and accepted, explicitly** — `seq` could not have detected it
  anyway (M2 §11.3), `live.jsonl` detects it only against `TranscriptRef.committedRecords`,
  and there is no counterpart counter here. Adding one would mean writing a count into
  `entry.json` on every edit, i.e. making the audit log able to fail the write it audits.
- **`detectionRan` added to the field list** (B3). `EntryMetadata` has five fields
  (`EntryMetadata.swift:47-87`); rev 1 listed four and omitted the one issue #21 exists for,
  so `SpokenDateDetection.apply` closing the latch with no date would have been unloggable —
  the audit could never answer "why did detection not apply here."
- **`deviceID` dropped** (F19). The log is local-only; a local-only file does not need to say
  which device it is. `cause: .sync` stays and is locally meaningful: *this device applied a
  change that arrived from sync.*
- **`cause: .rejected` added** (nit). `EntryMetadata.setOriginalDate` returns `false` for a
  future backdate and every call site discards it (`EntryMetadata.swift:135-141`); the owner's
  rejected attempt is arguably the most interesting thing to audit.

`from`/`to` are the fields' **on-disk encodings as strings** — `"1998-03"` for a `PartialDate`,
ISO8601 for `trashedAt`, a ULID for `journalID`, `"true"` for `detectionRan`. One typing rule
for all fields.

### 7.2 Writer rules

Written inside `EntryMetadataStore.update` (`EntryMetadataStore.swift:47-54`) — the single
read-modify-write funnel, already an actor — by diffing the metadata before and after the
mutation closure. A mutation that changes nothing writes nothing.

- **Ordered after the sidecar write** (nit): append only once `AtomicFile.replace` has
  returned. The log must never claim an edit the sidecar does not hold.
- **The append is a bare `O_APPEND` open → write → close**, with the **torn-tail newline
  fuse** required explicitly, not by analogy (B2, F9): if the file's last byte is not `\n`,
  write a lone `\n` first. Without it, `O_APPEND` lands the new record directly onto the
  unterminated one a force-kill left behind and loses **both** — the bug
  `LiveTranscriptWriter` documents at `LiveTranscriptStore.swift:109-118`.
- **Append failure is silent.** Rev 1 said it "sets a degradation flag", which has nowhere to
  live (B5): `EntryDegradation` is computed fresh from disk by `LibraryScanner.item` on every
  scan, there is no channel from a write-time failure inside an actor to a scan-derived value,
  and the `rescan()` fired by the very edit that failed would clear it. The failure is logged
  to the debug console and nowhere else. The sidecar is the truth; the log is testimony about
  it.

**"No call site can forget to log" requires closing the bypass** (B4). `EntryMetadataStore`
exposes `func write(_:captureID:)` (line 41-43) and `static func write(_:url:)` (line 85-89),
both non-private; no app code calls them today, but the static-seam pattern is a *sanctioned*
bypass in this codebase (`LibraryScanner.swift:121`, `TrashSweeper.swift:63`). T6/T7 makes the
instance `write` private and documents the static one as a read/test seam only.

**A `Mirror` field-count tripwire goes over `EntryMetadata`, beside the differ** (B3). Rev 1
claimed "adding a field to `EntryMetadata` does not change the log's shape" — true of the
encoding, false of the diff, which enumerates fields by hand. Same hazard
`writeCapturedManifest` got its tripwire for in T2.5.

### 7.3 Relationship to `backdateOrigin`

`docs/plans/2026-08-03-backdate-precedence-ux.md` §2B proposes
`EntryMetadata.backdateOrigin: explicit | carried | detected`, additive and lenient, no
migration. No conflict: the log reads the origin off the metadata it is diffing and copies it
into `origin`. If `backdateOrigin` ships later, older records carry `origin: nil`, which
decodes leniently as "unknown at the time". It also becomes the sixth field the `Mirror`
tripwire will flag, which is the intended behaviour.

That doc's own note stands and is endorsed: `backdateOrigin` "is a natural seed for T6's
revision/audit chain but should not try to be it: it's one enum, not a history" (line 91-92).
The enum answers *how the current value arose*, cheaply, at read time; the log answers *how it
got here*.

### 7.4 When

Built in T7, not T6 (§12.Q3b). The chain does not depend on it.

---

## 8. Migration and compatibility

### 8.1 What is on devices today

Two devices carry current `main`. Per capture, at most: `manifest.json` (with a
`TranscriptRef` when the live pass completed), `entry.json`, `final/recording.m4a`,
`transcript/live.jsonl`. **No `canonical-*.json` has ever been written by any build** — the
writer does not exist; the naming and `DirectorySnapshot.canonicalRevisions` were landed ahead
of it (M2 T3/T2.5), and `TranscriptRef.latestRevision` is declared but never written
(`LiveTranscription.swift:135` is the sole construction site outside tests).

### 8.2 Therefore: no migration

T6 adds files that have never existed. Every existing file keeps its meaning and its reader:

- `live.jsonl` unchanged; `EntryTranscriptLoader` (`EntryTranscript.swift:41-61`) becomes the
  fallback path rather than the primary one.
- `manifest.json` unchanged **by T6**. No `schemaVersion` bump. One optional field is added
  for T10 (§8.3), additive exactly as `TranscriptRef` was.
- `entry.json` unchanged. The audit log is a new sibling whose absence means "no audit
  history", true of every entry today.

The pre-T6 corpus promotes through §5.1's launch pass. Nothing is rewritten in place.

### 8.3 Migration import shape (T10), settled here

**Entries with audio.** The web transcript arrives as the first revision, `source: .import`,
every span `anchor: .none` (no time offsets exist — M2 §10.10), and — since `import` is human
lineage (§2.1) — it is the human tip. The import-time retranscription then appends a
`machineRetranscribe` revision whose ancestry does not contain it, so §2.3 derives **detached**
with no special case. That is the M3 plan's "old transcript = human revision v1" (line 108-109)
expressed by the ordinary machinery.

Its diff is the **nil-base two-way** case of §6.3, at whole-revision granularity. Rev 1 routed
all ~36 entries through a three-way diff whose base did not exist (F3).

M2 §10.10 asked whether imported entries need an explicit "unlinked provenance" class. The
answer: **no** — `anchor: .none` throughout is that class, in the same format as everything
else.

**Entries without audio** (the 23 paper-archive imports) need a **positive marker**, and rev 1's
"it survives via quarantine" was wrong in a way that would have been discovered on device (B6).
`.quarantineCaptureDirectory` appends to `outcome.quarantinedCaptureIDs`
(`RecoveryExecutor.swift:68-71`), published on `CaptureCoordinator`, so every audio-less entry
would raise the quarantine signal **on every launch, forever**: `RecoveryPlanner.decide`'s
`.complete` branch with no `.m4a` and no frames falls to `.deleteCaptureDirectory`
(`RecoveryPlanner.swift:102-104`) and the filter rewrites it every time.

Decision: **`Manifest.kind: CaptureKind?`** — `nil`/absent = `.audio` (every capture today),
`.textOnly` written by T10. `RecoveryPlanner` gains one early case: a `.textOnly` capture
returns a new `.leaveAlone(captureID:)` action — no filesystem op, and **not** appended to
`quarantinedCaptureIDs`. Optional and additive, so no `schemaVersion` bump; it must be added to
`writeCapturedManifest`'s carry-over, which the existing `Mirror` tripwire will demand. A
missing or corrupt manifest falls through to the old paths and quarantines, which is
safe-not-lossy.

T10 must also handle: `LibraryScanner.holdsSomethingToShow` (`LibraryScanner.swift:102-107`) is
satisfied via `holdsIrreplaceableArtifacts` (the canonical revision), and playback must degrade
to "no audio" rather than presenting a zero-length scrubber.

---

## 9. Sync forward-compat (T9) — the tensions, named

The chain must survive `2026-07-29-data-model-and-migration.md` §1–§2. Nothing here is a
blocker; all of it is cheaper to name now.

Stated once because §9 assumes it throughout and rev 1 never said it (F20): **`captureID` ==
`entries.id`.** The capture directory name is the entry's primary key, which is why both are
ULIDs and why `imp_…` ids survive migration verbatim
(`2026-07-29-data-model-and-migration.md:396-399`).

1. **Revision identity is `id`, never a filename.** `canonical-<n>`'s integer is local; on
   sync-in a foreign revision is written at the next free local `n` and its body is unchanged,
   because the body contains no `n` (§2.2, §4.2). `parentID` and `basedOnMachineID` are ids.
   **Rev 1's version of this rule was the bug**: it kept ordering by `n` while declaring `n`
   meaningless, which is how A1/F2 got in. Rev 2's `(createdAt, id)` order and derived
   attachment (§2.3) are what make sync-in a pure append with no recomputation and no rewrite.
2. **`transcript_revisions.text TEXT NOT NULL`** (schema line 102) vs spans-only on disk:
   `text` is materialized from `plainText` at import. The spans need `transcript_segments`
   (line 114), which the data-model doc deliberately kept out of the M3 core. **Required
   amendments to that doc**, three: store `frameStart`/`frameEnd INTEGER` plus `anchor TEXT`
   rather than `audioStartTime REAL` in seconds (seconds are a lossy re-derivation of the frame
   axis M2 §2 made durable, and #13 taps directly on it); add `sourceRevisionID`; add a **span
   ordinal**, because span order is reading order and may be non-monotonic in frames after a
   move (§3.3), so it is unreconstructable from SQL without it (F20).
3. **`source` enum mismatch.** The schema's CHECK is
   `('import','onDeviceSTT','cloudSTT','userEdit')` (line 103); T6 needs `machineLive` vs
   `machineRetranscribe` (different parents, different trust) and `merge`. **Decided: widen the
   CHECK** (§12.D1).
4. **`entries.canonicalRevisionId`** (line 48) as a *synced* pointer conflicts with §2.3's
   derived current: under LWW on the `Entry` record, two devices can disagree about a pure
   function of immutable children. Keep current derived; treat `canonicalRevisionId` as a local
   cache column recomputed after every sync merge; exclude it from the `Entry` CKRecord — the
   treatment `journals.isActive` gets in that doc's open decision 1.
5. **Record size, corrected** (C2, F14). Rev 1 said "a few hundred KB"; the real number is ~145
   bytes per span with word-level spans, so ~4,500–5,000 spans at 30 minutes ≈ **725 KB**, and
   ≈ **1.4 MB at an hour** — *over* the ~1 MB CKRecord non-asset ceiling, not approaching it.
   So the revision body travelling as a **CKAsset** is a requirement, not a preference
   (§12.D2), and two format economies are mandatory rather than nice: omit `sourceRevisionID`
   when it equals the containing revision's id (~18% of a machine revision's bytes, identical
   on every span), and omit `confidence` when absent.
6. **Record churn, not just size** (F20). Every hour-cap close uploads a full near-duplicate
   asset. At dogfood volume this is nothing; it is the first thing to hurt if editorial gets
   heavy, and the mitigation (delta revisions) is the design this doc deliberately rejected in
   §2.1. Named so the trade is on record.
7. **CloudKit cascade delete vs quarantine-never-delete** (F20). Revisions set `parent = Entry`
   for cascade (`…-migration.md:245-246`), and a purge on device B arrives on A as a zone delete
   of records whose backing files `RecoveryPlanner` is forbidden to delete
   (`RecoveryPlanner.swift:84-86`). Two opposite mandates over one tree. Not resolved here —
   T9's design task must state which wins. The likely answer: a sync-driven delete is the
   owner's own 30-day purge arriving late, so it is *authorized* deletion and must take a path
   the recovery planner never sees, i.e. `TrashSweeper`'s, not recovery's.
8. **`entry-log.jsonl` is local-only, and that engages open decision 4 head-on** (F19). That
   decision drops the web's `entry_moves` audit log because "no native feature or CloudKit
   record consumes it" (`…-migration.md:411-413`). The same test applies here and gives the same
   answer: no native feature and no CKRecord consumes this log either. So it gets no table, no
   record type, and no CKRecord — it is a **local forensic artifact**, and the decision it
   extends rather than contradicts is that doc's own remedy: *archive it to a file, don't model
   it.* The one amendment asked of that doc is to the export package (§3):
   `entries/<id>/entry-log.jsonl` ships in the export, where `entry_moves` ships as
   `legacy/entry_moves.json`. Consequence, restated from §7: a local-only log dies with the
   entry on the 30-day sweep and cannot survive a device wipe.

**Not synced**, to be added to that doc's local-only list beside `entry_search` / `entry_fts` /
`sync_state`: `transcript/draft.json` (an open editor buffer is device state),
`transcript/head.json` (a rebuildable cache), and `entry-log.jsonl` (item 8).

**Search**, for the record (M3 plan lines 30-32): the FTS index carries current's text and,
when it differs, the newest machine revision's; machine-only hits surface labeled. Both are
`plainText` off two revision documents; no format change needed. Built with GRDB, not here.

---

## 10. Testability

Everything below is pure and CI-reachable — no SDK, no models, no device.

**Order and attachment (the rev 2 core).**

- `(createdAt, id)` ordering is stable under shuffling and under renumbering the filenames.
- F1's walk: machine → user → user → machine → machine ⇒ **both** machine revisions detached,
  current is the last `userEdit`.
- A1's data-loss walk: a machine revision minted on a device with no human tip becomes detached
  when a human revision with an earlier `createdAt` is inserted — no file rewritten, current
  flips to the human revision.
- A1's divergence walk: two concurrent `userEdit`s ⇒ both devices derive the same current, and
  `forkedHumanLineage` is true on both.
- Nil-base: a chain with no machine revision derives a nil diff base, and §6.3's two-way reading
  is what the API returns.

**Splices and the lattice.**

- Table-driven (parent spans, edited text) → expected spans: unchanged text preserves `exact`
  and `sourceRevisionID`; a mid-span edit degrades **both sides** to `inherited` with the
  parent's bounds and never invents sub-ranges (F17); deletion leaves frames unclaimed;
  insertion with no preceding anchor is `.none`.
- **Monotone lattice, scoped to `.userEdit`** (F18): no `userEdit` revision produces an `exact`
  span whose text differs from its parent's. Mutation-verify by relaxing the splice rule.
- **Merge exemption as its own test**: adopted spans are byte-identical to the machine
  revision's, text and frames together.
- **F11**: after a per-hunk merge, no two spans with `anchor == .exact` have intersecting frame
  ranges.

**Files and failure.**

- Create-once: two concurrent appends over the same listing ⇒ one succeeds, one gets `EEXIST`,
  retries, and lands at the next `n`; **no revision is overwritten**. Mutation-verify by
  swapping `createExclusively` for `replace` and confirming failure.
- Three-answer listing: an unreadable `transcript/` **refuses to append** rather than allocating
  `n = 0` (A3). Mutation-verify by restoring `(try? …) ?? []`.
- Head is a fixed point: an undecodable revision yields the same rebuilt head twice running,
  with no write on the second pass (F6).
- Head is a cache: delete it ⇒ identical rebuild; corrupt it ⇒ identical rebuild.
- **The read path writes nothing**: run a scan over a tree with no head, no promotion, and a
  stale draft; assert the directory's mtimes and contents are byte-identical afterwards (A2).
  This is the single most important test in T6.
- Read-only-on-unreadable (§4.8): any undecodable revision ⇒ editor refuses to open.
- Decoder: missing lenient keys decode; missing `id`/`text` throws; **an unknown raw value in
  any of the four enums decodes to its degraded case rather than throwing** (F10); an `unknown`
  source counts as machine lineage; the `Mirror` tripwires fire on a new field.

**Interactions.**

- Promotion is display-identical: `plainText` of the promoted revision == the
  `EntryTranscript.text` the same log produced before promotion, byte for byte (F16).
- **Detection across the promotion boundary** (C3): `SpokenDateDetection` returns the same
  answer pre- and post-promotion for the same log. The `detectionRan` latch makes a regression
  here permanent and invisible.
- Promotion slot: a capture finalized through `finishCurrentCapture()` mints a revision whose
  `coverageFrames` is non-nil (B1). Mutation-verify by moving the call before
  `recordTranscriptRef`.
- Trash composition: a capture with `trashedAt != nil` is skipped by promotion, by draft close,
  and by head persistence; a text-only capture (`kind: .textOnly`) yields `.leaveAlone` and
  never appears in `quarantinedCaptureIDs` (B6).
- Entry log: the newline fuse repairs a torn tail so the next record survives (B2); a no-change
  mutation writes nothing; a `setOriginalDate` rejection logs `cause: .rejected`; the append
  happens after the sidecar replace returns.

UI (simulator, `RaconteUI`): edit → background → relaunch → the edit is a revision; a detached
machine revision does not change displayed text.

---

## 11. Task breakdown (implementer-subagent sized)

- **T6a** — `TranscriptRevision` / `TranscriptSpan` / `TranscriptHead` / `TranscriptDraft`
  types, hand-written decoders with the one unknown-enum rule, `Mirror` tripwires,
  `SegmentLayout` paths, `TranscriptText.join` factored out of `TranscriptConsolidator`,
  `AtomicFile.createExclusively`, `DirectorySnapshot.transcriptDirUnreadable`. No writer, no
  callers. Pure, CI.
- **T6b** — `TranscriptRevisionStore`: three-answer listing, create-once append with the
  `EEXIST` retry, head write and in-memory rebuild, the order/attachment/current derivation.
  Read-only static seams for the scanner.
- **T6c** — promotion (§5), wired at `CaptureView.swift:414-415` plus the launch pass and
  entry-open; `LibraryScanner`/`EntryTranscriptLoader` prefer a canonical revision and fall back
  to `live.jsonl`. Includes the display-identity and detection-boundary tests.
- **T6d** — splice engine (§3.3) and draft lifecycle (§2.5). The bulk of the test suite.
- **T6e** — attachment consequences: merge, accept, decline, revert (§6), against a fake machine
  revision. T8 supplies the real one; T7 the diff UI.
- **(T7)** — `entry-log.jsonl`, the audit write inside `EntryMetadataStore.update`, closing the
  `write` bypass (§7).
- **(T10)** — `Manifest.kind` + `RecoveryAction.leaveAlone` for text-only entries (§8.3).

Adversarial review after T6a–T6b (format frozen) and again after T6d (rules frozen).

---

## 12. Decisions and open questions

Restructured per F21: things the doc's own constraints already settle are presented as
decisions with rationale, not as questions.

### Decided (rationale given; overrule if you disagree)

- **D1 — Widen the GRDB `transcript_revisions.source` CHECK** to carry `machineLive`,
  `machineRetranscribe`, and `merge`, amending `…-migration.md:103`. Collapsing to the
  documented four loses the machine-live/machine-retranscribe distinction that
  `basedOnMachineID`, and therefore the three-way diff, depends on. Not a preference — the
  design does not work without it.
- **D2 — Revision bodies travel as CKAssets**, not inline CKRecord fields. With the corrected
  size estimate (§9.5) an hour-long entry is ~1.4 MB, over the non-asset ceiling. Rev 1 offered
  this as a choice on a 5× low estimate.
- **D3 — `live.jsonl` is kept forever** after promotion. It is small, it is the crash evidence,
  it is the only record of the analyzer's timebase, and `committedRecords` tail-loss detection
  reads it. Deleting later is easy; un-deleting is not.
- **D4 — The metadata audit lives outside the revision chain** (§7), local-only, unsynced,
  exported. This is the call T6 existed to make.

### Open — genuine owner calls

1. **Batching numbers.** Close a draft at 90 s since its last write, or at a 60-minute cap,
   whichever comes first; 2 s editor debounce. **Recommend as written** — the simplest thing
   satisfying "session or hour, whichever is shorter", and both numbers are one-line changes.
2. **Silent replacement when the entry is untouched.** A retranscription over an entry with no
   human edits becomes current with no prompt (§6.2). **Recommend yes** — nothing a person did
   is at risk, and auto-retranscribe-on-coverage-gap is pointless if the better text sits behind
   a prompt. Rev 2 makes this safe by defining **revert** (§6.5), which rev 1 left impossible;
   without revert the honest answer would have been no.
3. **Two split questions** (rev 1 bundled them):
   - **3a. Promote at finalize for every capture**, plus a one-shot launch pass for the existing
     corpus? **Recommend yes** — it is what removes the per-scan re-consolidation cost.
   - **3b. Build the audit log in T7 rather than T6?** **Recommend T7.** It has no dependents in
     T6, and T7 is where the editor makes provenance visible anyway.
4. **What should an incoming machine revision do to an open draft?** Rev 1 closed the draft
   immediately, which can mint a revision from a half-typed sentence mid-thought. Alternative:
   queue the machine revision's *marker* and leave the draft alone; the diff is offered when the
   draft closes naturally. **Recommend queue** — a retranscription is never urgent, and
   interrupting a sitting to preserve diff hygiene is the wrong trade. Flagged because rev 1
   chose the opposite silently.
5. **Spacing and punctuation.** Rev 2 deliberately makes promotion display-identical: canonical
   text joins exactly as the live view does (single spaces —
   `TranscriptConsolidator.swift:125-129`), so no existing entry's text changes. Do you want a
   later pass to actually repair spacing/punctuation, knowing it (a) changes the displayed text
   of every existing entry and (b) must therefore be a **machine revision** that the §6
   machinery can show you and you can revert? **Recommend yes, later, as its own machine-lineage
   pass** — not folded into promotion, where it would be an invisible rewrite.
6. **Per-hunk accept, or whole-revision, for T7 v1?** Whole-revision is far less UI, is the only
   defined granularity for the nil-base case anyway (§6.3), and avoids the overlap degradation
   of §6.3/F11. **Recommend whole-revision for v1.**
7. **Is decline a recorded action?** Yes in this design (§6.5) — a text-identical `merge` that
   advances `basedOnMachineID`. It costs one revision per decline and is the only thing that
   stops the same rejected diff being re-offered forever. **Recommend as designed**; the
   alternative is accepting that re-litigation.
8. **Are detached machine revisions visible in the history panel?** **Recommend yes, clearly
   labeled** ("machine transcript, not applied"). Hiding them makes the "a newer transcript is
   available" marker unexplainable, and revert needs them reachable.

### Owner answers, 2026-08-03 — all eight decided

1. **Yes as written.** Owner asked whether a *pause* exists; there is no editor-pause and none
   is needed — a 90 s close costs nothing, since reopening the editor just starts the next
   draft on top of the same chain. (If the question meant a capture-time pause button, that is
   a capture feature, tracked separately.)
2. **Yes** — silent replacement of untouched text, revert being the safety net.
3. **3a yes, 3b T7** — and the audit log is confirmed wanted: "let's just log edits so we have
   auditability."
4. **Queue** — an incoming machine revision never closes an open draft.
5. **Yes, later, as its own machine pass.** Plus a new capture-time requirement recorded in
   §14: end-sentence / end-paragraph / **switch-voice** markers (the owner's journals are
   conversations between "little Nico" and "big Nico", distinguished on paper by print vs
   cursive).
6. **Whole-revision for v1.** And decided in the same exchange: **one entry per read journal
   page** is the working practice for archival reading — it is also what gives per-entry
   spoken-date detection its chance to fire. Long free-form entries remain fine for new
   material.
7. **Yes** — decline is a recorded merge.
8. **Yes** — detached revisions visible, labeled.

## 14. Recorded requirement: capture-time structure markers (voice, sentence, paragraph)

Owner, 2026-08-03, deciding OQ 5: while reading a paper journal aloud, he wants low-friction
capture-screen buttons for **end sentence**, **end paragraph**, and **switch voice** — the
voices being the two hands of his own journals (print = "little Nico", cursive = big Nico),
i.e. a per-span *speaker/voice* attribute with exactly-two-values-for-now semantics.

**Designed 2026-08-05 — see `docs/plans/2026-08-05-capture-structure-markers-design.md`,
which supersedes the direction below.** Notable deltas from this sketch: end-sentence
markers are dropped (the transcriber already punctuates sentences acceptably), a
multi-voice toggle gates the feature and defaults off with per-journal carry-over, and
markers are stored raw and snapped to word gaps on read rather than at capture time.

Original design direction (superseded):

- **Capture-time, frame-stamped.** A marker is an event `(frame, kind)` recorded the moment
  the button is tapped, `frame` taken from the same capture-frame clock as everything else.
  Markers are ground-truth-adjacent (they record what the *owner* said about the audio at the
  moment it was made) — so they belong in their own append-only `transcript/markers.jsonl`,
  written like `live.jsonl`, NOT in the revision chain: they are input to promotion, not a
  revision.
- **Promotion consumes markers**: a `voice` attribute lands on `TranscriptSpan` (optional,
  additive, omitted when absent — decoder rule 4.7 already covers it), spans split at marker
  frames the same way runs split them. Sentence/paragraph markers become punctuation/breaks in
  the promoted text — which is exactly the §12 OQ 5 "repair pass" machinery, so they ride an
  existing seam.
- **UI sketch to explore**: a single thumb-reach toggle showing the active voice (LN/BN), so
  "switch voice" is one tap and glanceable; end-sentence/end-paragraph as two adjacent buttons.
  Spoken-command alternatives ("new paragraph") were considered and deferred — they collide
  with the actual journal text being read aloud.
- T7 editor must render the voice attribute distinctly (the print/cursive instinct suggests a
  typeface change, which SwiftUI makes cheap).

---

## 15. Build amendments (2026-08-08 — T6a/T6b as built, Gate A outcomes)

The chain was built on branch `t6/revision-chain` per
`2026-08-08-revision-chain-implementation-plan.md`, with
`2026-08-08-revision-chain-code-maps.md` as the citation authority (this doc's file:line
cites drifted after the §14 marker work and #25 landed). An adversarial format-freeze
gate reviewed T6a–T6b and forced the following deltas — **this section supersedes the
sections it names**:

1. **`TranscriptHead.listingUnreadable: Bool`** (additive, lenient, default false) —
   §4.3's shape gains a fourth field. A directory-level unreadable listing is recorded
   here, never as a sentinel value in `revisionFiles`/`unreadableFiles` (those arrays
   hold only real file numbers).
2. **`SpanAnchor` gains `.unknown(String)`** with verbatim raw round-trip, mirroring
   `RevisionSource` — §4.2/§4.7's "absent OR unknown ⇒ `.none`" was a lossy reader: a
   foreign build's anchor kind was destroyed on re-encode while its frames were kept.
   `.unknown` answers like `.none` for usable-bounds (`hasUsableBounds` is the one
   predicate). Absent key still decodes `.none`.
3. **Duplicate revision `id` across two canonical files is a defined state, not a trap**
   (rule, per the gate's freeze paperwork; belongs beside §4.5a): *two canonical files
   carrying the same revision `id` are one revision. The lowest file number is its
   canonical location; the others are ignored, counted in `revisionFiles`, and not an
   error. Same id with different bytes is a violation of immutability upstream and is
   not detected here.* It is the expected T9 sync shape (§2.2: the same revision written
   at each device's next free `n`); revisions are immutable, so any winner carries
   identical bytes, and file numbers never feed derivation — only the head's
   device-local `fileNumber` pointer — so all devices derive identical answers. The
   build's first reading crashed (`Dictionary(uniqueKeysWithValues:)`) — probe-confirmed
   at the gate; its second reading dropped the duplicate from `revisionFiles`, silently
   defeating the scan cache forever (also probe-confirmed).
4. **`append` requires `captures/<id>/` to exist** (`.captureMissing`, mirroring
   `EntryMetadataStore`) — §4.6's write-side trash skip was insufficient as specified:
   after `StagedRemover.stage` renames the capture away, there is no sidecar to consult
   and the sidecar read defaults to not-trashed; a bare mkdir-and-write resurrects the
   entry (A2.3, probe-confirmed). Existence-check-before-mkdir is the load-bearing rule;
   the sidecar `trashedAt` check remains for the directory-present case. `persistHead`
   carries the same guards; the gate ruled **silent no-op is correct** (the head is a
   pure cache — a skipped persist costs a rebuild, never correctness; add a
   `PersistOutcome` return only when a caller actually consumes it). One edge for T6c
   callers: the sidecar guard makes `persistHead` throw on an *unreadable* (not absent)
   `entry.json`, where it previously wrote; `append` swallows this.
5. **Head trust condition narrowed** (amends §4.3): a persisted head is trusted only if
   its `revisionFiles` matches the listing AND `unreadableFiles` is empty AND
   `listingUnreadable` is false. A head cached during damage is never trusted, so §4.8's
   self-healing holds for the scan cache too (damaged entries pay an in-memory,
   write-free rebuild per read until healthy).
6. **`append` never throws after the revision file is durable**: a `persistHead` failure
   inside `append` is swallowed (the head is a rebuildable cache; a caller retrying a
   thrown-but-durable append would mint a duplicate id — the non-sync trigger for #3).
7. **`TranscriptSpan.resolvedSourceRevisionID(in:)`** is the single reader of §9.5's
   omitted-key economy (absent ⇒ the containing revision's id). Write-side enforcement
   lands with the T6c/T6e span assemblers.
8. **§4.6's writer census, corrected**: `transcript/` writers are `LiveTranscriptWriter`
   (`live.jsonl`), `MarkerLogWriter` (`markers.jsonl`, landed with §14 after this doc),
   and `TranscriptRevisionStore` (canonical revisions, `head.json`, `draft.json`).
9. Known-corrected facts for future readers: `EntryMetadata` has six fields
   (`multiVoice` landed with §14 — §7.1's tripwire count must include it), and the
   launch-recovery path runs no `recordTranscriptRef`, so §5.1's launch-pass promotion
   copies `coverageFrames`/`skippedRanges` as honest-nil for recovered captures.

### 15b. Gate B amendments (2026-08-09 — T6c/T6d/T6e as built)

Tasks 4–6 landed per the same plan; the whole-branch gate forced these rulings. As with
§15, this subsection supersedes the sections it names. None change an encoded shape —
the Gate A freeze holds.

10. **§5.2 run mapping trims boundary whitespace** (Gate B C1). AttributedString runs
    *partition* the result text, so run texts carry their own boundary whitespace, and
    §5.2's verbatim copy contradicted §4.2's "spans hold no boundary whitespace"
    invariant — promotion doubled spacing at every run boundary (probe-confirmed), baked
    permanently into revision zero. As built: each run's text is trimmed, whitespace-only
    runs are dropped (frames untouched; `TranscriptText.join` re-supplies the single
    separator). F16/C3 tests are fixtured with whitespace-carrying runs so the
    non-degenerate path is pinned. Known residual (probe-characterized at the gate,
    unobserved on device): a run pair the analyzer splits *without* intervening
    whitespace (e.g. `don't` → `don`/`'t`) still gains a separator on join. If device
    data ever shows this shape, the fix is a promotion-time guard — compare
    `join(trimmedRunTexts)` against `result.text` and fall back to the runless
    single-span shape for that result — making F16 hold unconditionally by construction.
11. **§3.3's "adjacent `exact` spans are never merged" holds only across an intact,
    unedited separator.** When the user deletes the boundary space, the format cannot
    represent adjacency-without-separator (`join` always inserts one), so the two spans
    are combined into ONE `.inherited` span carrying the union bounds — a lattice-legal
    degrade, not an exception to F18. Round-trip (`join(spans) == editedText`) is the
    governing postcondition and is asserted inside the F18 generative property.
12. **`closeDraft` diffs against `draft.parentID`'s revision, not `current`** (amends
    §3.3's literal wording). The user edited the text they were shown — the parent's
    flattened text; diffing against a machine revision that landed mid-draft would
    attribute the machine's words to the human's keystrokes. The §2.5 no-op guard still
    compares against **current** (F7), and a mid-draft machine revision stays detached
    per §2.3 until accepted.
13. **§6.3's "adopted machine spans carry `anchor: .exact`" is descriptive of the common
    case, not an anchor rewrite.** Accept/revert adopt spans verbatim — text, frames,
    AND anchor unmodified (§3.2's "together, unmodified"; §6.5's "restored"; §10's
    "byte-identical"). Forcing `.exact` would fabricate anchors on §5.2's runless
    `.inherited` promotion spans — the exact lie the lattice exists to prevent. One
    as-built deviation from "byte-identical": a borrowed span's omitted
    `sourceRevisionID` is made explicit via `resolvedSourceRevisionID(in:)` before
    adoption (a nil copied into a different revision would misresolve to the new id).
14. **`TranscriptDraft` carries three fields beyond §2.5's list**: `captureID` (strict —
    the §13 self-identifying tripwire), plus `parentID` and `basedOnMachineID` (lenient
    additive) — required by §6.4's snapshot-at-open rule. An existing draft's snapshot
    is copied verbatim on every rewrite; only a brand-new draft samples `current`.
15. **Draft writes refuse on a degraded chain** (§4.8/F5, write half): `writeDraft`,
    `closeDraft`, and `closeStaleDrafts` throw (`.revisionUnreadable`/
    `.transcriptDirUnreadable`) when any canonical file is undecodable or the listing is
    unreadable — the draft stays on disk, nothing is minted. The read half (editor
    refuses to open) is T7's.

## 13. Rev 2 changelog

What changed and which finding forced it. Review 1 is `A*`/`B*`/`C*`; review 2 is `F*`.

**Format changes** (T7/T8 implementers must know these):

1. **`revision: Int` deleted from the body** — the filename integer is local and never stored
   (F2).
2. **`detached: Bool` deleted** — attachment and current are read-time derivations from
   `(createdAt, id)` order plus ancestry (A1, F1, F2). Nothing about "which revision is current"
   is stored anywhere.
3. **`TranscriptSpan.sourceRevisionID` omitted when it equals the containing revision's id;
   `confidence` omitted when absent** — ~18% and ~10% of a machine revision's bytes (C2, F14).
4. **`head.json` reshaped**: one `current` summary plus `revisionFiles` / `unreadableFiles` /
   `revisionCount`, instead of a row per revision (F15, F6). No `nextRevision`.
5. **`TranscriptDraft` is a specified struct with a decoder** — rev 1 left the file holding the
   only irreplaceable human text T6 creates entirely unspecified (F7).
6. **`EntryLogRecord`: `seq` and `deviceID` dropped; `detectionRan` and `cause: .rejected`
   added** (B2, B3, F9, F19, nit).
7. **`Manifest.kind: CaptureKind?`** added for T10's text-only entries, with a new
   `RecoveryAction.leaveAlone` (B6).
8. **Canonical text joins exactly as the live view does** — `TranscriptText.join` factored out
   and shared, so promotion changes no glyph (F16, C3). Rev 1's "spans carry their own
   whitespace" is gone.

**Rule changes:**

9. **The read path never writes** — new governing rule 9. Head rebuild, lazy promotion, and
   stale-draft close all moved off the scan onto explicit store calls, all skipping trashed
   captures (A2, F8). Rev 1 put three writes on a path documented as overlapping and racing
   `TrashSweeper`'s `removeItem`.
10. **`transcript/` is created only by a content-carrying write** (A2b) — the T3
    zero-byte-log lesson, which rev 1 reintroduced twice.
11. **Create-once is real**: `AtomicFile.createExclusively` via `renamex_np(RENAME_EXCL)`, plus
    a three-answer directory listing that refuses to append when `transcript/` is unreadable
    (A3). Rev 1's invariant rested on a `(try? …) ?? []`.
12. **Promotion moved to after `recordTranscriptRef`** (B1) and made once-only per capture,
    skipping captures with no `.m4a` (F8).
13. **Nil diff base defined** — two-way, whole-revision granularity; it is the *common* case
    (failed live pass, every migrated entry), not an edge (F3).
14. **Revert and decline defined** as `merge` revisions (F4, F12). Rev 1 made revert illegal
    under its own lattice rule.
15. **`basedOnMachineID` propagation stated** in one sentence (F13).
16. **Merge overlap rule**: retained spans intersecting adopted spans degrade to `inherited`
    (F11).
17. **Partial-edit sub-range branch deleted** — unexpressible in the format (F17).
18. **Runless promotion branch is `.inherited`, not `.exact`** (C1).
19. **Any unreadable revision makes the entry read-only** (F5), because order lives inside the
    file and "is it above current?" is undecidable.
20. **One unknown-enum rule for all four enums**, never a throw (F10).
21. **Monotone-lattice invariant scoped to `.userEdit`** with the merge exemption as its own
    test (F18).
22. **`EntryMetadataStore`'s `write` bypass closed**; `Mirror` tripwire over `EntryMetadata`
    (B3, B4). The append-failure degradation flag dropped as unimplementable (B5).

**Corrections:** §2.4 now agrees with §4.4 that a crashed promotion leaves a stray `.part`
(C4). §7's third justification struck — `TrashSweeper` removes the whole directory and does not
treat `transcript/` specially (C5). Size estimates corrected ~5× upward (C2, F14).
`CapturePlayback.seek(toFrame:)` named as missing, and the `Int`/`Int64` width mismatch in
`PlaybackSeek` named (nits).

**Resolved for §9:** `entry-log.jsonl`'s sync story engages the data-model doc's open decision 4
directly and reaches the same verdict — local artifact, exported, not modeled (F19).
Cascade-delete-vs-quarantine, record churn, `transcript_segments`' need for a span ordinal and
`sourceRevisionID`, and `captureID == entries.id` are all now named (F20).

**§12 restructured** (F21): D1/D2/D3 were rev 1's OQ 7/8/4 and are now decisions with rationale;
OQ 3 split into 3a/3b; decline promoted to its own question (Q7); revert folded into Q2 where it
belongs; the machine-arrival-closes-draft behaviour (Q4) and the promotion spacing question (Q5)
surfaced from where rev 1 had chosen them silently.

**Nothing was rejected.** Every finding in both reports is either fixed above or, where the two
reviewers disagreed, resolved explicitly: `TranscriptDraft.captureID` is **kept** despite review
1's nit that it duplicates the path, because review 2 (F7) needs the struct specified and a
self-identifying draft is a cheap tripwire against a file that ends up in the wrong directory —
the same reasoning that puts `captureID` in `manifest.json`, which the path also encodes.

## 16. T7 as-built rulings (2026-08-11 — editor/history/marker-correction/audit-log)

Same convention as §15/§15b: this subsection supersedes what it names; nothing here changes
an encoded shape from §15/§15b's freeze except where a ruling says so explicitly. T7 built the
editor (Task 4), voice-attribution-survives-edits (Task 5), marker correction (Task 6), the
metadata audit log (Task 7), revision history + revert (Task 8), and the parked-minors/docs
pass (Task 9) on `t7/editor-ui`.

1. **Detached-label ruling (owner).** "Machine transcript, not applied" is reserved for
   genuinely unapplied revisions — an entry's own rev0 is the foundation of later human edits,
   not a revision sitting apart from them. The plan's `!isAttached` shorthand is superseded
   **for that label only**; `TranscriptChain.isAttached` itself is unchanged. As built: the
   detached set is every revision neither `current` nor in `ancestry(of: current)`
   (`EntryChainSnapshot.swift:51,56`, `detachedMachineRevisions`'s computation at
   `EntryChainSnapshot.swift:193-208`, `TranscriptChain.ancestry(of:among:)`). Task 8's
   `orderedChain`/`ChainRevisionRow` (`EntryChainSnapshot.swift:20-23,65-70`) reuses the same
   rule for the whole-chain history panel rather than re-deriving it.
2. **Corrupt-sidecar ruling.** An unreadable `entry.json` gets its own editability case,
   `.readOnlyMetadataUnreadable` (`EntryChainSnapshot.swift:40`, wired at `:132`), never
   `.readOnlyTrashed` — same blocking behavior, but the entry is not in the trash and
   labelling it so would make Restore/Delete Now affordances lie. Same principle as ruling 1
   and as §15b's own corrupt-file rulings: never name a state with something untrue.
3. **Launch-sweep ruling.** `persistHead`'s only production caller was `append`, and
   `promoteIfNeeded` writes nothing once a chain exists (`.skippedAlreadyPromoted`) — so every
   `head.json` on a device that predates this sweep stays distrusted forever
   (`sizesStillMatch`'s size-integrity check has nothing to compare against) and #40's read-cost
   win never reaches an existing entry. Fix: a launch-time sweep,
   `TranscriptRevisionStore.stampUnstampedHeads()` / `stampHeadIfNeeded(captureID:)`
   (`TranscriptRevisionStore.swift:466-495`), guarded by `!files.isEmpty`
   (`TranscriptRevisionStore.swift:481`) so it never stamps a chainless capture — writing
   `head.json` into an empty `transcript/` would flip `DirectorySnapshot
   .holdsIrreplaceableArtifacts` false→true and make a mis-tapped capture permanently
   undeletable, the same zero-byte-log hazard (rule 10) `MarkerLog.swift`/
   `CaptureCoordinator.swift` already guard elsewhere.
4. **Leading non-placeable span ruling (Task 5, owner).** A leading span that cannot be placed
   against the marker timeline — no usable, non-zero-length frame bounds
   (`TranscriptAttribution.isPlaceableSpan`) — renders `voice: nil`, never a guessed voice.
   Guessing forward or backward from the nearest placeable span would assert something the
   data does not support; `nil` is `EntryDetailView`'s existing "no voice marker in force"
   answer, not a new state.
5. **Splice-inherit ruling (owner, 2026-08-11) — as built, Task 9b.** A wholesale word
   replacement with zero character overlap (the brief's own example, "Ellen" → "LN")
   **inherits the replaced word's audio frames** — the retyped word IS the heard word,
   corrected, not a new word spoken at a single instant. Before this task, the splice
   discarded the replaced span's frames and anchored the replacement as a zero-length
   `.inherited` point at the preceding span's end, which asserted something untrue about
   where the word lives in the audio (and is why #37's own worked example — Swahili name
   transcribed as "Ellen," corrected to "LN" — was disproved by probe during T7 planning).
   As built: `TranscriptSplice.spans(parent:editedText:)`
   (`TranscriptSplice.swift:50`) runs a precompute pass over the diff's positions/removed
   offsets/insertions, independent of the pre-existing atom-building walk, that tags an
   insertion run as a wholesale replacement only when a contiguous removal run covers
   exactly one parent span's full text with nothing else interposed — no second span, no
   removed separator, no surviving matched character (`wholesaleReplacements`,
   `TranscriptSplice.swift:108-141`). The `.insertion` `RawUnit` case carries the tagged
   span index through (`TranscriptSplice.swift:193,209`); the emit loop
   (`TranscriptSplice.swift:330-353`) inherits the REPLACED span's own
   `frameStart`/`frameEnd`/resolved `sourceRevisionID` when tagged and that span has
   usable bounds, and — the review round's fix — falls to `.none` with nil source, never
   the zero-length-point fallback, when the replaced span itself has nothing to inherit
   (borrowing a DIFFERENT span's provenance would repeat the exact untruth this ruling
   exists to remove, just aimed at a new victim). `TranscriptAttribution.isPlaceableSpan`
   (unchanged) is the one placeability rule both the wholesale-inherited case and the
   ordinary zero-length-point case answer to — a wholesale replacement is placeable
   exactly when the span it replaced was. Multi-span replacements, partial-span edits, and
   plain deletions with nothing typed in their place are untouched, byte-identical to
   before. §3.3's Insertion row above carries the same exception.
6. **Row-honesty ruling (Gate B, T6c — not previously written up in §15/§15b).** Rows route
   through the O(1) `validatedHead` cache, but a trusted head could mask in-place damage to a
   canonical file: the row would say healthy while the detail screen and editor both refused.
   Fix: each canonical file's byte size is recorded in `head.json`
   (`RevisionFileSize`/`byteSize`, `TranscriptRevisionStore.swift:120-128`) and `validatedHead`
   distrusts the cache on any mismatch against a fresh `.fileSizeKey` stat
   (`TranscriptRevisionStore.swift:326,367-388`) — nearly free, since the directory scan
   already stats those files for #39. **Same-size corruption still slips through** — accepted
   knowingly, and pinned by its own deliberately-named test,
   `testSameSizeCorruptionIsAnAcceptedGapNotCaughtByTheIntegrityCheck`
   (`RaconteTests/TranscriptRevisionStoreTests.swift:495`) — so a future reader finds a named,
   intentional gap rather than rediscovering it as a bug.

## 17. Mark voices (as-built) (2026-08-12 — issue #56, replaces "Correct markers")

Same convention as §15/§15b/§16: this subsection supersedes what it names. Built on
`feat/mark-voices` per `docs/plans/2026-08-12-mark-voices-plan.md`'s D1-D9. No encoded
shape changed except `Journal` gaining `voiceLabels` (additive, below) — `StructureMarker
.voice` already existed and needed no wire change.

1. **Voice-carrying adds (D1).** `MarkerCorrectionWriter.addVoiceBoundary` writes a
   `.correctionBoundaryAdd` record that also carries `voice`
   (`MarkerCorrectionWriter.swift:96-103`), sharing `addBoundary`'s placeable-anchor rule
   (`placeableFrame`, `MarkerCorrectionWriter.swift:80-87`) rather than re-deriving it. On
   the read side a voice-carrying add folds to a synthesized `.voice` marker and a
   voiceless one still folds to `.paragraph`, exactly as before —
   `TranscriptAttribution.breakpoints(for:pieces:)` switches on `marker.marker.kind`
   (`TranscriptAttribution.swift:384-393`) and never on the record's own correction kind,
   so old and new adds are indistinguishable once folded.
2. **Opening-voice rule (D2).** `MarkerCorrectionWriter.addOpeningVoice` writes a
   voice-carrying `.correctionBoundaryAdd` at frame 0 unconditionally — no picked-word
   validation, since frame 0 is always a legal anchor
   (`MarkerCorrectionWriter.swift:113-116`). `VoiceMarkingPlan` only emits it when the
   entry has no voice marker at all (`hasAnyVoiceMarker == false`) and the gesture's
   anchor isn't itself the transcript's first placeable span — in that one case the
   opener would collide at the same attribution cut as the anchor and lose to it anyway,
   so it's a permanent no-op line skipped on purpose
   (`VoiceMarkingPlan.swift:163-178`, `openerIfNeeded`). This mirrors capture's own
   frame-0 `bn` opener (`CaptureCoordinator.markOpeningVoice`) for the correction path.
3. **Append-only planning, later-seq-wins (D3).** `VoiceMarkingPlan` has no retract and
   no correct — every gesture is a `Command` list of `addOpeningVoice`/`addVoiceBoundary`
   only (`VoiceMarkingPlan.swift:16-19`). Re-flipping a paragraph or re-marking a range
   is just a later append: `TranscriptAttribution.breakpoints` walks markers in sorted
   `(frame, seq)` order and overwrites `result[index]` on every marker landing at that
   cut, so the last one in order always wins (`TranscriptAttribution.swift:374-402`).
   `MarkerCorrectionWriter.retract`/`.correctVoice` are unchanged and gain no new
   callers — format capabilities, not marking-mode capabilities (D8, next).
4. **Frame-ambiguity refusal (Task 4 fix round).** Splice fragments of one parent span
   can share an identical `[frameStart, frameEnd)`
   (`TranscriptSplice.swift`'s `.inherited` fragment branch) — a boundary aimed at a
   later fragment resolves, on read, to the EARLIEST placeable span carrying that frame
   (`TranscriptAttribution.placeableCutPosition`), which can silently mark text nobody
   selected or make a flip's switch-and-restore self-cancel. Controller ruling
   2026-08-12: refuse rather than relocate. `VoiceMarkingPlan.validate` checks the WHOLE
   plan before returning any of it — every `addVoiceBoundary` command's frame must
   resolve back to the exact span index that emitted it, and no two commands in one plan
   may target the same frame (`VoiceMarkingPlan.swift:142-161`). A refusal throws
   `PlanError.notMarkable` and writes nothing (half a plan can never be taken back out of
   an append-only log). This is a reachable UI state, not a programmer error:
   `VoiceMarkingModel.flipParagraph`/`.markRange` catch it explicitly and surface
   `MarkerCorrectionWriter.boundaryAddRejectionMessage()` — the same copy `addBoundary`
   already uses for "no timed position" — then reload from disk
   (`VoiceMarkingModel.swift:146-160,168-187`).
5. **Display-config default flip (D7), supersedes.** `Journal.voiceLabels: [String:
   String]` (voice id -> label), additive and lenient, empty by default, encoded only
   when non-empty so an unlabelled journal's bytes are unchanged
   (`Journal.swift:15-20,42-46,49-62`). `VoiceDisplay` is now the one display-mapping
   type: `label(forVoice:voiceLabels:)` returns `nil` unless the voice is set AND that
   journal configured a non-empty label for it; `isItalic(voice:)` keeps the main-voice
   rule (`VoiceDisplay.swift:12,25-36`). **This supersedes the 2026-08-08 always-on-label
   decision** (§4 of `docs/overview.md`'s prior text, "BN: prose in italic, LN: regular"
   inline labels) — the default render as of this section has NO label at all; labels
   are opt-in per journal via `JournalVoiceLabelsSheet`. `TranscriptAttribution
   .displayName`/`.isItalic` are deleted; `EntryDetailView.attributedParagraph` reads
   `VoiceDisplay` directly (`EntryDetailView.swift:565-568`) and the accessibility label
   still names the voice even with labels off (`VoiceDisplay
   .accessibilityName`, `VoiceDisplay.swift:42-44`).
6. **D8's deliberately dropped capabilities.** `EntryDetailView`'s old "Correct
   markers…" button, `MarkerCorrectionView`, and `MarkerCorrectionModel` are deleted,
   replaced by "Mark voices…" pushing `VoiceMarkingView`
   (`EntryDetailView.swift:518-522`, `.navigationDestination` at `EntryDetailView.swift
   :110-111`). `MarkerCorrectionWriter.retract` and `.correctVoice` stay (format
   capabilities, still tested) but have no caller from marking mode: **retracting a
   mis-tap and adding a bare paragraph break (no voice) have no UI as of this section.**
   Both can return inside marking mode later if the owner asks; nothing about the format
   forecloses it.
7. **WYSIWYG / append-only planning (D6's invariant).** Marking mode always reads the
   layout fresh from disk on open and after every gesture, success or failure
   (`VoiceMarkingModel.open`, `VoiceMarkingModel.swift:111-135`, called at the end of
   both `flipParagraph` and `markRange`) — the screen is a projection of what actually
   landed, never of what the model assumed a plan would do. This is also what makes
   non-atomic multi-command plans (switch lands, restore write throws) surface honestly
   rather than silently: the reload after a partial failure shows the entry genuinely
   flipped-to-end-of-entry, not a guessed pre- or post-gesture state.
