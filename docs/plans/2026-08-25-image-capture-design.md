# Image capture on entries — design

2026-08-25. Design for image capture: any entry can carry photographed/imported images,
with the same durability guarantees audio already gets.

## Intent

"Audio is ground truth; the transcript is a derived, replaceable interpretation" (project
principle) generalizes: **the captured artifact is ground truth.** An image the owner adds
to an entry — a photographed page of a paper journal, a snapshot taken in the moment — has
the same standing as a recorded voice. Original bytes are stored byte-for-byte, digested
and synced exactly like audio; nothing derived from them (a thumbnail) is ever treated as
the record.

This also completes a data-model gap the app already tolerates: an entry today is really
"a capture directory," and the only durable content it can hold is audio and its derived
transcript. Images are a second, independent kind of durable content an entry can hold,
and — new here — an entry can hold images with *no* audio at all (a photographed drawing).
That case forces two small, real extensions to existing machinery (§5), not just a new
record type; both are called out below rather than glossed over.

## Data model

No GRDB. This codebase's actual entry storage (`Raconte/Capture/SegmentLayout.swift`,
`Raconte/Library/AppContainer.swift`) is file-based: one entry = one `captures/<ULID>/`
directory, `manifest.json` (capture-machine state) + `entry.json` (user metadata) beside
it. The 2026-07-29 data-model doc's GRDB `photos`/`audio_assets` tables were never built —
GRDB does not appear anywhere in `Raconte/`. This design follows the code, not that plan.

Images are a new sibling directory inside the capture directory, mirroring how
`transcript/` sits beside `final/`:

```
captures/<captureID>/
  manifest.json
  entry.json
  final/recording.m4a        (absent for an image-only or text-only entry)
  transcript/…
  images/
    <imageID>.orig            original bytes, verbatim, no re-encode
    <imageID>.json            per-image sidecar (below)
    thumbnails/<imageID>.jpg  derived, regenerable (§ Thumbnails)
```

`<imageID>` is a ULID (`ULID.make()`), matching every other id in the codebase
(`revisions`, staging names). ULID's time-sortability is what gives "0..n images,
ordered" a free answer: **display order is ULID order** (== attachment order), no
separate index field needed — the same reasoning `photos_entry` indexed on `(entryId,
id)` in the old plan, just without a database. `.orig`'s extension is the real one
(`.jpg`, `.heic`, `.png`, …), inferred from the source's UTType at write time; the
sidecar is the source of truth for MIME, not the extension.

`SegmentLayout` gains:
```swift
static func imagesDirectory(captureDirectory: URL) -> URL
static func imageOriginalURL(captureDirectory: URL, imageID: String, ext: String) -> URL
static func imageSidecarURL(captureDirectory: URL, imageID: String) -> URL
static func imageThumbnailURL(captureDirectory: URL, imageID: String) -> URL
```

Per-image sidecar `<imageID>.json` (own file, not folded into `entry.json` — an image
never changes once added, so its metadata is write-once like a segment sidecar, not
read-modify-write like `entry.json`):

```json
{
  "id": "01J...",
  "originalExtension": "heic",
  "mime": "image/heic",
  "bytes": 2481932,
  "sha256": "…",
  "width": 4032,
  "height": 3024,
  "capturedAt": "2026-08-25T18:04:00.123Z",   // EXIF DateTimeOriginal if present, else nil
  "addedAt": "2026-08-25T18:04:12.456Z"        // when this device wrote the file
}
```

Order of images = ascending `id`. Default max image count per entry: **none enforced in
v1** — YAGNI; if the owner hits a real ceiling (dozens on one entry), revisit. HEIC and
JPEG (and PNG, etc.) are equally fine as originals — decision 1 already settles "keep
bytes verbatim," so format is a non-issue; no conversion, ever.

