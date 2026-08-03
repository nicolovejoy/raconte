# Backdate precedence — decision doc

2026-08-03. For an owner discussion, not a build plan. Owner said "let's discuss" (CLAUDE.md
next-steps #3).

## 1. The problem, mechanically

Three sources can set `EntryMetadata.originalDate`. The code today knows about two of them,
and cannot tell them apart.

**Surprise 1 — a manual backdate blocks detection entirely.**
`SpokenDateDetection.apply` (Raconte/Library/SpokenDateDetection.swift:25) applies the
detected date only `if metadata.originalDate == nil`. It still writes `detectedDate` — the
latch — and never runs again for that entry (line 18). So the detected date is recorded and
then *invisible*: the detail view's "Detected from the recording" label is gated on
`EntryMetadata.backdateWasDetected`, which is `originalDate == detectedDate`
(EntryMetadata.swift:100) — false in exactly this case. Dead data, and the latch means
clearing the backdate later doesn't bring it back.

**Surprise 2 — carry-over counts as manual, so a sitting never gets per-entry dates.**
`setBackdateEnabled(true)` pre-fills from `carriedBackdates[journal]`, then immediately calls
`rememberBackdate()` and `syncActiveEntryMetadata(clearingBackdateIfDisabled: true)`
(CaptureView.swift:330–347), which writes `originalDate` into the sidecar mid-recording.
`detectSpokenDate` deliberately awaits `pendingMetadataWrite` before testing (CaptureView.swift:435)
so that write is guaranteed to have landed. Result: detection is blocked for every capture in
the sitting.

Sharper still: **it is the toggle, not the dial, that blocks detection.** Toggle-on with no
carried value pre-fills `Date()` and writes *today* as the backdate — and `rememberBackdate()`
then stamps today as the journal's carry, so the carry is never absent again after the first
toggle.

Root cause in one line: the sidecar records *what* the backdate is, never *how it arose*, and
"the owner typed this" is the only thing that should outrank the recording.

## 2. Candidates

### A — UI only: never auto-overwrite, always surface

Precedence: manual (any kind) always wins; detection only ever writes when `originalDate == nil`
(i.e. today's rule, unchanged).
Change: always record `detectedDate`, and in the detail view show "Recording says March 1998 —
use it?" whenever `detectedDate != nil && detectedDate != originalDate`. One tap applies it.
Persisted state: none new. No migration.
UI: one row + button in `EntryDetailView`.
Failure modes: none data-losing. Cost: a 20-capture sitting with carry-over is 20 taps; the
friction that motivated carry-over just moves.

### B — `backdateOrigin` on the sidecar (the sketched design)

Precedence: **explicit > detected > carried > capture date.**
Persisted state: `var backdateOrigin: BackdateOrigin?` on `EntryMetadata`
(`explicit | carried | detected`). Additive and lenient on decode, like `detectedDate`
(EntryMetadata.swift:147) — never identity-strict, since a damaged origin must not make the
whole sidecar unreadable. Encoded only when `originalDate != nil`.
Migration: none. Absent origin + present `originalDate` (legacy sidecar) ⇒ read as `explicit`,
the conservative reading: an old hand-set date is never overwritten. Corpus is a handful of
entries on one phone; this is free now and expensive in three months.
Capture-screen state: origin is set at the point of intent — `.carried` on pre-fill,
`.explicit` on `setBackdateDate`/`setBackdatePrecision` and on the detail sheet's Save,
`.carried` (yieldable) for the toggle-on default. `SpokenDateDetection.apply` gains one clause:
apply when `originalDate == nil` **or** `backdateOrigin != .explicit`, stamping `.detected`.
UI: the existing "Detected from the recording" label now shows in the sitting case (it keys off
`backdateWasDetected`, which becomes true). Plus A's affordance for the cases detection declined.
Failure modes: a misdetection silently overwrites a deliberate carried date. The parser has one
documented false positive — a bare leading year ("2000 dollars was a lot", SpokenDateParser.swift:34)
— and it lands mid-sitting where the owner is least likely to check each entry. Second: the
capture header showed the carried date during recording and it changes underneath after finalize.

### C — B, minus the auto-overwrite of carried

Precedence: explicit > carried > capture date for what's *applied*; detection is applied
automatically only when nothing is set, and otherwise surfaced as A's one-tap affordance.
`backdateOrigin` is still stored, and drives whether the affordance is offered prominently
(carried) or quietly (explicit).
Persisted state and migration: same as B.
Failure modes: same friction as A for the sitting case, but the origin field is already in the
format, so flipping to B later is a one-line rule change and no migration.

## 3. Recommendation

**B, with A's affordance included, not as an alternative to it.**

- The origin field is the only thing that makes the sitting case fixable at all, and it is free
  to add now (tiny corpus, lenient decode, no migration) and not free later.
- A alone leaves the motivating case — read a paper journal aloud for an hour, get per-entry
  dates — unsolved.
- The misdetection risk is bounded by the affordance: detected ≠ carried is visible on the entry
  (label already exists) and the detail sheet can offer "restore <carried date>" using the same
  comparison. Detection also can't loop — the latch stands.
- `backdateOrigin` is a natural seed for T6's revision/audit chain but should not try to be it:
  it's one enum, not a history.

Ship order if the discussion stalls: A first (small, fixes the invisible-data bug on its own),
then B once the owner has seen detection quality on real recordings.

## 4. Open questions

1. Auto-overwrite of a carried backdate by detection — yes (B) or tap-to-apply (C)? This is the
   whole decision; everything else follows.
2. Does a detected date update the journal's carry-over for the *next* capture, or does carry
   stay "what the owner last dialled"? (Recommend: carry stays what he dialled.)
3. Toggle-on with no carried value currently writes **today** as a backdate and mints it as the
   journal's carry. Should the toggle write nothing until the picker is touched? Doing only this
   fixes a large share of surprise 2 by itself.
4. Legacy sidecars — `originalDate` present, no origin — read as `explicit` (never overwritten)?
5. Should the "use detected date" affordance appear even when the applied date is `explicit`
   (read-only, one tap, never automatic)? Recommend yes; it costs nothing and closes surprise 1.
