# Journal-page photo snapshots — design

2026-08-09. Owner-decided in session (options quoted where he chose). Status: approved
design, unbuilt. Follows the T6 provenance story; builds after T7 unless resequenced.

## Model

The PAPER journal is the source of truth. The recording (the owner reading the page
aloud) and the page photo are both *representations* of it. The photo is a **human
reference only** — something to look at beside the transcript when verifying or
correcting. Owner ruling: no machine-reading ambition, ever ("no machine will be
invented in my lifetime that can read my terrible handwriting"). Fidelity bar is
legible-on-screen, not archival.

## Decisions

1. **One photo per entry; retake replaces.** Matches page-per-entry (T6 §12). A spread
   is framed as one shot. No gallery, no ordering, no primary-selection UI.
2. **Both attach paths.** Capture-time snap on the capture screen (camera only) as the
   happy path; detail-view attach (camera + photo library, same PhotosPicker pattern as
   journal covers) for entries that already exist.
3. **Viewing aid only at launch.** No provenance semantics in the data. The
   "corrected against the page" revision flag is deferred, deliberately cheap to add
   later: `RevisionSource` already tolerates unknown raw values, so a new source/flag
   needs no migration. Decide when the T7 editor exists and its value is testable.
4. **Deferred, not precluded: batch-snap queue.** Owner use case: photograph the next
   five pages, then record entries one at a time, each queued photo becoming the next
   entry's page. Not at launch. The design keeps the door open because a photo can
   exist on an entry before its recording does (path 2 plus capture-time snap-before-
   record); nothing else is built for it.

## Storage (approach chosen: capture-directory sidecar file)

`page.jpg` lives in the entry's capture directory, referenced from `entry.json`
(a `PagePhotoRef`, mirroring `TranscriptRef`): presence in the sidecar is the claim,
the file on disk is the fact, and the read path answers three ways —
absent / unreadable / present — never collapsing unreadable into absent.

Ingest re-encodes through ImageIO exactly like `JournalCoverStore`: strips EXIF
(location above all), bounds the long edge (~2500 px) at ~0.8 quality. Knobs, not
commitments. Camera originals are never stored (10+ MB, location-bearing).

Why this and not the M3 photos table: the photo is conceptually part of the entry, and
the capture directory already has every lifecycle the photo needs — the recovery scan,
30-day trash, staged removal (#25), and eventually M4 sync as one more asset on the
entry's record. A photos-table owner would re-create orphan handling, sweep rules, and
sync mapping that the entry model already solved.

**`holdsIrreplaceableArtifacts` must include the page photo.** Once the journal is
reshelved the photo is as irreplaceable as the m4a; a directory holding one is
quarantined, never deleted, same as today's rule for audio and transcripts.

Deletion: retake replaces atomically (write new, rename over); explicit remove is
allowed with a confirm, and goes through staged removal like every other artifact.

## UI shape (v1)

- Capture screen: optional snap affordance (camera only). Skippable, zero-friction
  when unused. Control pins `.environment(\.colorScheme, .dark)` per the ledger rule.
- Detail view: show the photo (tap to zoom), attach / retake / remove.
- T7 editor: side-by-side photo pane is a line item in the T7 plan, not built here.

## Rejected

- Photos table as owner (second lifecycle for one entry-owned file).
- Storing camera originals (size, EXIF/location, no fidelity need beyond legibility).
- Any OCR/vision path (owner ruling above).
- Multi-photo entries (revisit only if real pages defeat single-shot legibility).
