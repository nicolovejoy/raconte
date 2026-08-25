# Image capture on entries — implementation plan

Spec: `docs/plans/2026-08-25-image-capture-design.md`. Read it before starting any task —
this plan assumes its decisions (data model, sync mapping, UI surfaces, thumbnails, safety
argument, open risks) as settled and does not re-derive them.

Implementers run on **Sonnet**. Tasks flagged **[escalate]** below are, in the plan
author's judgment, above Sonnet's reliable weight for a first pass — the controller should
run those on a stronger model or budget extra review passes.

## Global Constraints

- **Swift 6 strict concurrency.** New actors/types must compile clean under the project's
  existing strict-concurrency settings — no `@unchecked Sendable` unless an existing
  pattern in the touched file already uses one for the same reason.
- **`xcodegen generate`** after any `project.yml` edit (new source files under
  `Raconte/` are usually picked up automatically by the existing folder reference, but
  confirm — if a task adds a file and it does not appear in a subsequent build, run
  `xcodegen generate` before debugging further).
- **Test commands** (from `CLAUDE.md` — copy verbatim, do not improvise flags):

  macOS unit tests (ad-hoc signed, nocloud entitlements — REQUIRED for any test that
  touches `AppContainer.root()` indirectly, i.e. anything that is not a pure/fixture-only
  test):
  ```
  xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements test
  ```
  iOS compile check:
  ```
  xcodebuild -project Raconte.xcodeproj -scheme Raconte -destination 'generic/platform=iOS' \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
  ```
  UI tests (simulator only, split by class — the whole suite exceeds the Bash tool's
  10-minute cap):
  ```
  xcodebuild -project Raconte.xcodeproj -scheme RaconteUI \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:RaconteUITests/<ClassName> test
  ```
- **UI tests reach screens via `openPlace(app, "sidebar.…")`** (`RaconteUITests/
  UITestNavigation.swift`) — never a hard-coded navigation tap. Add new UI-test coverage
  through this helper.
- **Nothing capture-critical hangs off a view's lifecycle.** `CaptureView`/`EntryDetailView`
  can be navigated away from at any time; image writes, sha256, and sync enqueue must
  complete (or durably fail) independent of whether the detail screen is still on screen —
  drive them from the model (`LibraryScreenModel`/a new image store actor), never from
  `.onAppear`/`.onDisappear`/`.onChange` on the view.
- **Land-or-park for inbound sync.** Every new inbound path for `Image` records must park
  (never drop) a record that cannot be applied yet, per issue #85 and the existing
  `PendingRevision`/`ParkedRevisions` pattern in `Raconte/Sync/SyncIngest.swift`. A task
  that fetches and discards on any non-happy-path is not done.
- **Test-first for pure cores.** Any task below marked "pure core" writes its tests before
  its implementation (TDD) — sha256/path math, eligibility predicates, EXIF-suggestion
  logic.

---

## Task 1

**Title:** File layout, `SegmentLayout` extension, and the `holdsIrreplaceableArtifacts`
fix.

