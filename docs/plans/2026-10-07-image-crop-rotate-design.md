# Image crop + rotate (2026-10-07) — design (#121)

Owner-approved 2026-10-07 after a brainstorm. Rulings restated inline; nothing here is
inferred from a back-reference.

## What

A framing step — freeform rectangular crop plus rotate in 90° steps — for images in
Raconte, on iOS and macOS. Three entry points:

- (a) a new **entry image**, right after a camera shot or a library/file pick, before it
  is stored;
- (b) a new **journal cover**, same moment;
- (c) an **existing entry image**, from the full-screen viewer, behind a confirmation.

Not in scope: aspect presets, arbitrary-angle straightening, cropping an existing cover
from the library band (#120 — re-picking the cover already replaces it), the
image-storage efficiency review carried on #121, and #195's viewfinder question (waits on
the build 26 iPhone smoke of #134).

## Owner rulings

1. **Crops may destroy originals, with a confirmation.** The confirmation belongs to entry
   point (c) only: at (a)/(b) nothing old exists yet, so Cancel means "no crop", never
   "lose the photo".
2. **Tool shape:** freeform rectangle + 90° rotate. No presets, no straightening.
3. **Both at capture and on existing images** (entry point list above).

## Architecture

### `ImageFraming` — pure core (new, `Raconte/Library/ImageFraming.swift`)

```swift
struct ImageFraming: Equatable, Sendable {
    /// Clockwise quarter turns applied BEFORE the crop. 0…3.
    var rotationQuarterTurns: Int
    /// Crop rectangle in UNIT coordinates (0…1) of the ROTATED image.
    var cropRect: CGRect
    static let identity: ImageFraming   // 0 turns, rect (0,0,1,1)
    var isIdentity: Bool
    /// Rotated-then-cropped JPEG, metadata carried through. nil when `data` does not
    /// decode or the encode fails. Identity returns `data` byte-for-byte.
    func apply(to data: Data) -> Data?
}
```

Rules:
- ImageIO/CoreGraphics only — no UIKit/AppKit, no platform `#if` — so it pins on macOS
  without a camera, matching `ImageStore`, `CameraJPEG`, `JournalCoverStore.reencode`.
- Decode honouring the source's EXIF orientation (the transform-applied decode
  `JournalCoverStore.reencode` already uses), so a quarter turn is relative to how the
  photo DISPLAYS, not to the raw sensor bitmap. Output is written with orientation `.up`
  (1), top-level and `{TIFF}` — the pixels are now upright; a stale orientation tag would
  have one reader rotate the result again (`CameraJPEG`'s point).
- Metadata carries through: copy the source's properties (`CGImageSourceCopyPropertiesAtIndex`),
  drop the pixel-geometry keys that no longer describe the output (`PixelWidth`,
  `PixelHeight`, `{Exif}` `PixelXDimension`/`PixelYDimension`, the orientation keys as
  above), and encode via `CameraJPEG.encode(image:orientation:metadata:quality:)` at 0.9 —
  so `ImageEXIF.capturedAt` (hence the backdate suggestion on add) still finds
  `DateTimeOriginal`. (#191's rule: a re-encode that drops the date is a regression.)
- Crop rect is clamped to (0,0,1,1) and to a minimum size before use; a degenerate rect
  (zero area after clamping to pixels) is treated as identity-crop, never as a nil result.
- Output pixel size: rotated width/height swapped for odd turns; crop applied in pixels by
  rounding the unit rect against the rotated size.

### `CropRectGesture` — pure drag math (new, `Raconte/Library/CropRectGesture.swift`)

Unit-space drag handling for the view: `moved(rect, by: delta)` keeps the size and slides
inside (0,0,1,1); `resized(rect, handle:, by: delta)` moves one edge/corner, clamps to the
bounds and to `minimumSide` (0.1 unit), never inverts. Pure, so the clamping is unit-tested
rather than eyeballed.

### `ImageFramingView` — UI (new, `Raconte/Library/UI/ImageFramingView.swift`)

One SwiftUI screen, both platforms. Pinned near-black background (`.environment(\.colorScheme,
.dark)` on any system control, CLAUDE.md rule). Image scaled to fit; a crop rectangle with
four corner handles and four edge handles over it, dimmed outside; a Rotate button (one
clockwise quarter turn per tap; the rect resets to full on rotate); Cancel and Use in the
toolbar. Labels through `TypeRole`. Presented as a `.fullScreenCover` on iOS and a `.sheet`
on macOS, attached to the OUTER view of the presenting screen (never a `Section` — CLAUDE.md
trap). The view holds only `@State framing: ImageFraming` and the preview; `onUse(ImageFraming)`
/ `onCancel()` are the whole interface — the view never touches bytes beyond decoding the
preview.

Identifiers: `imageFraming.rotate`, `imageFraming.use`, `imageFraming.cancel`,
`imageFraming.cropRect`.

### Entry point (a): `ImageCapturePickerSheet`

Today a shot/pick calls `onPick(data, type)` directly. New: a `@State pendingFraming:
PendingFraming?` (`Data` + `UTType`) — a landed shot or picked item goes there, the framing
view presents over the sheet, **Use** → `onPick(framing.apply(to: data) ?? data, .jpeg)` for a
non-identity framing (identity → the original bytes and type untouched), **Cancel** →
`onPick(data, type)`. Multi-select frames each item in sequence (next item lands in
`pendingFraming` after the previous resolves). The #134 tally / Take Another… / Done loop and
the #182 `CameraErrorRelay` are untouched; a framing-apply failure (nil) falls back to the
original bytes — the owner's photo is never dropped by the crop step.

### Entry point (b): `JournalCoverPickerSheet`

Same insertion, one item at a time. `onPick(Data)` unchanged.

### Entry point (c): `ImageFullScreenViewer` + `LibraryScreenModel.replaceImage`

Viewer toolbar gains **Crop** (`entryDetail.images.crop`), enabled when an image is showing.
It presents `ImageFramingView` over the original bytes (`model.originalData`). **Use** with a
non-identity framing → confirmation dialog "Replace the original? The uncropped image is
deleted." → `onReplace(sidecar, framedData)` → the viewer dismisses on success, exactly as
Remove does. Identity → nothing happens (no confirmation, no write).

```swift
/// LibraryScreenModel
/// Adds the framed bytes as a NEW image minted at the OLD image's ULID timestamp, then
/// removes the old one. Write-first: a failed add removes nothing and returns false.
func replaceImage(_ captureID: String, imageID: String, data: Data) async -> Bool
```

- The replacement id is `ULID.make(now: ULID.timestamp(from: imageID)!)` — same millisecond,
  fresh randomness — so it sorts into the old image's slot in the ULID-ordered strip once the
  old one is gone. No new sidecar field, no CloudKit schema change. `ImageStore.addImage`
  gains an optional `imageID:` override for this (default: mint).
- Hooks: `noteLocalChange(.image(new))` after the add, then `removeImage(old)` (which fires
  `noteLocalDelete` + `noteLocalDeleteFamily` as today). One `rescan()` at the end.
- An old id whose ULID does not parse (`timestamp(from:)` nil) → mint normally; the image
  moves to the end. Not expected in practice; pinned so it never traps.

### Sync: inbound single-image deletion (`CloudEngineControl`, `SyncIngest`)

`CloudEngineControl.swift:603` ignores an inbound `.image` deletion on cascade reasoning. A
remote removal of ONE image from a still-live entry has an outbound producer
(`LibraryScreenModel.removeImage`) but no consumer, so a device that already shows the
image keeps it — with (c) that is a visible duplicate on the Mac after an iPhone crop. In
scope: `exchange.acceptRemoteImageDeletion(captureID:imageID:)`:
- if the capture directory exists locally → `ImageStore.removeImage` (local write only — fires
  NO `noteLocalChange`/`noteLocalDelete`: an inbound write must never echo out as a local
  mutation, the rule every ingest path states) and the model rescans;
- if the capture is gone (true cascade, entry already purged) → no-op, as today.
The `.image` case leaves the ignored group in the deletion switch. This also closes the
pre-existing Remove gap the comment documents.

## Error handling

- Framing apply returns nil → the existing "Couldn’t Use That Photo" alert is NOT raised at
  (a)/(b); the original bytes are stored unframed (the crop step is best-effort, the photo
  is not). At (c) a nil apply shows the alert and writes nothing.
- `replaceImage`: add fails → false, old image untouched, viewer shows the alert and stays
  up. Remove-after-add failure → the old image lingers (idempotent remove, same as today);
  no data is lost in either order.
- Inbound image deletion for an unknown image id → no-op (idempotent remove).

## Testing

Unit (`RaconteTests`):
- `ImageFramingTests`: identity is byte-identical; one quarter turn swaps pixel dimensions;
  a quadrant crop of a four-colour synthetic image returns that quadrant's colour; an EXIF
  `DateTimeOriginal` on the source survives (`ImageEXIF.capturedAt` on the output equals the
  input's); an orientation-6 source (sideways sensor bitmap) comes out upright with
  orientation 1 and the display-relative turn applied; a degenerate crop rect is identity.
- `CropRectGestureTests`: move clamps to bounds; resize clamps to bounds and minimum side;
  a resize that would cross the opposite edge stops at the minimum, never inverts.
- `LibraryScreenModelTests` (existing file, new tests): `replaceImage` yields a strip whose
  ids are unchanged except at the replaced position; the new id's ULID timestamp equals the
  old's; add failure (invalid bytes) returns false and leaves the old image; the sync hook
  recorder sees `noteLocalChange(.image(new))` then `noteLocalDelete(.image(old))`.
- Sync (existing engine/ingest test files): an inbound `.image` deletion for a live capture
  removes the file trio and fires no outbound hook; for a missing capture it is a no-op.
- `TypeScaleTests` paper-screen scan: `ImageFramingView` is a capture-surface-style pinned
  screen, so it is added to the scan's EXEMPT list with a one-line reason (like `CaptureLabel`),
  not quietly left out.

UI (`RaconteUITests`, simulator / CI):
- `ImageCaptureUITests`: library pick (the existing precedent) → `imageFraming.use` is
  present → tap → the image lands in the strip. Camera is untestable in the simulator.
- Viewer: open an image → `entryDetail.images.crop` → `imageFraming.rotate` → `imageFraming.use`
  → confirmation → Replace → strip count unchanged, the thumbnail identifier changed.

Every test spec gets a RED proof (stash the production change, watch it fail for the right
reason) before it is reported green.

## Not touched

`ImageStore`'s crash ordering, sidecar shape, thumbnail policy; `CameraCapture`; the #134
batch tally; `JournalCoverStore.reencode` (the cover's own downscale still runs after the
crop, on the framed bytes).
