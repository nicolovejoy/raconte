# Capture-time structure markers (voice + paragraph)

Design pass for T6 §14, owner-decided 2026-08-05. Blocks T7 (the editor must render the
voice attribute), but is independently buildable and independently useful.

Governing rule, inherited: **a tap is an observation about the audio that the audio does
not contain.** It is ground-truth-adjacent, stored raw, never overwritten by an
interpretation of it. Snapping, promotion, and rendering are all derived and re-derivable.

## 1. Scope

While reading a paper journal aloud, the owner marks two things:

- **switch voice** — his journals are conversations between "little Nico" (print) and
  "big Nico" (cursive). No machine can recover this from the audio.
- **end paragraph** — a structural break the transcriber cannot reliably infer.

**Sentence boundaries are deliberately out of scope.** SpeechAnalyzer punctuates
sentences acceptably, and per-sentence tapping costs the most flow for the least gain
(30–60 taps a page vs. ~5–10). Owner decision, 2026-08-05.

## 2. Owner decisions

1. Voice + paragraph marked live; sentences left to the transcriber.
2. Raw tap frame stored; snapped to the nearest inter-word gap at promotion; editable in
   T7. The raw frame is never discarded — a better snapping rule later re-derives better
   boundaries from untouched data.
3. Exactly two voices in the UI, stored as a **string id** (`"ln"` / `"bn"`) not a bool.
   Storage generality is free now and needs a migration later; UI generality is neither
   free nor wanted.
4. A **multi-voice toggle** gates the voice feature. Default off. When on, the entry opens
   in **`bn`**, written as a frame-0 marker so "what voice is this span" has exactly one
   rule (most recent marker at or before it) with no special case for the beginning.
5. Multi-voice carry-over is **per journal, read from disk, durable** across launches and
   journal switches.
6. **No capture-time undo.** Mis-taps are fixed in T7, which must handle them regardless.
7. Paragraph markers are **independent of the voice toggle** — always available, including
   in single-voice entries.

### Deliberate divergence from the backdate carry-over rule

The 2026-08-02 backdate rule says carry-over **never auto-enables**, because a silently
enabled state can mislabel an entry unnoticed. Multi-voice deliberately does auto-enable.
Justification: a wrong voice attribute is visible in the editor and freely editable, while
a wrong backdate is a quiet data error. Recorded as a divergence, not an oversight.

## 3. Components

New unless marked.

**`FrameClockSink`** (Capture) — a `PCMSink` that accumulates `frameCount` into an atomic
`Int64` and exposes `currentFrame` readable from any thread. Installed as a **third tee
branch**, after the disk sink and `BoundedPCMSink`. This is the shape `TeeSink`'s own doc
comment prescribes: "a counter or a drop ledger would force `@unchecked` plus a lock on the
real-time tap thread — that bookkeeping belongs in a branch, which knows its own frame
cursor." One addition per chunk on the audio thread; nothing else.

Alternatives rejected: deriving the frame from the published `elapsed` timer (a wall-clock
accumulator that keeps running across an interruption whose audio never reached disk — it
would pass every test and drift silently on exactly the recordings that were interrupted),
and injecting markers into the PCM stream for the consumer to stamp (exact by construction,
but a union type down a path typed as audio, to buy accuracy discarded at the snap step).

**`StructureMarker`** (Capture) — `seq`, `frame`, `kind`, and `voice` for voice markers.

**`MarkerLog`** (Capture) — append-only JSONL writer/reader for
`transcript/markers.jsonl`, built like `LiveTranscriptStore`: `O_APPEND`, `lineEncoder()`
(**not** the shared `.prettyPrinted` encoder — it would tear every record in half), torn
trailing line dropped on read, and the three-answer read `.absent` / `.unreadable` /
`.present` rather than a bare array. **Opens lazily at first append**, never at capture
start (the T3 zero-byte-log lesson, restated as rev 2 rule 10).

**`CaptureCoordinator`** (existing, small addition) — main-actor `markVoice(_:)` and
`markParagraph()`; published `currentVoice` for the toggle. Markers hang off the
coordinator, **not** `TranscriptionSession`: they must survive a capture where
transcription never ran (no assets, denied permission, dead engine). They annotate the
audio, and the audio is what the app guarantees.

**`MarkerSnapping`** (pure) — markers + committed runs in, snapped boundaries out. No I/O,
no actor, no clock.

**`CaptureView`** (existing) — controls, §5.

**`EntryMetadata` + `LibraryScanner`** (existing, one field) — `multiVoice: Bool` on the
sidecar; the scan already walks every sidecar, so carry-over costs one field read.

## 4. On-disk format

`transcript/markers.jsonl`, one object per line:

```json
{"seq":0,"frame":0,"kind":"voice","voice":"bn"}
{"seq":1,"frame":812544,"kind":"paragraph"}
{"seq":2,"frame":1104128,"kind":"voice","voice":"ln"}
```

`frame` is on the `StampedChunk.startFrame` / `SegmentSidecar.startFrameOffset` axis —
position in `final/recording.m4a`, the same durable address the transcript uses.

Rules:

- Hand-written `init(from:)`. Identity fields (`seq`, `frame`, `kind`) strict; additive
  fields lenient. See appendix.
- `seq` detects **interior** loss only. A torn trailing line leaves a gapless `0..<n` with
  nothing to compare against, and unlike the transcript there is no `committedRecords`
  count to check against. **Tail loss in the marker log is undetectable.** Bounded damage:
  the final voice span runs long, which is visible and editable in T7. Stated rather than
  papered over.