**Deletion of one image**: `rm` the `.orig`/`.json`/thumbnail trio. Simple, since images
are write-once, order-only, no cross-references besides the parent capture directory
(reversed by the entry's own trash lifecycle — see below).

### Text, for an entry with no audio

Decision 3: no new field. `EntryMetadata`/the transcript-revision chain already store
"the text," provenance included — `transcript_revisions.source` (in the pre-M4 GRDB plan)
maps to this codebase's `TranscriptRevisionStore` revision-chain `source` tag on each
`canonical-<n>.json`. For an entry with no audio, the user types directly into the same
editor (`TranscriptEditorView`/`TranscriptEditorModel`) that edits a transcript today; the
resulting revision is tagged `source: userEdit` exactly as a manual correction to a real
transcript is today (`TranscriptRevisionStore` already has this source case — no new
enum value). No caption field, no second text concept.

### Entry existence with no audio

An entry created via "+ New entry" (§ UI surfaces) has no audio and — until images or
text are added — nothing durable at all. It still needs a `captures/<id>/` directory the
rest of the app can recognize uniformly (library scan, recovery, sync eligibility), so
creation writes a **minimal, already-finalized manifest**:

```
state: .complete
final.verifiedAt: <createdAt>     // nothing to verify; set immediately
final.durationFrames: 0
final/recording.m4a: absent
```

This is a deliberate reuse, not a new "kind" of capture: every place that currently asks
"is this capture sync-eligible / recovery-safe / done" (`FinalizeArtifactPush.isFinalized`,
`RecoveryPlanner`, the library scan) reads `manifest.final.verifiedAt != nil` and nothing
else about *why* — a blank entry is trivially, honestly "already finalized" because there
is no audio pipeline to run. No separate "no-manifest" branch has to be threaded through
recovery, sync, or the library scan. `Manifest.final.durationFrames = 0` with no
`recording.m4a` file must never be read as "zero-length real recording" anywhere audio
duration is displayed — `EntryListItem`/detail already compute duration from segment/
manifest frames, which is honestly `0` here.

## Sync mapping

New CloudKit record type `Image`, mirroring `AudioAsset` exactly (`Raconte/Sync/
SyncRecordFamily.swift`, `SyncRecordBuilders.swift`):

```swift
enum SyncRecordType { static let image = "Image" }        // new case, existing enum

enum SyncImageField {
    static let originalExtension = "originalExtension"
    static let width = "width"
    static let height = "height"
    static let capturedAt = "capturedAt"       // EXIF date, optional
}
```

Shared fields via the existing `SyncChildAssetField` (`file`, `sha256`, `bytes`,
`entryRef`) — identical to `AudioAsset`/`LiveLog`/`Revision`. `entryRef` carries
`.deleteSelf`, so purging an Entry cascades its images server-side, same as every other
child record (design precedent: `docs/plans/2026-07-29-data-model-and-migration.md` §2,
"Parent references for cascade").

`SyncRecordName` gains `.image(captureID:imageID:)` — record name embeds both, mirroring
`.revision(id:)`'s "own id, no captureID" EXCEPT images DO embed captureID in the name
(unlike revisions, an image is not independently addressable across a capture move —
there is no cross-capture image reference to preserve identity for). Record name:
`i.<captureID>.<imageID>` (a new prefix; `SyncCloudIdentifiers` already owns the naming
scheme — extend it, don't reinvent it).

**Push eligibility — the real gap.** `FinalizeArtifactPush.namesToPush` currently appends
`.audio` unconditionally once a capture is finalized (`Raconte/Sync/
SyncRecordBuilders.swift`), which assumes every finalized capture has audio. It does not,
now. Two fixes, both narrow:

1. `.audio` is pushed only when `final/recording.m4a` actually exists — the same
   readability-probe pattern already used for `.liveLog`/`.markerStream` (`try?
   Data(contentsOf:)`), not a bare existence check, for the identical "unreadable read as
   absent" reason those two already document.
2. `.image(captureID:imageID:)` is appended once per file under `images/` whose sidecar
   (`<imageID>.json`) is present and readable — same probe.

Everything downstream (`SyncRecordExchange.recordToPush`, `entryCanBePushed`'s "child
safe to push once Entry has landed or would land alongside it" gate) already generalizes
per-record-name; adding a case to the `switch` in `recordToPush(for:zoneID:)` and an
`imageRecordToPush` sibling of `audioRecordToPush`/`revisionRecordToPush` (hash the
`.orig` file, build the record, `note(build:)` into the upload ledger) is the whole of it
— no change to the ledger/digest/reconcile machinery, which is already per-record-name
generic.

**Fetch / ingest — land-or-park (issue #85's rule, non-negotiable here).** An inbound
`Image` record can arrive:
- **After its Entry already exists locally** — the ordinary case. Verify sha256, write
  `.orig`/`.json`/regenerate thumbnail directly into `captures/<captureID>/images/`.
- **Before its Entry has committed locally** (new-entry ingest is multi-record and
  unordered, design precedent `EntryIngest`/`EntryAssembler`) — durably parked at
  `sync/staging/<captureID>/pending-images.json`, same shape as `PendingRevision`/
  `ParkedRevisions` (`Raconte/Sync/SyncIngest.swift`): id, verified bytes, park reason.
  `EntryAssembler.assemble`'s `pruneUnexpectedStagingContents` allow-list must learn this
  filename or a park is silently deleted at commit — the exact fix-round bug `pending-
  revisions.json`/`pending-marker-streams.json` already had to be added there for.
- **For an entry that is locally trashed** — same `knownToHaveExisted` re-park rule
  `ParkedRevisions` uses: an image for a trashed entry is parked, not discarded, and
  rehydrated if the entry is restored; purged (with the rest of the directory) only when
  the entry is permanently purged.

CKSyncEngine never redelivers a consumed record (project lesson, `inbound-sync-must-
land-or-park.md`) — a fetched Image that is dropped on any of these paths (a transient
disk error, a bug) is gone forever unless durably parked before the fetch handler
returns, exactly like every other child record type already does. No new mechanism:
reuse the parked-queue pattern verbatim, keyed by `imageID` (content-addressed, so
`accumulate` is a set-union, not a list append — a redelivered duplicate for the same
`imageID` is a no-op).

Environment-tag gate (#90) and wipe/resync (`docs/plans/2026-08-24-90-environment-tag-
design.md`) apply unchanged: a wipe drops ledger + system fields for Image records the
same as any other, and the forced full refetch after a wipe redelivers them through the
same land-or-park path. Nothing about images is special-cased in that machinery.

## UI surfaces

**Entry detail** (`EntryDetailView.swift`): new "Images" section, a horizontal strip of
thumbnails (tap → full-screen viewer, swipe between images, a "Remove" action per image —
decision 10). A "Capture Image" button opens the platform picker (below). Sits between
`playbackSection` and `transcriptSection` — images are evidence alongside the recording,
not billed above or below it. For an image-only entry, `playbackSection` is empty/hidden
(no audio) and the images strip is the primary content, shown first.

**Entry list row** (`LibraryEntryRow` in `LibraryView.swift`): a small leading thumbnail
(the first/oldest image, ULID order) on any row whose entry has ≥1 image. For an
image-only entry (no `snippet`), the thumbnail sits where the transcript snippet
(`library.row.snippet`) would — same row layout, one slot filled by whichever content
exists. Accessibility identifier `library.row.thumbnail`, mirroring the existing
`library.row.<field>` convention.

**Blank-entry creation** ("+ New entry", decision 4): a toolbar action on the entry list
(`LibraryView`), visible for both All Entries and a scoped journal. Mints a captureID,
writes the minimal manifest (§ Data model), and — when launched from a scoped journal —
sets `entry.json.journalID` to that journal so the new entry files itself correctly from
creation, matching how a capture started from within a journal already behaves. Routes
straight to `EntryDetailView` for that captureID (`LibraryDestination.entry(captureID)`,
existing enum — no new destination case). No picker-first flow: the owner always lands on
the (mostly empty) detail screen and chooses what to add from there.

**Per-platform capture sources** (decision 5), all funneling into one `onPick: (Data,
UTType) async -> Bool` shape on the detail screen, matching `JournalCoverPickerSheet`'s
existing `onPick: (Data) async -> Bool` convention exactly (that sheet is the direct
precedent — `PhotosPicker` + `UIImagePickerController` camera wrapper already exist in
this codebase, at `Raconte/Library/UI/JournalCoverPickerSheet.swift` and its
`CameraCapture` helper):
- **iOS/iPadOS**: `PhotosPicker` (multi-select — `matching: .images`, no `selectionLimit`
  cap on a picker single entries reasonably return from) + in-app camera
  (`UIImagePickerController.isSourceTypeAvailable(.camera)` guard, same as the cover
  picker).
- **macOS**: `fileImporter` (`UTType.image` content types), drag-and-drop onto the entry
  detail screen AND the entry list row (`.onDrop(of: [.image], …)`), and paste
  (`NSPasteboard` image read, wired to a `⌘V` command or an Edit-menu item while the
  detail screen has focus).
- **iPad drag-and-drop**: only if it falls out of the macOS `.onDrop` modifier for free
  (SwiftUI's `.onDrop` works on iPadOS with no extra code in the common case) — not a
  separate iPad-specific implementation. Skip if it doesn't.

**Language** (decision 6): button label "Capture Image…" (ellipsis — it opens a picker,
matching "Choose from Library…"/"Take Photo…" ellipsis convention already in
`JournalCoverPickerSheet`). Empty state: "Nothing captured yet" (not "No images" — stays
in the capture voice). No "attach"/"paste"/"illustrate" anywhere in user-facing copy, even
though "paste" is the literal macOS mechanism — the button and empty-state text never
name the mechanism, only the action.

## Date / backdate behavior

Decision 8. On adding the *first* image to a dateless-or-new entry (i.e. `entry.json`
has no `originalDate` yet — the same "unfiled/un-backdated" state a fresh blank entry
starts in):
1. Read EXIF `DateTimeOriginal` (or `DateTimeDigitized` as fallback) from the original
   bytes via ImageIO (`CGImageSourceCopyPropertiesAtIndex`, the same framework
   `JournalCoverStore` already uses for thumbnailing — no new dependency).
2. If present, prefill the backdate picker with that date, precision `.day`, and surface
   it as a *suggestion the owner confirms* — never silently written. Reuses the existing
   backdate sheet (`EntryDetailView.backdateSheet`/`backdateDraft`), pre-populated rather
   than defaulted to today.
3. If absent, prefill with today (the existing default for an unbackdated entry).

This never fires on a *subsequent* image added to an entry that already has a backdate
(sticky-backdate rule, CLAUDE.md: "editable, never clearable by one tap, explicit
overrides only") — adding a second photo must not silently redate an entry the owner
already dated. The EXIF-suggest path is specifically "entry has no date yet," not "this
image has EXIF."

## Thumbnails

Derived, cached, regenerable — never ground truth (decision 1). Generated once at
add-time and stored at `images/thumbnails/<imageID>.jpg` (§ Data model) so the entry list
and detail strip don't decode a multi-megapixel original on every scroll. Default: JPEG,
long edge 512px (list row needs ~40pt @3x ≈ 120px; the detail strip needs more — 512 clears
both with headroom), quality 0.7 — one shared size for both surfaces rather than two
thumbnail sizes, matching `JournalCoverStore`'s single-size precedent (1024px there, for a
larger display target; entry thumbnails are smaller everywhere they appear).

Generation reuses `JournalCoverStore.reencode`'s exact technique
(`CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways`)
— decodes straight to thumbnail size, never materializes the full original as a bitmap.
**Never applied to `.orig`** — the thumbnail path reads the original file but writes only
to `thumbnails/`, and re-running it (a size bump later, a corrupt thumbnail file) is pure
regeneration from the still-intact original, at any time, no data at risk.

Missing/corrupt thumbnail at read time (a torn write, a pre-thumbnail-code image
ingested via sync) degrades to a generic image placeholder AND queues a regenerate — same
degrade-never-skip rule `JournalCoverStore.read` already applies to a damaged cover.

## Safety argument

What can be lost, and when, mirroring `docs/plans/2026-08-24-90-environment-tag-
design.md`'s style:

- **Local write of a new image**: original bytes are written via `AtomicFile.replace`
  (the same primitive every other durable write in this codebase uses) before the sidecar
  is written, and the sidecar before any sync enqueue. A crash between "bytes written" and
  "sidecar written" leaves an orphaned `.orig` with no `.json` — invisible to every reader
  (thumbnail generation, the sync push scan, and the library row all key off the sidecar's
  presence, matching the `entry.json`-drives-visibility convention already in place) and
  cleaned up the next time anything writes into that `images/` directory, or left
  harmlessly inert forever if nothing does. No user-visible loss: the picker's `onPick`
  callback hasn't returned success yet, so the owner sees the add fail and retries.
- **Push**: content-addressed and immutable, same as `AudioAsset`/`Revision` — a
  half-sent asset simply isn't in the ledger yet, and `SyncPlanner.reconcile` re-enqueues
  it on the next launch. No partial-image-on-server case: CKAsset upload is atomic per
  record.
- **Fetch**: land-or-park (above) closes the "fetched but not yet applicable" gap the same
  way revisions/marker streams already do. The one residual risk is identical to every
  other parked-queue type: a park file itself is subject to ordinary disk-write failure,
  which is the same risk `PendingRevision`/`PendingMarkerStream` already carry and have not
  needed further hardening against in production.
- **Trash / delete**: images ride the entry's existing stage-then-purge lifecycle
  (`StagedRemover`/`TrashSweeper`) — trashing an entry is one `rename(2)` of the whole
  capture directory, images included, into `trash-pending/`, recoverable until the
  30-day sweep or an explicit permanent delete. No separate image-trash state: an image
  cannot outlive its entry, and cannot be "trashed" independently of it (decision 10 only
  allows *removal*, a permanent, immediate delete of one image from a live entry — not a
  soft-delete of that image alone). Removing one image from a live entry is NOT staged —
  it is a direct, immediate unlink of that image's trio of files, matching how a segment
  sidecar write is immediate rather than staged; the entry itself is still live and still
  editable, so there is no "recover this one image" affordance to build.
- **Wipe/resync (#90)**: covered above — no image-specific behavior, inherits the
  existing argument wholesale.
- **The one genuinely new hazard**: an image-only entry with `holdsIrreplaceableArtifacts
  == false` under *today's* definition (§ Open risks — this is the load-bearing fix this
  design requires, not an accepted residual risk) would read as "no durable content" to
  `LibraryScanner`/`RecoveryPlanner` and be swept or quarantined-then-deleted despite
  holding a real, un-losable photograph. This is fixed by extension, not accepted — see
  next section.

## Open risks

1. **`DirectorySnapshot.holdsIrreplaceableArtifacts` does not know about images.** Today:
   `finalM4APresent || finalM4APartPresent || transcriptPresent`
   (`Raconte/Capture/DirectorySnapshot.swift`). Must become `|| imagesPresent` (a stat-level
   flag, same shape as `transcriptPresent` — "does `images/` exist and hold ≥1 sidecar,"
   never a full decode) or an image-only entry is invisible to the library scan
   (`LibraryScanner.holdsSomethingToShow` calls this same property) and a candidate for
   `RecoveryPlanner`'s `.deleteCaptureDirectory` action. This is not optional polish — an
   unfixed gap here means the feature can destroy the exact artifact it exists to protect.
   Flagged as Task 1 in the implementation plan; call it out explicitly in review.
2. **EXIF orientation.** Some camera/photo-library sources hand back image bytes whose
   pixel data is stored unrotated with an EXIF `Orientation` tag carrying the correction.
   Thumbnail generation must respect it (`kCGImageSourceCreateThumbnailWithTransform:
   true`, already in `JournalCoverStore.reencode` and reused here) or thumbnails render
   sideways while the original (correctly interpreted by any real viewer) does not — a
   confusing, cosmetic-only mismatch, not a data-loss risk.
3. **Large originals and container size.** No re-encode means a burst of full-resolution
   HEIC/JPEG photos on an entry grows the container faster than a re-encoded scheme would.
   Accepted per decision 1 (ground truth over storage economy); if it becomes a real
   problem, the answer is user-facing (a library size view, #89's About-page work item),
   never silent re-encoding.
4. **Sync eligibility extension (§ Sync mapping, "the real gap") is new logic in a
   file (`FinalizeArtifactPush`) that several other tasks (#90, #94, #91) have already
   touched for subtle race reasons.** Land it as its own reviewed task, not folded
   silently into the record-builder task, and re-run the existing sync suite alongside
   the new image tests.
5. **Multi-select PhotosPicker UX** — adding N images in one pick means N sequential
   sha256+write+thumbnail operations before the sheet dismisses; no batching/progress UI
   designed here. Acceptable at dogfood scale (a handful of photos per entry); revisit if
   the owner routinely adds dozens at once.

## Future work (explicitly out of scope)

Tagging, OCR of photographed text, in-app image editing/cropping/rotation, and a
dedicated "photo journal" browsing mode are all YAGNI for v1 — noted here only so a
later reader doesn't wonder whether they were forgotten.