**Why first:** every other task depends on the path/existence primitives here, and the
`holdsIrreplaceableArtifacts` fix is the one correctness bug that must land before any
image can be written to a real capture directory (design doc, "Open risks" #1) — writing
images without it means the recovery/library-scan machinery can treat a real, un-losable
photo as garbage.

**Files:**
- `Raconte/Capture/SegmentLayout.swift` — add:
  ```swift
  static let imagesDirName = "images"
  static let imageThumbnailsDirName = "thumbnails"

  static func imagesDirectory(captureDirectory: URL) -> URL
  static func imageThumbnailsDirectory(captureDirectory: URL) -> URL
  static func imageOriginalURL(captureDirectory: URL, imageID: String, ext: String) -> URL
  static func imageSidecarURL(captureDirectory: URL, imageID: String) -> URL
  static func imageThumbnailURL(captureDirectory: URL, imageID: String) -> URL
  ```
  (`imageOriginalURL`'s file name is `<imageID>.<ext>`; `imageSidecarURL`'s is
  `<imageID>.json`; `imageThumbnailURL`'s is `<imageID>.jpg` always, regardless of the
  original's format.)
- `Raconte/Capture/DirectorySnapshot.swift` — add `imagesPresent: Bool` to
  `CaptureSnapshot` (stat-level: `images/` exists and contains ≥1 `.json` sidecar; never
  decodes a sidecar, matching `transcriptPresent`'s own "existence + non-empty" contract).
  Extend `holdsIrreplaceableArtifacts` to `finalM4APresent || finalM4APartPresent ||
  transcriptPresent || imagesPresent`. Update the gathering code (wherever
  `DirectorySnapshot.gather` populates `transcriptPresent` today) to also populate
  `imagesPresent` from the same directory walk.

**Tests** (`RaconteTests`, pure — no actor, no disk beyond temp fixtures):
- `SegmentLayoutImageTests`: each new path function produces the expected relative path
  for a fixed `captureDirectory`/`imageID`/`ext`; `imageThumbnailURL` always ends `.jpg`
  regardless of `ext`.
- `DirectorySnapshotImagesPresentTests`:
  - `holdsIrreplaceableArtifacts` is `false` for a capture with no manifest, no audio, no
    transcript, no images (today's baseline — must not regress).
  - `holdsIrreplaceableArtifacts` is `true` for a capture with `images/<id>.json` present
    and NOTHING else (no audio, no transcript) — the adversarial case this task exists
    for; write this fixture with a real `images/` directory containing one sidecar file,
    not a mocked flag, so the test would fail if the gather step were never wired.
  - An `images/` directory that exists but is empty (created, nothing written into it —
    the abandoned-blank-entry case) does NOT flip `imagesPresent`.

**Done when:** both test classes pass under the macOS nocloud test command above, and
`holdsIrreplaceableArtifacts`'s doc comment is updated to mention images alongside audio/
transcript.

---

## Task 2

**Title:** Image store core — sha256, atomic write of originals, sidecar codec, EXIF read.

**Files:**
- New `Raconte/Library/ImageStore.swift` (mirrors `EntryMetadataStore`'s split of pure
  static seams + an actor for the read-modify-write parts, though image writes are
  write-once so the actor's job is narrower — serializing concurrent adds to the same
  capture directory, not a read-modify-write).
  ```swift
  struct ImageSidecar: Codable, Sendable, Equatable {
      var id: String
      var originalExtension: String
      var mime: String
      var bytes: Int
      var sha256: String
      var width: Int?
      var height: Int?
      var capturedAt: Date?   // EXIF DateTimeOriginal/DateTimeDigitized, if present
      var addedAt: Date
  }

  enum ImageStoreError: Error, Equatable {
      case captureMissing
      case invalidImage
  }

  actor ImageStore {
      let capturesRoot: URL
      init(capturesRoot: URL, now: @escaping @Sendable () -> Date = { Date() },
           mintImageID: @escaping @Sendable () -> String = { ULID.make() })

      /// Verifies `data` decodes as an image (ImageIO), writes `.orig` + sidecar +
      /// thumbnail atomically-in-sequence (orig, then sidecar, then thumbnail — matches
      /// the design doc's crash-ordering argument: an orphaned `.orig` with no sidecar
      /// is invisible to every reader), enqueues a thumbnail regen if generation fails
      /// rather than failing the whole add. Returns the minted sidecar.
      func addImage(captureID: String, data: Data, sourceUTType: String?) async throws -> ImageSidecar

      /// Every sidecar for a capture, ULID order (== display order). Empty for a capture
      /// with no images/no `images/` directory — never throws.
      func images(captureID: String) -> [ImageSidecar]

      /// Removes the `.orig`/`.json`/thumbnail trio for one image. Not an error if
      /// already absent (idempotent, matching `JournalCoverStore.delete`'s convention).
      func removeImage(captureID: String, imageID: String) async

      // Ingest path (mirrors `JournalCoverStore.ingest`): writes fetched bytes verbatim,
      // sha256-verified by the CALLER before this is invoked (same division of labor as
      // `EntryAssembler.assemble`'s audio verify-then-write).
      func ingest(captureID: String, imageID: String, sidecar: ImageSidecar, data: Data) throws
  }
  ```
- New `Raconte/Library/ImageThumbnailer.swift`: pure function `static func generate(from
  data: Data, longEdge: CGFloat = 512, quality: CGFloat = 0.7) -> Data?`, lifted from
  `JournalCoverStore.reencode`'s technique (`CGImageSourceCreateThumbnailAtIndex`,
  `kCGImageSourceCreateThumbnailWithTransform: true` for EXIF orientation) but returning
  `nil` on failure instead of throwing — thumbnail generation failure must never fail the
  image add itself (design doc, degrade-never-skip).
- New `Raconte/Library/ImageEXIF.swift`: pure function `static func capturedAt(from data:
  Data) -> Date?` — reads `kCGImagePropertyExifDateTimeOriginal` (fallback
  `DateTimeDigitized`) via `CGImageSourceCopyPropertiesAtIndex`, parses the EXIF date
  string format (`"yyyy:MM:dd HH:mm:ss"`, NOT ISO8601 — EXIF's own format), returns nil on
  any failure.

**Test cases** (pure core — write these first):
- `ImageThumbnailerTests`: valid JPEG/PNG input → non-nil JPEG output, long edge ≤512;
  garbage bytes → nil; a rotated (EXIF orientation ≠ 1) fixture → output pixel dimensions
  reflect the corrected orientation, not the raw stored dimensions.
- `ImageEXIFTests`: fixture with `DateTimeOriginal` → correct parsed `Date`; fixture with
  only `DateTimeDigitized` → that value; fixture with neither → nil; non-image bytes → nil.
- `ImageStoreTests` (actor, temp `capturesRoot`):
  - `addImage` on an existing capture directory writes all three files; sidecar's
    `sha256` matches a fresh hash of the bytes on disk (never the caller's claimed value —
    same "hash what you actually wrote" discipline `SyncTreeScanner` uses).
  - `addImage` on a captureID with no directory throws `.captureMissing` (mirrors
    `EntryMetadataError.captureMissing`'s guard).
  - `addImage` with non-image bytes throws `.invalidImage`, writes nothing (no orphaned
    partial files — assert the directory is unchanged).
  - `images(captureID:)` returns sidecars in ascending id (ULID) order after three adds
    with distinct mint results.
  - `removeImage` deletes exactly that image's trio and leaves siblings untouched (write
    two images, remove one, assert the other's three files still exist and still hash
    correctly).
  - `removeImage` on an already-absent id is a no-op, does not throw.
  - Thumbnail-generation failure (inject an `ImageThumbnailer` stub that returns nil) does
    not fail `addImage` — sidecar + orig still land; a "needs thumbnail regen" state is
    observable (exact shape — a flag on the sidecar or a re-check based on the thumbnail
    file's absence — implementer's call; make it explicit either way, not implicit).

**Done when:** all tests above pass; `ImageStore`/`ImageThumbnailer`/`ImageEXIF` have zero
UIKit/AppKit imports (ImageIO/CoreGraphics only, matching `JournalCoverStore` — must build
and test on macOS with no platform `#if`).

---

## Task 3

**Title:** Model/API on entries — `EntryListItem`, `LibraryScreenModel` image methods,
blank-entry minting.

**Files:**
- `Raconte/Library/LibraryScanner.swift` / wherever `EntryListItem` is defined — add:
  ```swift
  var images: [ImageSidecar]   // populated by the scan, ULID order
  var leadingThumbnail: ImageSidecar? { images.first }
  ```
  Wire into `LibraryScanner.item(for:metadata:...)` — read `images/` via `ImageStore`'s
  static/pure seam (add a synchronous `static func readSidecars(captureDirectory: URL) ->
  [ImageSidecar]` to `ImageStore` for exactly this — the scan is synchronous and
  actor-free by design, matching how it already reads `entry.json` via
  `EntryMetadataStore.read` rather than hopping the actor).
- `Raconte/Library/LibraryScreenModel.swift` — add:
  ```swift
  func addImage(_ captureID: String, data: Data, sourceUTType: String?) async -> Bool
  func removeImage(_ captureID: String, imageID: String) async
  func images(for captureID: String) async -> [ImageSidecar]

  /// Blank-entry creation (design doc "Entry existence with no audio"). Mints a
  /// captureID, writes the minimal already-finalized manifest + (when journalID is
  /// non-nil) an entry.json with that journalID set. Returns the new captureID, or nil
  /// on any write failure (directory creation, manifest write).
  func createBlankEntry(journalID: String?) async -> String?
  ```
  `createBlankEntry` is new, small, file-writing logic — does NOT go through
  `SegmentStore`/`CaptureCoordinator` (those own the live audio state machine and are the
  wrong owner for a manifest that is finalized from the instant it's written). Suggested
  home: a new small type `Raconte/Capture/BlankEntryMinter.swift` with a pure
  `static func manifest(captureID: String, createdAt: Date) -> Manifest` (state `.complete`,
  `final.verifiedAt = createdAt`, `final.durationFrames = 0`) plus the directory-creation/
  write side, called from `LibraryScreenModel.createBlankEntry`.
- After a blank entry is created, `EntryListItem`'s existing snippet/duration derivation
  must not choke on `final.durationFrames = 0` + no `recording.m4a` — verify (do not
  assume) that `LibraryScanner.durationSeconds`'s existing fallback chain already renders
  this as `0`, which is correct, not a crash or a bogus large number.

**Tests:**
- `LibraryScannerImagesTests`: a capture with 2 images and no audio produces an
  `EntryListItem` with `images.count == 2`, `leadingThumbnail` == the earliest by id, and
  (via Task 1's fix) is NOT in `skipped`.
- `BlankEntryMinterTests` (pure): `manifest(captureID:createdAt:)` produces a `Manifest`
  that `FinalizeArtifactPush.isFinalized` reads as `true` for that capture directory once
  written to disk — i.e. an actual round-trip through `CaptureCoding`, not just a struct
  equality check, since `isFinalized` re-decodes from bytes.
- `LibraryScreenModelBlankEntryTests`:
  - `createBlankEntry(journalID: nil)` → the capture directory exists,
    `LibraryScanner.build` after a rescan shows it as unfiled with `images.isEmpty`.
  - `createBlankEntry(journalID: "j1")` → the resulting `entry.json` decodes with
    `journalID == "j1"`.
  - `addImage`/`removeImage`/`images(for:)` round-trip through the model the same way the
    direct `ImageStore` tests do (thin pass-through — assert the model doesn't silently
    swallow an `ImageStore` failure; `addImage` must return `false` on one, matching the
    `Bool`-returning convention `setBackdate`/`moveEntry`/`trashEntry` already use).

**Done when:** all tests pass; `EntryListItem` construction sites elsewhere in the codebase
(grep for `EntryListItem(` — likely only `LibraryScanner.item(for:)` and test fixtures)
are updated for the new `images` parameter, none left defaulting silently to a stale
empty array where a real scan should have populated it.

---

## Task 4

**Title:** Sync record type + upload leg (push).

**[escalate] flag:** the `FinalizeArtifactPush.namesToPush`/`entryCanBePushed` change
(making `.audio` conditional on file existence) touches code that #90/#94/#91 have all
separately modified for subtle race/environment reasons this task's author was not
tracking in detail — recommend a stronger model or an explicit extra review pass focused
solely on "does this change any behavior for an audio-bearing entry," not just "does it
work for image-only entries."

**Files:**
- `Raconte/Sync/SyncRecordFamily.swift` / `SyncRecordName` (wherever that enum lives) —
  add `.image(captureID: String, imageID: String)` case. Record name `i.<captureID>.
  <imageID>` via `SyncCloudIdentifiers` (extend its naming table, same pattern as
  `.revision`/`.audio`/`.liveLog`).
- `SyncRecordFamily.names(captureID:captureDirectory:)` — enumerate every image sidecar
  under `images/` and append `.image(captureID:imageID:)` for each, alongside the existing
  audio/liveLog/revision/markerStream enumeration. This is what makes trash-purge (`Trash
  Sweeper`'s `onDeleted`) retire image ledger entries correctly — same mechanism, no new
  wiring needed at the sweeper.
- `Raconte/Sync/SyncRecordBuilders.swift`:
  ```swift
  enum SyncImageField {
      static let originalExtension = "originalExtension"
      static let width = "width"
      static let height = "height"
      static let capturedAt = "capturedAt"
  }
  static func imageRecord(imageID: String, sidecar: ImageSidecar, fileURL: URL,
                          entryID: CKRecord.ID, zoneID: CKRecordZone.ID) -> CKRecord
  ```
  Mirrors `audioRecord`/`revisionRecord` exactly: `SyncChildAssetField.file` = `CKAsset`
  over the `.orig` file, `.sha256`/`.bytes` from the sidecar, `.entryRef` with
  `.deleteSelf`, plus the three `SyncImageField`s.
- `Raconte/Sync/SyncRecordType`: add `static let image = "Image"`.
- `FinalizeArtifactPush.namesToPush` (`Raconte/Sync/SyncRecordBuilders.swift`): change the
  unconditional `.audio` append to the readability-probe pattern already used for
  `.liveLog`/`.markerStream` (`try? Data(contentsOf: finalRecordingURL, options:
  .mappedIfSafe) != nil`). Append `.image(captureID:imageID:)` for every readable sidecar
  under `images/`, same probe technique, reusing the enumeration logic factored out for
  `SyncRecordFamily.names` above (do not duplicate the directory-listing code — extract a
  shared helper if the two call sites would otherwise diverge).
- `SyncIngest.swift` → `SyncRecordExchange`:
  - Add `.image` case to `recordToPush(for:zoneID:)`'s switch, dispatching to a new
    `imageRecordToPush(captureID:imageID:name:zoneID:)` — same shape as
    `revisionRecordToPush`/`audioRecordToPush`: locate the file, hash fresh, `note(build:)`
    into the ledger, build via `SyncRecordBuilders.imageRecord`.
  - `entryCanBePushed` needs no change (it already gates on "Entry exists or would build
    alongside" — an image is a child exactly like audio/revision).

**Tests:**
- `SyncImageRecordBuilderTests`: `imageRecord` produces a `CKRecord` with every field set
  correctly from a fixture sidecar; `SyncRecordType.image == "Image"` (pins the wire
  string — a typo here is a silent second schema, per the file's own existing doc comment
  on `SyncRecordType`).
- `FinalizeArtifactPushImageTests`:
  - A finalized capture with audio present and 2 images → `namesToPush` returns `.entry,
    .audio, .image(id1), .image(id2)` (order: entry, audio if present, then images in
    ULID order — assert the exact contract so a later change can't silently reorder and
    break a test that never checked).
  - A finalized capture with NO audio (`final/recording.m4a` absent) and 1 image →
    `namesToPush` returns `.entry, .image(id1)` — **no `.audio`**. This is the adversarial
    case the whole task exists for; if this test is missing or weak, the task is not done.
  - A finalized capture with audio present and zero images → unchanged from today
    (`.entry, .audio`, plus liveLog/markerStream as before) — regression guard.
- `SyncRecordExchangeImagePushTests` (actor-level, mirrors existing `revisionRecordToPush`
  test shape): push for an image whose file is missing/unreadable → nil, no ledger entry
  written (mirrors `revisionRecordToPush`'s "file vanished" nil-return case).

**Done when:** all tests pass, and the existing full audio-path test suite (whatever
covers `FinalizeArtifactPush`/`entryRecordToPush`/`audioRecordToPush` today) is re-run and
shows zero behavior change for audio-bearing entries — paste the before/after pass counts
into the PR description, not just "tests pass."

---

## Task 5

**Title:** Sync fetch leg — ingest with land-or-park.

**Files:**
- `Raconte/Sync/SyncIngest.swift`:
  - `RemoteImageFields` (or similar), decoded from a fetched `Image` `CKRecord` — mirrors
    `RemoteEntryFields`'s init pattern: strict on identity (record name → captureID +
    imageID), lenient on everything else that has a sane default.
  - `PendingImage`/`ParkedImages` structs, exact mirror of `PendingRevision`/
    `ParkedRevisions` (id keyed by `imageID`, `knownToHaveExisted` for the trashed-capture
    re-park case, content-addressed so redelivery of the same `imageID` is a no-op, not an
    accumulation).
  - `AppContainer.syncStagingPendingImagesFileName = "pending-images.json"` +
    `syncStagingPendingImagesURL(containerRoot:captureID:)` — new file in
    `Raconte/Library/AppContainer.swift`, doc-commented the same way `pending-
    revisions.json`/`pending-marker-streams.json` are (why a sibling file, what rides the
    commit rename).
  - **`EntryAssembler.assemble`'s `pruneUnexpectedStagingContents` allow-list must add
    `AppContainer.syncStagingPendingImagesFileName`** — this is the exact fix-round bug
    class `pending-revisions.json` and `pending-marker-streams.json` were each separately
    added for; missing it here silently deletes a durably-parked image at the next commit.
    Call this out by name in the PR description so a reviewer checks it specifically.
  - Ingest logic in `SyncRecordExchange` (or wherever `ingestRevision`/
    `ingestParkedRevisions` live): `ingestImage(record:)` — decode, verify sha256 on
    arrival (never trust the claimed digest), then:
    - captureID exists locally and not trashed → write directly via `ImageStore.ingest`.
    - captureID doesn't exist yet → park in `pending-images.json`.
    - captureID exists but trashed → park with `knownToHaveExisted: true`.
  - `rehydrateParkedImages` (mirrors `rehydrateParkedRevisions`/
    `rehydrateParkedMarkerStreams`): on capture commit (`EntryAssembler.assemble`'s
    success path) or on capture restore-from-trash, apply any parked images for that
    captureID and delete the park file.
  - `EntryIngest.plan`: no change needed — images are optional riders like `liveLog`
    (design doc: commit set is manifest + entry + audio-if-any; an entry with images but
    no audio never has an `audio` piece to wait for in the first place — confirm the
    existing `guard incoming.audio != nil else { return .refuse(...) }` in `EntryIngest
    .plan` is NOT reached for an image-only new-entry ingest, i.e. that path needs its own
    "commit set complete" check that does not require audio). **This is a second real gap
    like Task 4's — flag explicitly if `EntryIngest.plan`/`EntryAssembler.assemble`
    hard-require audio bytes to commit a NEW entry at all, since an image-only entry
    arriving via sync (this device never captured it, it exists only on another device)
    would then never assemble.** If confirmed, extend `Incoming`/`plan`/`assemble` so the
    commit set is "manifest + entry, audio optional, complete when nothing image-eligible
    is still missing" — mirror the `liveLog` optional-rider pattern already there, applied
    to `audio` itself for this one case.

**[escalate] flag:** the `EntryIngest.plan`/`EntryAssembler.assemble` change (if the gap
above is confirmed) changes the commit-set contract for ALL new-entry ingest, not just
images — recommend a stronger model and a review pass that specifically re-derives "can an
audio-bearing entry still fail to assemble until its audio arrives" (it must).

**Tests:**
- `RemoteImageFieldsTests`: decode fixture `CKRecord`s, including a damaged/missing
  optional field degrading correctly.
- `ParkedImagesTests`: pure round-trip (encode/decode), redelivery of the same `imageID`
  replaces rather than duplicates.
- `SyncRecordExchangeImageIngestTests`:
  - Image arrives for an already-local, non-trashed capture → lands directly in
    `images/`, readable via `ImageStore.images(captureID:)` immediately.
  - Image arrives for a captureID with no local directory → parked, `captures/` unchanged.
  - Later, that captureID's Entry+manifest+(audio-if-any) arrive and assemble → parked
    image is rehydrated into the committed directory in the SAME commit, not a later pass
    (mirrors the existing revision-rehydration test shape).
  - Image arrives for a locally-trashed capture → parked with `knownToHaveExisted: true`;
    restoring the entry rehydrates it; permanently deleting the entry instead leaves the
    park file to be cleaned up with the rest of `sync/staging/` (or explicitly purged —
    implementer's call, but must not orphan silently forever).
  - **Adversarial, matching this project's "vacuous fixture" lesson:** a test where the
    park file is deliberately NOT in `pruneUnexpectedStagingContents`'s allow list must
    FAIL (prove the allow-list omission is actually caught before trusting the fix) —
    write this as a throwaway probe during development, not necessarily kept in the final
    suite, but confirm it fails red before the allow-list edit and passes green after.

**Done when:** all tests pass, and — if the `EntryIngest`/`EntryAssembler` gap above is
real — a fresh audio-only new-entry-ingest test (no images at all) is added or re-run to
confirm zero behavior change for the ordinary case.

---

## Task 6

**Title:** Entry detail UI — images section, per-platform capture actions.

**Files:**
- `Raconte/Library/UI/EntryDetailView.swift`: new `imagesSection` (thumbnail strip +
  "Capture Image…" button), positioned per the design doc (between playback and
  transcript; first, above transcript, when there's no audio). Wire to
  `LibraryScreenModel.addImage`/`removeImage`/`images(for:)` from Task 3.
- New `Raconte/Library/UI/ImageCapturePickerSheet.swift` — the per-platform picker sheet,
  directly modeled on `JournalCoverPickerSheet.swift` (same file, read it before writing
  this): `PhotosPicker` (iOS/iPadOS, `matching: .images`, no selection limit) + camera
  (`CameraCapture`, reuse the existing helper — do not duplicate
  `UIImagePickerController` wrapping) + macOS `fileImporter`. Multi-select handling: the
  design doc accepts sequential add-per-item with no batch progress UI for v1 — do not
  over-build this.
- New `Raconte/Library/UI/ImageFullScreenViewer.swift` — tap-to-expand, swipe between
  images, a destructive "Remove" action (decision 10, immediate delete of one image from a
  live entry, not staged — see design doc's safety argument for why this is NOT the same
  code path as entry trash).
- Empty state / button copy: "Capture Image…" / "Nothing captured yet" verbatim (design
  doc, decision 6 — no "attach"/"paste"/"illustrate" anywhere in this file).
- Accessibility identifiers, following the existing `library.row.<field>`/`journalCover.
  <action>` convention: `entryDetail.images.strip`, `entryDetail.images.captureButton`,
  `entryDetail.images.thumbnail.<imageID>` (or index-based if id-based proves awkward for
  XCUITest lookup — implementer's call, but pick ONE convention and use it consistently),
  `entryDetail.images.remove`.

**Tests:** UI-level unit coverage is thin in this codebase for view files (see
`EntryDetailView`'s own lack of dedicated unit tests) — rely on Task 7's UI test class for
end-to-end coverage of the picker flow. Do add, if practical, a small headless test for
any pure logic extracted into the view model layer (e.g. "which section shows first" as a
testable function of `hasAudio`/`hasImages`, rather than inline `if` in the view body).

**Done when:** builds clean on both iOS simulator and macOS (nocloud entitlements), and a
manual smoke pass (owner or a `run`-skill launch) confirms: add an image via PhotosPicker,
see it in the strip immediately, tap through to full-screen, remove it, confirm it's gone
from both the strip and the entry list row.

---

## Task 7

**Title:** Entry list thumbnails, blank-entry action + routing, UI test coverage.

**Files:**
- `Raconte/Library/UI/LibraryView.swift` — `LibraryEntryRow`: leading thumbnail when
  `item.leadingThumbnail != nil`; falls back to today's layout (no thumbnail slot at all,
  not a blank placeholder) when there are no images — matches the existing
  conditional-section pattern already used for `snippet`/`journalName ` in that same row.
  Toolbar "+ New entry" action (design doc), wired to `LibraryScreenModel
  .createBlankEntry(journalID:)` from Task 3, then pushes `LibraryDestination.entry
  (captureID)` on success; on failure (nil), surface an alert matching the existing
  `trashFailed`/`moveFailed` pattern already in this file (same swallowed-`try?`-turned-
  alert family, one more instance of it).
- New `RaconteUITests/ImageCaptureUITests.swift` (or extend an existing library UI test
  class if one is the natural home — check for `LibraryUITests`/`EntryDetailUITests`
  first rather than assuming a new file):
  - Blank-entry flow: `openPlace(app, "sidebar.library")` (or the journal-scoped
    equivalent), tap "+ New entry", land on entry detail, confirm empty state text.
  - Image add (simulator PhotosPicker — this codebase's existing UI tests for
    `JournalCoverPickerSheet` are the precedent for how to drive a `PhotosPicker` in
    XCUITest; follow that pattern rather than inventing a new one).
  - Thumbnail appears on the library row after returning from detail.
  - Remove-image flow round-trips (add, remove, row thumbnail disappears).

**Done when:** the new UI test class passes via `-only-testing:RaconteUITests/
<ClassName>` (per Global Constraints — do not attempt the whole `RaconteUI` suite in one
invocation), and a full run of whatever UI test classes existed before this task shows no
regression (split invocations, reconcile counts against the pre-task baseline per the
project's own documented lesson about this exact suite).

---

## Task 8

**Title:** EXIF date suggestion wiring.

**Files:**
- `Raconte/Library/UI/EntryDetailView.swift` / wherever the backdate sheet's presentation
  is triggered from an image add: on `addImage` success, if the entry had no
  `originalDate` before the add (check BEFORE the add — `item.metadata.originalDate ==
  nil`, using the pre-add snapshot, not a post-add re-read that might reflect a
  concurrent edit), and `ImageEXIF.capturedAt(from:)` (Task 2) returned non-nil, prefill
  `backdateDraft`/`backdatePrecisionDraft` with that value and precision `.day`, and
  present the existing backdate sheet (`showingBackdatePicker = true`) rather than
  auto-saving. If EXIF is nil, follow the entry's existing no-backdate default (today —
  do nothing extra).
- This task is UI-glue only — `ImageEXIF` itself is already built and tested in Task 2.
  Keep this task's diff small and focused on the wiring + the "only when no existing
  date" gate.

**Tests:**
- A view-model-level test (extract the gating logic — "should I suggest a backdate" — into
  a small pure function if it isn't already trivially inline-testable) covering: no
  existing date + EXIF present → suggest; existing date + EXIF present → do NOT suggest
  (sticky-backdate rule); no existing date + no EXIF → today's default, unchanged.
- UI test (can fold into Task 7's class): add an image with known EXIF fixture data to a
  dateless entry, confirm the backdate sheet appears pre-populated rather than needing a
  manual date entry.

**Done when:** tests pass and the sticky-backdate rule (CLAUDE.md: never clearable/
overridden by one tap) is explicitly re-verified — adding a SECOND image to an
already-backdated entry must not reopen or alter the backdate sheet.

---

## Task 9

**Title:** macOS drag-and-drop + paste.

**Files:**
- `Raconte/Library/UI/EntryDetailView.swift` and `LibraryView.swift` (row-level drop
  target per design doc) — `.onDrop(of: [.image], isTargeted:, perform:)` wired to the
  same `LibraryScreenModel.addImage` path Task 6 already built the sheet-based flow
  through (no second image-add code path — drag/drop and paste both terminate at the same
  model method the picker sheet uses).
- Paste: `NSPasteboard.general` image read, wired to a `⌘V`/Edit-menu command scoped to
  when the entry detail screen has focus — macOS-only (`#if os(macOS)`), matching the
  existing platform-conditional style already used throughout this codebase (`#if
  os(iOS)` blocks in `JournalCoverPickerSheet` are the precedent for the split).
- iPad drag-and-drop: per design doc, only if `.onDrop` already works there for free once
  Task 6/9's macOS code is in place — verify on iPad simulator, do not write
  iPad-specific code to force it.

**Tests:** manual/UI-test coverage for drag-and-drop is notoriously hard to automate
reliably in XCUITest for this kind of gesture — this codebase's own CLAUDE.md notes
simulator-vs-device gesture gaps elsewhere. Prefer a pure unit test on the
data-extraction step (`NSItemProvider`/pasteboard → `Data` + UTType, then hand off to the
same `addImage` path Task 2/3 already cover end-to-end) over attempting a full simulated
drag gesture. Manual smoke pass (owner, macOS build) is the acceptance gate for the
gesture itself.

**Done when:** the data-extraction unit test passes, `addImage` is confirmed reachable
from both drop and paste via that same tested path, and a manual macOS smoke (owner or
`run`-skill launch) confirms drag-and-drop and paste both add an image visibly.

---

## Suggested sequencing

Tasks 1–2 first (foundation, no UI). Task 3 next (model layer). Tasks 4–5 (sync) can run
in parallel with Task 6 (detail UI) once Task 3 lands, since sync and UI both depend only
on Task 3's model API, not on each other. Task 7 depends on Task 6 (needs the detail
screen to route to) and Task 3 (blank-entry). Task 8 depends on Task 2 (EXIF) + Task 6
(backdate sheet wiring). Task 9 depends on Task 6 (shares `addImage` plumbing) but not on
Tasks 4/5/7/8 — could run any time after Task 6.
