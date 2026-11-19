# Crop: inset start and pinch to resize

Date: 2026-11-18. Status: awaiting owner approval. Small change, one PR.

## Why

Owner, after the build 28 smoke: he photographs a journal page with some margin around it,
so the crop he wants is nearly always a bit inside the photo. Today the rectangle starts at
the full photo and every side has to be dragged in by hand. He wants to start close and
adjust quickly.

## What changes

1. **Inset start for camera shots.** When the crop screen opens on a photo just taken with
   the camera, the rectangle starts 10% in from each edge (it keeps 80% x 80% of the photo),
   in the photo's own orientation. A portrait iPhone photo is 3:4, close to 8.5 x 11, so the
   inset rectangle is already about page-shaped.
2. **Pinch resizes the rectangle.** A pinch anywhere on the crop screen grows or shrinks the
   rectangle and keeps its shape. The photo does not move or magnify. Works on iOS and on
   the Mac trackpad.

Handles and the move drag are unchanged and stay freeform.

## Decided by the owner

- No shape lock, no shape presets (square and the rest are dropped).
- The start is inset, not the full photo. He suggested "20% or something like that".
- Pinch is option A below.
- Free rotation by twisting is not needed. The Rotate button stays as it is.

## My calls (owner has seen the first two, has not ruled on the rest)

- **10% per side, not 20%.** 20% per side keeps 36% of the photo. One constant; tune after
  the first smoke.
- **Camera shots only.** Library picks and the viewer's re-crop of a stored image start at
  the full photo, as today. A library pick is not necessarily a page shot with margins, and
  a stored image has already had its margins removed. `PendingFramingItem.origin` already
  says which is which; the cover picker's camera shots get the inset too.
- **Rotate returns the rectangle to the screen's starting rectangle**: inset for a camera
  shot, full photo otherwise. Today it returns to the full photo.
- **Pinch at an edge.** The rectangle grows around its centre. When a side meets the photo's
  edge the rectangle slides to keep growing, and it stops when its width or its height
  fills the photo. It never shrinks below `ImageFraming.minimumSide` on either side.
- **A pinch takes over from a drag.** A pinch usually starts with both fingers on the
  rectangle, so the first finger often begins a move drag before the second lands. When
  the pinch begins, the rectangle returns to where that drag started and the pinch owns it.
  That drag stays ignored until its finger lifts. (Changed while planning, after the owner
  approved: the first version said "whichever starts first owns the rectangle", which would
  have let the drag swallow most pinches.)

## Known cost

Cropping is permanent: at capture only the cropped image is stored. Today an untouched Use
keeps the original bytes. With the inset start, shoot then Use discards the outer 10% band
of a camera shot. The dimmed band shows what will go. Dragging the rectangle back to the
full photo still stores the original untouched (`isIdentity`). Owner was told this.

## Approaches considered

- **A. Pinch resizes the rectangle (chosen).** One pure function next to `moved` and
  `resized` in `CropRectGesture`, one `MagnifyGesture` on the screen. Shape-preserving
  resize by pinch plus freeform handles gives the "corners locked, sides free" split the
  owner first asked for, without a lock.
- **B. Pinch magnifies the photo, with panning.** Better precision at a page edge. Three to
  five times the work: zoom and pan state, the #201 margins rule under zoom, and a
  one-finger drag that has to mean "move rectangle" in one place and "pan photo" in
  another. Gesture conflicts of that kind show only on a device. Not now; nothing in A
  blocks adding it later.
- **C. Fixed frame, photo moves under it (Photos style).** A rewrite of the screen. Dropped.
- **Shape lock on corners, or shape presets.** Withdrawn by the owner.

## Constraints

- The pinch math is a pure function in unit space, pinned by `CropRectGestureTests`, like
  `moved` and `resized`. The starting rectangle is a pure function too.
- A simulator pinch does not prove a device pinch (memory: simulator gestures fire where
  device gestures don't). The unit tests pin the math; the owner smoke on an iPhone proves
  the gesture.
- The #201 margins are untouched.
- `ImageCaptureUITests` taps Use on an untouched camera item at lines 234 and 269 and reads
  the crop rectangle at 302. Any assertion there that assumes a full-photo start for a
  camera shot has to change with this.

## Not in scope

Photo magnification (B), twist rotation, shape presets, #120 (cover band slice).

## Left to the builder

How the starting rectangle reaches `ImageFramingView` (a parameter from the three call
sites), where the gesture attaches, and the names.