- An unrecognized `kind` is **preserved and ignored**, not dropped. Costs one enum case;
  prevents a device on an older build from deleting a marker kind a newer build wrote.
  Reachable the moment M4 sync exists.
- Writing the first marker creates `transcript/`, flipping `holdsIrreplaceableArtifacts`
  so cleanup quarantines rather than deletes (issue #8 machinery). Correct, not incidental.

Single-voice entries carry no voice markers; the file may contain only paragraph markers,
or not exist at all.

## 5. UI

Pre-record, in the setup area beside journal and backdate: a **Two voices** toggle,
initialized from carry-over.

While recording:

- multi-voice on — a thumb-reach voice toggle showing the active voice (BN/LN), one tap to
  switch, plus an adjacent paragraph button.
- multi-voice off — paragraph button only.

Both controls pin `.environment(\.colorScheme, .dark)`; the capture screen pins a
near-black background and an ambient-scheme control renders dark-on-dark in light mode
(2026-08-02 rule, learned the hard way).

Both fire a haptic on tap. The owner is reading a page, not watching the screen —
confirmation has to be felt, not seen.

Controls are enabled only in `.recording`. Spoken commands ("new paragraph") stay rejected:
they collide with the journal text being read aloud.

## 6. Snapping

Input: markers plus committed `TranscriptRun`s. Window: **±1.5 s** around the raw frame, a
single named constant, to be tuned after a real page is read.

1. Collect inter-run gaps (run N end → run N+1 start) intersecting the window.
2. Pick the **largest** gap; ties resolve to the one nearest the raw frame.
3. No gap but a run boundary in the window → snap to the nearest boundary.
4. Nothing in the window (the tap landed inside one long run) → keep the raw frame and flag
   the boundary `approximate`, so T7 can surface it.

`TranscriptRun.captureFrameStart`/`End` are **optional, not merely imprecise** — Apple
documents that runs need carry no time range. Untimed runs cannot participate; fall back to
the record-level `captureFrameStart`/`End`.

## 7. Failure modes

- **Append fails** — `lastError` is set and the control shows a failure state. Recording is
  never interrupted: continuity of audio outranks marker fidelity. It does not fail
  silently (the 2026-08-03 "sidecar writes fail loudly" rule).
- **`markers.jsonl` unreadable** — promotion assigns **no** voice attributes rather than
  assuming single-voice. Never fabricate an answer from a failed read (the `journals.json`
  unreadable→empty collapse, 2026-08-02).
- **No transcript at all** — markers are still stored. Promotion has nothing to snap to and
  assigns nothing; T8 retranscription re-applies them. Markers outlive any given transcript,
  which is the point of keeping them out of the revision chain.
- **Interruption / resume** — `FrameClockSink` is constructed **once per capture** and
  installed at **both** `recorder.start` sites via the same tee identity. It must not reset
  on resume. This is the T1 lesson: a second branch that dies at the first interruption.
- **Crash mid-capture** — appended lines are already durable; recovery needs no marker work.
- **No frame clock installed** (UI-test harness) — markers are disabled outright rather than
  writing a stream of frame-0 markers.

## 8. Testing

Pure — `MarkerSnapping`: gap present, no gap, untimed runs, marker before the first run,
marker after the last, competing gaps, tie resolution.

`MarkerLog`: torn tail dropped; the first record after a torn tail is **not** fused onto it
(the exact T3 `O_APPEND` bug); `.absent` vs `.unreadable` vs `.present`; lazy creation —
no `transcript/` until the first append.

Decoder: missing additive field decodes; missing identity field throws; unknown `kind`
round-trips intact.

`FrameClockSink`: accumulates across a resume; **mutation-verified** that both
`recorder.start` sites install it, mirroring the existing T1 tee regression test.

Carry-over: per journal, from disk, survives a journal switch and back.

UI test: the voice controls appear and disappear with the toggle.

## 9. Task breakdown

1. `FrameClockSink` + tee wiring + resume-site regression test.
2. `StructureMarker` + `MarkerLog`.
3. Coordinator `markVoice`/`markParagraph` + `lastError` path.
4. `multiVoice` on the sidecar + per-journal carry-over.
5. `CaptureView` controls.
6. `MarkerSnapping` (pure).
7. T7 consumes the voice attribute — deferred to T7, not this build.

## 10. Open

- The ±1.5 s tolerance is a guess until a real page is read.
- T7 must render voice distinctly; the print/cursive instinct suggests a typeface change,
  which SwiftUI makes cheap. T7's call, not this doc's.

## Appendix — traps this codebase has already hit

Kept because whoever implements this (including a subagent) will otherwise repeat them.

**Swift's synthesized decoder ignores property defaults.** `var runs: [TranscriptRun] = []`
still throws `keyNotFound` on a line without the key; only `Optional` gets
`decodeIfPresent` from synthesis. Verified in T3 rev 3, where combined with a parser that
skips undecodable lines it would have silently erased every log rather than erroring.

**The shared JSON encoder is `.prettyPrinted`.** Used for a JSONL line it tears every
record across multiple lines. `lineEncoder()` exists for this.

**`O_APPEND` fuses the first record after a torn tail onto it**, losing both. Caught by T3's
own tests.

**A zero-byte log file flips `holdsIrreplaceableArtifacts`**, so eagerly opening a log at
factory time makes every mis-tap leave a permanently undeletable directory. Open lazily.
