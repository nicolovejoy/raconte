# User journeys

Purpose: concrete walk-throughs to pressure-test the data model and UI, before M3/M5 build it.

Status: draft for owner edit, 2026-08-02

---

## 1. Reading an old paper journal entry aloud (phone) — core dogfooding loop

Who/when: Nico, evenings, working through a box of paper journals decades old.

1. Opens Raconte on iPhone. Taps capture (or "capture" defaults into this flow while
   dogfooding is the primary use).
2. Before or after recording, sets **original date** — the date written on the paper page.
   [DRAFT — react] Where does this live in the UI: a field on the capture screen itself,
   or a required step on the review screen right after stopping? Setting it before
   recording risks friction (typing a date before speaking a word); setting it after risks
   the entry ever getting left undated if he walks away.
3. Reads the entry aloud, verbatim or paraphrased, however long it runs.
4. Taps stop. App finalizes (see M1 recovery machine — this part is done and hardened).
5. Entry now carries two dates: **originalDate** (March 1998, the paper page) and
   **capturedAt** (today, automatic, always exact). Library browses by originalDate by
   default.
6. Repeats for the next entry, possibly the next several pages in one sitting.

Open questions:
- Date precision: paper entries are sometimes undated or only "spring 1998" — does
  originalDate need the same precision field as the web app (`entry.json` had this)?
- Batching: reading 10 entries in a row — does the app remember "still reading this
  journal" so date entry can be relative ("day after the last one") instead of typed
  fresh each time?

---

## 2. A present-day spoken entry — no backdating

Who/when: Nico, any day, talking about today.

1. Opens Raconte, taps capture, talks.
2. Stops. No date step needed — originalDate defaults to capturedAt (today).
3. Entry lands in the library at today's date, same as M1 always assumed.

Open questions:
- Does the UI need to visibly distinguish "same-day" entries from backdated ones in the
  library, or is originalDate == capturedAt enough to imply it silently?

---

## 3. Quick review on the phone right after capture

Who/when: Nico, seconds after tapping stop, still holding the phone.

1. Review screen shows the finalized audio and the live transcript's last committed text
   (the "tail" — same mechanism already verified in the transcript tail fix, see
   `docs/m1-smoke-log.md` run 12).
2. He skims the tail for anything obviously wrong (a name mangled, a date misheard) but
   does **not** correct anything here — phone is capture/glance, not the editing surface.
3. Optionally taps play to hear a snippet back.
4. Leaves it. Trusts that the Mac editorial session is where correction happens.

Open questions:
- [DRAFT — react] Should phone review allow *any* edit (e.g. fixing a date, deleting a
  bad take) or is it strictly read-only by design? A hard no-edit rule is simpler to
  reason about but he may want to delete a botched capture on the spot.
- Does "trusting the tail" mean the phone shows only committed (non-volatile) text, never
  a volatile hypothesis that might still change? (M2 design already distinguishes these —
  worth confirming the review screen picks committed only.)

---

## 4. Editorial session on the Mac — correcting a transcript against audio

Who/when: Nico, at a desk, dedicated correction time.

1. Opens Raconte on Mac, picks an entry from the library (recent captures surfaced first,
   or filtered to "needs review").
