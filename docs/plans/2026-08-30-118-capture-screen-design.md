# Capture screen design pass (#118)

Owner-ratified 2026-08-30. Supersedes the capture half of
`2026-08-29-ux-redesign-design.md` ("Capture landing (PR 4)"), whose idle-state spec
assumed capture was the app's landing screen. It is not, and PR 4 was consciously
replaced by Home (#115) and never re-planned.

Mockup reviewed at smoke: https://claude.ai/code/artifact/d62b442d-7ecf-497b-b5c5-42b87ee0c391
(its Ready state shows a centred record button — **superseded by §2 below**.)

## 0. What changed about the problem

Every route into capture now starts recording on arrival: the library's floating button
and Home's "New entry" both call `CaptureScreenModel.beginCapture(inJournal:)`. So
`.setup` stopped being a screen you pass *through* on the way to recording, and became a
screen you land on *after* one — by discarding, by dismissing a receipt, or by clicking
Capture in the sidebar.

It also duplicates Home. Of the six things in the idle band, Home already renders the
recovery banners (`HomeView.recoveryBanners`, identical call-site arguments — verified,
not assumed) and the last entry, and About is where the build stamp belongs.

## 1. Scope

`CaptureMachine` is untouched. `CaptureLayoutModel`'s three modes stay. What changes is
what each mode renders, plus one contained behaviour change (§4) and one new pure
accessor (§5).

## 2. The control bar never moves — in any state

**The record control stays in the bottom bar in all three modes.** The old PR-4 idea of a
centred 76 pt button in a 96 pt halo on the idle screen is dropped.

That halo was designed when capture was the front door and the idle state had to *invite*
you to start. It no longer is, so the reasoning doesn't survive. And keeping the bar
constant is better on its own terms:

- The #53 invariant holds absolutely instead of holding "except at a moment you rarely
  see". Exceptions rot: a new route to Ready turns the exception back into the defect.
- You operate this screen while looking at a page, not at the screen. A record/stop
  control in one fixed position is worth more than a handsome idle state.
- `CaptureView.controlBar`'s own doc comment already states the rule as absolute:
  "Present in every phase so it never appears, disappears, or resizes under the owner's
  thumb mid-reading."

Consequence: Ready and Recording differ **only** in the middle band (empty vs. transcript)
and in what the status row says. Nothing that matters moves between them.

## 3. The three states

### Ready

Top: journal name + chevron (picker sheet), and the compact backdate line.
Middle: empty.
Bottom: the bar, reading `0:00 · Ready`.

Removed from this band: `MultiVoiceField` (§4), the `RecoveryBanner` loop,
`lastEntrySection`, `BuildInfo.stamp` (§7).

Three `CaptureLayoutModel` flags become permanently false — `showsLastEntry`,
`showsMultiVoiceField`, `showsRecoveryBanners`. They are **deleted**, not pinned false;
dead flags are the #74 complaint. Their tests go with them.

Owner at smoke, on the last-entry card: *"there's the previous transcript text… don't
want that there."* It was the card doing its job, not a stale transcript region — no bug
on main, and this removes it.

### Recording

Top: journal name, compact backdate line.
Middle: the live transcript (§5), filling everything above the bar.
Bottom: the bar — status row (dot, timer, "Recording", Discard), meter, then
voice-switch / stop / paragraph.

Bar geometry is unchanged. Every rule in `CaptureControlBarMetrics` stands.

### Receipt

Owner at smoke: *"I like the receipt page fine, nice to see the text there."* Structure
approved; two changes.

**"Record another" is deleted.** It sat directly above the bar's own record button, so the
screen offered two ways to start the next reading — and making it a red mic, as first
asked, would have put two mic buttons on one screen. The bar's record button now dismisses
the receipt and starts the next reading in one tap. One record control, one position.

**The entry becomes a tappable card, not a bare "Open" button.** Owner: *"maybe show the
entry in a box that's clearly 'click to open'-able or (view/edit). Open isn't super clear
here."* The dated, headed prose block becomes the tap target, styled so it reads as
openable, labelled view/edit rather than "Open".

## 4. Two voices stops being a toggle

`MultiVoiceField`, `multiVoiceOverrides`, `setMultiVoiceEnabled`, `multiVoiceEnabled` and
`LibraryScreenModel.lastMultiVoice` are deleted. `MarkerControlsModel.make` loses its
`multiVoice:` parameter and gates on phase alone, so the BN/LN switch is present in every
recording.

`markVoice` calls `markOpeningVoice()` first; the existing `didWriteOpeningVoice` guard
already makes that idempotent, and the opener is still written at literal frame 0. The
first live mark also writes `multiVoice: true` to the entry's sidecar.

**Why this is safe.** The pre-record gate existed only to arm the live switch. Nothing is
lost by dropping it, because `VoiceMarkingPlan.openerIfNeeded` / `addOpeningVoice` already
synthesizes a frame-0 opener for any entry lacking one — the post-hoc Mark Voices editor
can convert a single-voice recording into a fully marked two-voice one. What the gate cost
was live thumb-marking on a journal's *first* two-voice reading, which arriving-recording
made unreachable.

**`metadata.multiVoice` keeps its exact meaning.** It is a synced, LWW-merged CloudKit
field with a per-field `modified` stamp (`SyncIngest.swift:885`) and is read by
`CaptureReceipt`. It is written at a different moment, never redefined.

## 5. Live transcript

New pure accessor on `TranscriptConsolidator` exposing the ordered runs with an
`isProvisional` flag, built from the same frame-position sort `displayText` already
performs. `displayText` becomes derived from it so the two cannot drift.

The view composes one `AttributedString`: committed text at full strength, the live
hypothesis dimmed. New York serif, matching the receipt and entry detail — the same words
in the same face from the moment they appear.

**The old spec is unbuildable as written.** "Current sentence full-white, earlier text
dimmed" needs sentence boundaries, which nothing in the pipeline tracks. The real seam is
`committed` vs `provisional`.

**The trap.** The consolidator merges by frame position, not arrival order, precisely
because results come back out of order. A hypothesis is therefore *not* reliably a
trailing suffix — it can land mid-text. "Dim the tail" is wrong on exactly the case the
consolidator exists to handle.

**Test requirement.** A fixture that feeds results in order passes without exercising
anything. This spec needs a proof-of-RED step and an adversarial reviewer; the repo has 13
recorded instances of this exact failure.

**Check first, before building.** Instrument the consolidator and record a minute of
speech to measure how long text stays provisional. If the window is short, the tail of the
transcript changes brightness continuously while reading aloud — motion in peripheral
vision, which is the opposite of the screen's job. Cheap to measure; expensive to discover
after the build.

## 6. Backdate

The compact one-line summary appears on **both** Ready and Recording, tapping through to
the same write-through editor sheet. Owner: *"it's important to be able to back date
whenever, basically."*

**The audit trail he asked for already exists.** `EntryLogRecord` records `at`, `field`,
`from`, `to` and `cause` per changed field, including `originalDate`, and carries a
forward-declared `origin` for `BackdateOrigin` that nothing writes yet. Capture's backdate
writes go through `EntryMetadataStore.update`, the same chokepoint that produces the diff —
verified, so history is recorded on this path too. Undo is buildable on it later; nothing
is needed here.

## 7. Two corrections riding along

**`BuildInfo.stamp` moves to About**, beside Version. It currently exists only in
`CaptureView`, twice — the 2026-08-29 doc's claim that it "moves to About only" was a plan
that never ran. About shows `AppVersion.current()` ("1.0 (12)"), a different fact from
"built Aug 30, 9:24 AM PT"; the build *time* is what identifies a wireless or TestFlight
install.

**A stale justification, in FOUR places — not three.** `JournalHeaderView` (:533),
`BackdateField` (:627), `MultiVoiceField` (:724) and **`RecordControlsRow` (:890)** defend
their `.environment(\.colorScheme, .dark)` pins by calling `CaptureView` "the app's one
permanently-mounted NavigationStack root". The nav redesign made that false. The pins stay
correct; the stated reason does not, and a reader will act on it.

This list originally said three and omitted `RecordControlsRow` — corrected 2026-08-30
after the cloud session working this task found the fourth. `grep -n permanently` finds
all four; a grep for the full phrase `permanently-mounted` finds only three, because
`JournalHeaderView`'s copy is hyphenated across a line break. **Grep the distinctive word,
not the phrase.**

## 8. Token pass

`CaptureView`'s colour literals (`.white`, `.white.opacity(0.35)`,
`Color.green.opacity(0.22)`) move into `InkTone`. Capture surfaces stay pinned `.studio`
regardless of system appearance, and any system control placed there keeps its
`.environment(\.colorScheme, .dark)` pin.

## 9. Out of scope

- Back destination from an entry → #86 (owner raised it at this smoke).
- Time of day on current-week entry rows → #125.
- Whether the main record button should be red rather than white — owner asked for a red
  mic on "Record another", which §3 deletes. A red record control generally is a separate
  decision he has not made.