2. Three-pane-ish reading view (per the rebuild plan's Mac reading polish idea): audio
   waveform/scrubber, transcript text, maybe metadata (dates, journal).
3. Plays audio, follows along the transcript, clicks into a wrong word/phrase, retypes it.
4. Each edit is captured as part of a **human revision** — append-only, never overwrites
   the machine transcript that came from SpeechAnalyzer.
5. Can review revision history for the entry: machine v1 (from capture), human v1 (his
   edits), etc.
6. Saves / moves to next entry.

Open questions:
- Revision granularity: is a "human revision" one per editorial session (batch of edits,
  committed on save/navigate-away), or one per individual text change? Session-level is
  probably right (matches how a human actually works) but changes the data model shape.
- Does editing require playing the audio through that segment first (forcing verification),
  or can he freely retype without listening (faster but defeats "audio is ground truth")?

---

## 5. Retranscription after a better model arrives

Who/when: Nico, whenever SpeechAnalyzer/SpeechTranscriber improves or a new locale model
lands, likely infrequent and manual-triggered.

1. On an entry (or a batch), taps "retranscribe from audio."
2. App re-runs the transcription engine against `final/recording.m4a` (never the live
   pass — already the governing rule from the M2 design).
3. New **machine revision** is appended to the chain. Human edits from prior revisions
   are **not** touched or reapplied automatically — they stand as their own layer.
4. He can now compare: old machine text vs. new machine text vs. his human-edited text.
   [DRAFT — react] What does "compare" look like — a diff view, or just three tabs? A
   diff view is probably the whole point of this journey but is real UI work.

Open questions:
- If he already hand-corrected a passage and the new machine pass gets it right too, is
  there any prompt to say "machine now agrees with your edit, nothing to do" — or does
  that require a smarter reconciliation than "just append a new revision"?
- Batch retranscription (whole archive at once, e.g. after M2's fallback path improves) —
  is that a v1 need or purely hypothetical until it's cheap/fast enough to not think about?

---

## 6. Browsing and rereading years later — the payoff journey

Who/when: Nico, far future, looking back at either paper-archive imports or his own
present-day entries.

1. Opens library, browsed by originalDate (paper entries sit chronologically alongside
   present-day ones, indistinguishable by browse position — only a subtle marker shows
   which is which, if any).
2. Picks a journal or a date range, reads down the list of entries.
3. Opens one, reads the (human-corrected, if it went through Mac editorial) transcript,
   plays audio if he wants the original voice/inflection.
4. This is silent, read-only browsing — no correction, no recording.

Open questions:
- [DRAFT — react] Does the library visually separate "paper archive, backdated" entries
  from "spoken live" entries, or is the unification (one timeline, one truth) the whole
  point and any visual split undermines it?

---

## 7. Search for a remembered moment

Who/when: Nico, trying to find "that entry where I talked about X" — could be a name,
place, or approximate time.

1. Opens search (FTS5, per the plan of record), types a word or phrase.
2. Results show snippet matches with highlighting, entries ranked (recency? relevance?
   originalDate proximity to a remembered rough time?).
3. Taps a result, lands on the entry in the reading view (journey 6 from here).

Open questions:
- Does search index the machine transcript, the human-corrected transcript, or both
  (and if a word only appears in the machine version because a human edit removed it,
  does that still surface)? This is a direct consequence of the revision-chain design
  and needs an explicit answer before FTS5 indexing is built.
- Search by original date range vs. capture date range — does the search UI expose both,
  or default to originalDate only (matching the browse default in journey 6)?

---

## 8. Recovering from an interrupted or killed capture — trust journey

Who/when: Nico, phone call comes in mid-entry, or app gets force-quit/OS-killed, or he
force-quits by mistake.

1. Mid-capture interruption (call, route change) — state machine already handles this
   (M1, hardened, stress-verified). App shows "interrupted," resumes or finalizes per the
   existing recovery design.
2. On next app launch after a kill, recovery scan runs automatically: "Recovered
   recording: Xm Ys" — already a verified, tested feature (M1).
3. He sees the recovered entry in the library, dated (originalDate = capturedAt, since a
   kill mid-dictation of a paper entry would need the date he'd set going in — see
   journey 1's open question about *when* originalDate gets set, because a kill before
   that step means the recovered entry has no original date yet).
4. Trusts the recording is intact; plays it back to confirm before doing anything else.

Open questions:
- Direct fallout of journey 1's unresolved question: if originalDate is meant to be set
  *before* recording starts, does the recovery flow need a "confirm/set original date"
  prompt baked in, since a kill could happen before that step ever ran?
- Does a recovered-but-interrupted paper-reading session need a way to say "I was still
  mid-page, don't count this as a complete entry yet" — i.e. a draft/incomplete state
  distinct from a normal finalized entry?

---

## 9. Migrating the frozen recountly.org web entries in

Who/when: Nico, one-time (or few-time) migration pass, per the M3 plan-of-record line
("one-evening script exporting Neon rows + private blobs").

1. Runs the migration script (not app UI — a one-off tool) against the frozen web app's
   Neon DB + blob storage.
2. Script maps web entries (~50, including the 23 paper-archive imports already done on
   the web) into Raconte's local store: audio → segment/final files, transcript text →
   an initial machine-revision-equivalent (or is it treated as already-human-edited,
   since the web transcripts were manually typed/corrected in the old app?).
3. Entries appear in the library alongside newly captured ones, same browse/search/reading
   experience.
4. Spot-checks a handful against the live web app before trusting the migration and
   proceeding to the teardown checklist (per the rebuild plan).

Open questions:
- [DRAFT — react] Web-app transcripts were hand-authored/corrected in the old system —
  do they import as a **human revision** (since a person wrote them) with no machine
  revision underneath, or does that break the "machine transcript always exists as the
  base layer" invariant the revision chain otherwise guarantees? This is the biggest open
  question in this journey and probably needs a decision before the migration script is
  written, not after.
- Photos and page-label metadata (23 paper-archive imports) — folded into this same
  script, or a separate pass?

---

## Design tensions surfaced — need owner decisions

1. When `originalDate` gets set — before recording (friction) or after (a kill mid-capture
   leaves the entry undated). Touches journeys 1 and 8.
2. Is phone review strictly read-only, or can it delete/fix on the spot? Any edit leaking
   onto the phone dilutes the two-surface model. Journey 3.
3. Human-revision granularity: per editorial session vs. per individual change. Data-model
   shape, not just UI. Journey 4.
4. What FTS5 indexes: machine transcript, human-corrected, or both. Must be settled before
   indexing is built. Journey 7.
5. Migration: old web transcripts are hand-authored with no machine layer beneath — import
   as a human revision without a machine base, or does that break the revision-chain
   invariant? Decide before the script is written. Journey 9.
