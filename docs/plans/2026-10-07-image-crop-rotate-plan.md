# Image crop + rotate (2026-10-07) Implementation Plan — freeform crop, 90° rotate, at capture and on existing images (#121)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One PR, branched from `fix/196-yank-exif-backdate` (PR #197; the PR targets that
branch and GitHub retargets to `main` when #197 merges): a framing step — freeform
rectangular crop plus rotate in 90° steps — after a camera shot or library pick for an entry
image or a journal cover, and a **Crop** action on an existing entry image that replaces the
original behind a confirmation. iOS and macOS. Plus the inbound single-image-deletion consumer
that makes a cross-device replacement show as one image, not two.

**Architecture:** A pure `ImageFraming` (rotation quarter turns + a unit-space crop rect,
`apply(to:) -> Data?` in ImageIO/CoreGraphics only) and a pure `CropRectGesture` (drag/resize
clamping in unit space) carry every rule a test can pin. `ImageFramingView` is one SwiftUI
screen for both platforms that only ever hands back an `ImageFraming`. The two picker sheets
queue each landed shot/pick through the framing view before calling their existing `onPick`.
`LibraryScreenModel.replaceImage` adds the framed bytes as a NEW image minted at the OLD
image's ULID timestamp (so it keeps its slot) and then removes the old one through the
existing `removeImage` — write-first. `SyncRecordExchange.acceptRemoteImageDeletion` is the
new inbound consumer, routed from the `.image` case of `CloudKitEngineControl`'s deletion
switch.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, ImageIO/CoreGraphics, XCTest. The Xcode
project is generated: `xcodegen generate` after adding ANY source or test file, or the suite
runs green at the OLD count. Local macOS test recipe (CLAUDE.md "Test (macOS)"); the UI suite
is CI-only on this laptop (CoreSimulator out of date, #189). The owner's `/Applications/
Raconte.app` must not be running during a local test run (same bundle id blocks the test host).

**Spec:** `docs/plans/2026-10-07-image-crop-rotate-design.md` — owner-approved 2026-10-07. The
three rulings restated: (1) crops may destroy originals, with a confirmation — at entry point
(c) only; (2) tool shape is freeform rectangle + 90° rotate, no presets, no straightening;
(3) both at capture (a)/(b) and on existing images (c).

## Global Constraints

- Pure image code is ImageIO/CoreGraphics only — no UIKit/AppKit, no platform `#if` — so it
  builds and pins on macOS (the rule `ImageStore`, `CameraJPEG`, `JournalCoverStore.reencode`
  already follow).
- Paper screens take a `TypeRole`, never a bare text style or a size literal. `ImageFramingView`
  is ADDED to `TypeScaleTests.paperScreenFiles` (the scan is an include list) in Task 3.
- Any system control on the pinned-dark framing screen pins `.environment(\.colorScheme, .dark)`.
- `.sheet`/`.fullScreenCover` attach to the presenting screen's OUTER view, never a `Section`.
- Nothing load-bearing hangs off a view's lifecycle; the framing view owns only its own
  `@State framing` and preview.
- Output JPEG quality **0.9** (`CameraJPEG.encode` default). Output orientation tag **1**
  (`.up`), top-level and `{TIFF}`. Minimum crop side **0.1** unit.
- Replacement id: `ULID.make(now: ULID.timestamp(from: oldID) ?? Date())`.
- Confirmation copy at (c): title **"Replace the original?"**, message **"The uncropped image
  is deleted."**, action **"Replace"** (destructive), **"Cancel"**.
- Identifiers added: `imageFraming.rotate`, `imageFraming.use`, `imageFraming.cancel`,
  `imageFraming.cropRect`, `entryDetail.images.crop`. None removed.
- New source or test file → `xcodegen generate` before building.
- Straggler grep for every renamed/deleted symbol over `Raconte RaconteTests RaconteUITests`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Every test gets a RED proof: run it against the pre-change code (stash the production file,
  or write the test first and watch "cannot find … in scope"), then make it pass.

## Review Focus

1. A source JPEG with EXIF orientation 6 (sideways sensor bitmap, displays upright): one
   clockwise turn must be relative to how it DISPLAYS, and the output must carry orientation
   1 with upright pixels — not orientation 6 plus a rotated bitmap, which one reader shows
   right and another shows rotated twice. (Task 1 `testOrientationSixSourceIsUprightedBeforeTheTurn`.)
2. Identity framing at (a)/(b) must store the ORIGINAL bytes and type untouched — a PNG or
   HEIC pick the owner did not crop must not be silently re-encoded to JPEG. (Task 4
   `testIdentityFramingHandsTheOriginalBytesAndTypeToOnPick`.)
3. `replaceImage` when the add fails (bytes do not decode): nothing is removed, the old image
   is still on disk and in the strip, no hook fires. (Task 5 `testReplaceImageWriteFirst…`.)
4. An inbound `.image` deletion for a capture that is already gone (true cascade) is a no-op
   — no crash, no directory recreated, no hook. (Task 7 `testInboundImageDeletionForAMissingCaptureIsANoOp`.)
5. Multi-select of three library photos with the framing step: all three reach `onPick`, in
   order, one framing presentation each; cancelling the framing on the second still stores it
   unframed and still frames the third. (Task 4 `testQueueAdvancesPastACancelledItem`.)

---

### Task 1: `ImageFraming` — pure rotate + crop + metadata-preserving encode

**Files:**
- Create: `Raconte/Library/ImageFraming.swift`
- Test: `RaconteTests/ImageFramingTests.swift`
- Reuse: `Raconte/Library/CameraJPEG.swift` (`CameraJPEG.encode(image:orientation:metadata:quality:)`),
  `RaconteTests/ImageThumbnailerTests.swift` (`makePNG`, `pixelSize(of:)`), `Raconte/Library/ImageEXIF.swift`.

**Interfaces:**
- Produces:
  ```swift
  struct ImageFraming: Equatable, Sendable {
      var rotationQuarterTurns: Int          // normalised 0…3 on read via `normalisedTurns`
      var cropRect: CGRect                   // unit coordinates of the ROTATED image, y down
      static let identity: ImageFraming
      static let minimumSide: CGFloat = 0.1
      var normalisedTurns: Int
      var isIdentity: Bool
      func rotated() -> ImageFraming         // one more clockwise turn, cropRect reset to full
      func apply(to data: Data) -> Data?
      static func clamped(_ rect: CGRect) -> CGRect
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Raconte

/// #121: the pure framing core. Every rule the view and the model lean on is pinned here
/// with synthetic images, so it needs no camera and no simulator.
final class ImageFramingTests: XCTestCase {

    // MARK: Fixtures

    /// A 2×1 image: left pixel red, right pixel blue. Returned as PNG unless `jpegProperties`
    /// is given, in which case a JPEG carrying those properties (EXIF date, orientation…).
    private func redBlue(jpegProperties: [CFString: Any]? = nil) -> Data {
        let image = Self.redBlueImage()
        let output = NSMutableData()
        let type = jpegProperties == nil ? UTType.png : UTType.jpeg
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, jpegProperties as CFDictionary?)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func redBlueImage() -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }

    /// RGB of the pixel at (x, y) with y DOWN (row 0 is the top row), read through a fresh
    /// RGBA8 context so the source's own pixel format does not matter.
    static func rgb(of data: Data, x: Int, y: Int) -> (UInt8, UInt8, UInt8)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return (buffer[i], buffer[i + 1], buffer[i + 2])
    }

    private func isRed(_ p: (UInt8, UInt8, UInt8)?) -> Bool { p.map { $0.0 > 200 && $0.2 < 60 } ?? false }
    private func isBlue(_ p: (UInt8, UInt8, UInt8)?) -> Bool { p.map { $0.2 > 200 && $0.0 < 60 } ?? false }

    private func orientation(of data: Data) -> UInt32? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyOrientation] as? UInt32
    }

    // MARK: Identity

    func testIdentityIsByteIdenticalAndIsIdentity() {
        let data = redBlue()
        XCTAssertTrue(ImageFraming.identity.isIdentity)
        XCTAssertEqual(ImageFraming.identity.apply(to: data), data, "identity must not re-encode")
    }

    func testFourTurnsAndAFullRectIsIdentity() {
        let framing = ImageFraming(rotationQuarterTurns: 4, cropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(framing.normalisedTurns, 0)
        XCTAssertTrue(framing.isIdentity)
    }

    // MARK: Rotate

    func testOneClockwiseTurnSwapsDimensionsAndPutsTheLeftEdgeOnTop() throws {
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: redBlue()))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 1); XCTAssertEqual(size.height, 2)
        XCTAssertTrue(isRed(Self.rgb(of: out, x: 0, y: 0)), "left (red) becomes top after a clockwise turn")
        XCTAssertTrue(isBlue(Self.rgb(of: out, x: 0, y: 1)))
    }

    func testThreeTurnsIsOneCounterClockwiseTurn() throws {
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 3, cropRect: .unit).apply(to: redBlue()))
        XCTAssertTrue(isBlue(Self.rgb(of: out, x: 0, y: 0)), "left (red) becomes BOTTOM after a counter-clockwise turn")
        XCTAssertTrue(isRed(Self.rgb(of: out, x: 0, y: 1)))
    }

    func testRotatedAdvancesOneTurnAndResetsTheRect() {
        let framing = ImageFraming(rotationQuarterTurns: 3, cropRect: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        let next = framing.rotated()
        XCTAssertEqual(next.normalisedTurns, 0)
        XCTAssertEqual(next.cropRect, .unit)
    }

    // MARK: Crop

    func testCropKeepsOnlyTheRequestedUnitRect() throws {
        // Right half of [red|blue] is blue, 1×1.
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 0,
                                             cropRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)).apply(to: redBlue()))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 1); XCTAssertEqual(size.height, 1)
        XCTAssertTrue(isBlue(Self.rgb(of: out, x: 0, y: 0)))
    }

    func testCropIsAppliedAfterTheRotation() throws {
        // One clockwise turn gives [red on top, blue below]; the top half of THAT is red.
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1,
                                             cropRect: CGRect(x: 0, y: 0, width: 1, height: 0.5)).apply(to: redBlue()))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 1); XCTAssertEqual(size.height, 1)
        XCTAssertTrue(isRed(Self.rgb(of: out, x: 0, y: 0)))
    }

    func testClampedPullsAnOutOfBoundsRectInsideAndUpToTheMinimumSide() {
        let wild = ImageFraming.clamped(CGRect(x: -0.5, y: 0.9, width: 3, height: 0.01))
        XCTAssertEqual(wild.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(wild.maxX, 1, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(wild.height, ImageFraming.minimumSide - 1e-9)
        XCTAssertLessThanOrEqual(wild.maxY, 1 + 1e-9)
    }

    func testADegenerateRectIsTreatedAsFull() throws {
        // Zero-area rect on a 2×1 image rounds to no pixels — must fall back to the full image,
        // never return nil (a nil here would drop the owner's photo at the picker).
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .zero).apply(to: redBlue()))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 1); XCTAssertEqual(size.height, 2)
    }

    // MARK: Metadata and orientation

    func testEXIFDateSurvivesTheReencode() throws {
        let input = redBlue(jpegProperties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:03:15 10:30:00"] as [CFString: Any],
        ])
        let expected = try XCTUnwrap(ImageEXIF.capturedAt(from: input), "sanity: the fixture carries a date")
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: input))
        XCTAssertEqual(ImageEXIF.capturedAt(from: out), expected, "#191: a re-encode must keep the photo's own date")
    }

    func testOutputCarriesOrientationOneAndNoStalePixelDimensions() throws {
        let input = redBlue(jpegProperties: [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 2,
                                             kCGImagePropertyExifPixelYDimension: 1] as [CFString: Any],
        ])
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: input))
        XCTAssertEqual(orientation(of: out), CGImagePropertyOrientation.up.rawValue)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(out as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        // ImageIO rewrites these from the real pixels; what must NOT survive is the source's 2×1.
        if let x = exif?[kCGImagePropertyExifPixelXDimension] as? Int { XCTAssertNotEqual(x, 2) }
    }

    /// Review Focus 1. Orientation 6 (`.right`) means "rotate 90° CW to display": the 2×1
    /// [red|blue] bitmap DISPLAYS as 1×2 red-over-blue. One more clockwise turn of the DISPLAYED
    /// image gives 2×1 [blue|red], stored upright (orientation 1).
    func testOrientationSixSourceIsUprightedBeforeTheTurn() throws {
        let input = redBlue(jpegProperties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue])
        let out = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: input))
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: out))
        XCTAssertEqual(size.width, 2); XCTAssertEqual(size.height, 1)
        XCTAssertTrue(isBlue(Self.rgb(of: out, x: 0, y: 0)))
        XCTAssertTrue(isRed(Self.rgb(of: out, x: 1, y: 0)))
        XCTAssertEqual(orientation(of: out), CGImagePropertyOrientation.up.rawValue)
    }

    func testNonImageBytesReturnNil() {
        XCTAssertNil(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: Data("nope".utf8)))
    }
}

extension CGRect {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
}
```

- [ ] **Step 2: Add the test file to the project and run it to verify it fails**

Run: `xcodegen generate` then the macOS test recipe with `-only-testing:RaconteTests/ImageFramingTests`
(CLAUDE.md "Test (macOS)" — the `CODE_SIGN_ENTITLEMENTS=Raconte/Raconte-nocloud.entitlements` form).
Expected: build FAILS with `cannot find 'ImageFraming' in scope`. That is the RED proof for this task.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// #121: a framing — rotate in quarter turns, then crop — expressed independently of pixel
/// size and of how a view scaled its preview. `cropRect` is in UNIT coordinates (0…1) of
/// the ROTATED image, y down (origin top-left, the UI's convention and `CGImage.cropping`'s).
///
/// Pure ImageIO/CoreGraphics — no UIKit/AppKit, no platform `#if` — so it builds and pins on
/// macOS with synthetic images, the same rule `ImageStore`/`CameraJPEG` follow.
struct ImageFraming: Equatable, Sendable {
    var rotationQuarterTurns: Int
    var cropRect: CGRect

    static let identity = ImageFraming(rotationQuarterTurns: 0, cropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    /// Smallest crop side, in unit space — a rect thinner than this is useless and is where
    /// a drag handle crossing its opposite edge would otherwise invert the rect.
    static let minimumSide: CGFloat = 0.1

    /// `rotationQuarterTurns` folded into 0…3 (negative and ≥4 values included).
    var normalisedTurns: Int { ((rotationQuarterTurns % 4) + 4) % 4 }

    var isIdentity: Bool {
        normalisedTurns == 0 && Self.clamped(cropRect) == Self.identity.cropRect
    }

    /// One more clockwise quarter turn. The crop rect resets to the full image: a rect chosen
    /// against the previous orientation has no meaning against the new one.
    func rotated() -> ImageFraming {
        ImageFraming(rotationQuarterTurns: normalisedTurns + 1, cropRect: Self.identity.cropRect)
    }

    /// `rect` pulled inside the unit square and grown to `minimumSide` where it is thinner —
    /// the one clamp the view, the gesture helper and `apply` all share.
    static func clamped(_ rect: CGRect) -> CGRect {
        var r = rect.standardized
        r.size.width = min(max(r.width, minimumSide), 1)
        r.size.height = min(max(r.height, minimumSide), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }

    /// The rotated-then-cropped image as JPEG (quality 0.9), metadata carried through,
    /// orientation written as 1 (`.up`) because the pixels are now upright. Identity returns
    /// `data` byte-for-byte. nil only when `data` does not decode or the encode fails.
    func apply(to data: Data) -> Data? {
        if isIdentity { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        // Transform-applied decode: the bitmap comes out as it DISPLAYS, so the turn below is
        // relative to what the owner saw, not to the raw sensor orientation (Review Focus 1).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let rotated = Self.rotate(upright, quarterTurns: normalisedTurns) else { return nil }

        let cropped = Self.crop(rotated, unitRect: Self.clamped(cropRect)) ?? rotated

        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        // Geometry that described the SOURCE: ImageIO rewrites the top-level pair from the real
        // pixels, and a stale EXIF pixel dimension pair would lie about the output.
        metadata.removeValue(forKey: kCGImagePropertyPixelWidth)
        metadata.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        // `CameraJPEG.encode` writes the orientation top-level AND in `{TIFF}`.
        return CameraJPEG.encode(image: cropped, orientation: .up, metadata: metadata)
    }

    // MARK: Pixel steps

    /// `quarterTurns` clockwise turns (0…3) as a fresh bitmap. CoreGraphics' drawing space is
    /// y-up, where a positive angle is counter-clockwise on screen — hence the negation.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 { return image }
        let w = image.width, h = image.height
        let (outW, outH) = turns % 2 == 0 ? (w, h) : (h, w)
        guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none  // a quarter turn moves whole pixels; never resample
        context.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return context.makeImage()
    }

    /// `unitRect` (already clamped) applied in pixels. nil when the rounded rect has no pixels —
    /// the caller falls back to the uncropped image rather than failing the framing.
    static func crop(_ image: CGImage, unitRect: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pixelRect = CGRect(x: (unitRect.minX * w).rounded(.down),
                               y: (unitRect.minY * h).rounded(.down),
                               width: (unitRect.width * w).rounded(),
                               height: (unitRect.height * h).rounded())
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the macOS recipe with `-only-testing:RaconteTests/ImageFramingTests`.
Expected: `Executed 13 tests, with 0 failures`. If `testOneClockwiseTurn…` fails with red at the
BOTTOM, the rotation sign is wrong — flip the sign in `rotate`, nothing else. If the orientation-6
test fails with 1×2 output, the decode is not transform-applied — check the thumbnail options.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Library/ImageFraming.swift RaconteTests/ImageFramingTests.swift project.yml
git commit -m "feat(#121): ImageFraming — pure rotate/crop/metadata-preserving encode

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
(`project.yml` only if it changed — it should not; the generated `.xcodeproj` is gitignored.)

---

### Task 2: `CropRectGesture` — unit-space move and resize with clamping

**Files:**
- Create: `Raconte/Library/CropRectGesture.swift`
- Test: `RaconteTests/CropRectGestureTests.swift`

**Interfaces:**
- Consumes: `ImageFraming.clamped(_:)`, `ImageFraming.minimumSide` (Task 1).
- Produces:
  ```swift
  enum CropHandle: CaseIterable, Sendable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
  enum CropRectGesture {
      static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect
      static func resized(_ rect: CGRect, handle: CropHandle, by delta: CGSize) -> CGRect
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Raconte

/// #121: the drag math behind `ImageFramingView`'s crop rectangle, in unit space. Pinned
/// here so clamping is a tested rule, not something eyeballed on a simulator.
final class CropRectGestureTests: XCTestCase {

    private let quarter = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    func testMoveSlidesWithoutResizing() {
        let moved = CropRectGesture.moved(quarter, by: CGSize(width: 0.1, height: -0.1))
        XCTAssertEqual(moved.minX, 0.35, accuracy: 1e-9)
        XCTAssertEqual(moved.minY, 0.15, accuracy: 1e-9)
        XCTAssertEqual(moved.size, quarter.size)
    }

    func testMoveStopsAtTheBounds() {
        let moved = CropRectGesture.moved(quarter, by: CGSize(width: 5, height: 5))
        XCTAssertEqual(moved.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(moved.size, quarter.size, "a move never changes the size, even at the edge")
    }

    func testResizingTheRightEdgeMovesOnlyThatEdge() {
        let resized = CropRectGesture.resized(quarter, handle: .right, by: CGSize(width: 0.1, height: 0.3))
        XCTAssertEqual(resized.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(resized.maxX, 0.85, accuracy: 1e-9)
        XCTAssertEqual(resized.minY, 0.25, accuracy: 1e-9)
        XCTAssertEqual(resized.maxY, 0.75, accuracy: 1e-9, "an edge handle ignores the perpendicular delta")
    }

    func testResizingACornerMovesBothOfItsEdges() {
        let resized = CropRectGesture.resized(quarter, handle: .topLeft, by: CGSize(width: -0.1, height: -0.1))
        XCTAssertEqual(resized.minX, 0.15, accuracy: 1e-9)
        XCTAssertEqual(resized.minY, 0.15, accuracy: 1e-9)
        XCTAssertEqual(resized.maxX, 0.75, accuracy: 1e-9)
        XCTAssertEqual(resized.maxY, 0.75, accuracy: 1e-9)
    }

    func testResizeStopsAtTheBounds() {
        let resized = CropRectGesture.resized(quarter, handle: .bottomRight, by: CGSize(width: 2, height: 2))
        XCTAssertEqual(resized.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(resized.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(resized.minX, 0.25, accuracy: 1e-9)
    }

    func testResizeNeverInvertsAndStopsAtTheMinimumSide() {
        // Dragging the left edge far past the right edge.
        let resized = CropRectGesture.resized(quarter, handle: .left, by: CGSize(width: 0.9, height: 0))
        XCTAssertEqual(resized.width, ImageFraming.minimumSide, accuracy: 1e-9)
        XCTAssertEqual(resized.maxX, 0.75, accuracy: 1e-9, "the opposite edge stays put")
        XCTAssertGreaterThan(resized.width, 0)
    }

    func testResizeResultIsAlwaysClamped() {
        for handle in CropHandle.allCases {
            let r = CropRectGesture.resized(quarter, handle: handle, by: CGSize(width: -3, height: 3))
            XCTAssertEqual(r, ImageFraming.clamped(r), "\(handle)")
        }
    }
}
```

- [ ] **Step 2: Add the file to the project and run to verify it fails**

Run: `xcodegen generate`, then the macOS recipe with `-only-testing:RaconteTests/CropRectGestureTests`.
Expected: build FAILS with `cannot find 'CropRectGesture' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import CoreGraphics

/// Which part of the crop rectangle a drag grabbed.
enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

/// #121: `ImageFramingView`'s drag math, in unit space (0…1, y down). Pure so the clamping
/// rules — stay inside the image, never thinner than `ImageFraming.minimumSide`, never
/// inverted — are pinned by `CropRectGestureTests` rather than eyeballed.
enum CropRectGesture {
    /// Slide `rect` by `delta`, size unchanged, stopping at the unit square.
    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        var r = rect
        r.origin.x = min(max(rect.minX + delta.width, 0), 1 - rect.width)
        r.origin.y = min(max(rect.minY + delta.height, 0), 1 - rect.height)
        return r
    }

    /// Move the edge(s) `handle` owns by `delta`; the opposite edge(s) stay put. An edge that
    /// would cross its opposite stops at `minimumSide` from it; everything is clamped to the
    /// unit square.
    static func resized(_ rect: CGRect, handle: CropHandle, by delta: CGSize) -> CGRect {
        let minSide = ImageFraming.minimumSide
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX = min(max(rect.minX + delta.width, 0), maxX - minSide) }
        if handle.movesRight { maxX = max(min(rect.maxX + delta.width, 1), minX + minSide) }
        if handle.movesTop { minY = min(max(rect.minY + delta.height, 0), maxY - minSide) }
        if handle.movesBottom { maxY = max(min(rect.maxY + delta.height, 1), minY + minSide) }
        return ImageFraming.clamped(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the macOS recipe with `-only-testing:RaconteTests/CropRectGestureTests`.
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Library/CropRectGesture.swift RaconteTests/CropRectGestureTests.swift
git commit -m "feat(#121): CropRectGesture — unit-space move/resize clamping

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `ImageFramingView` — the framing screen, both platforms

**Files:**
- Create: `Raconte/Library/UI/ImageFramingView.swift`
- Modify: `RaconteTests/TypeScaleTests.swift` (`paperScreenFiles` — add `"Raconte/Library/UI/ImageFramingView.swift"`)
- Test: `RaconteTests/ImageFramingViewTests.swift` (pure helpers only — SwiftUI views are not unit-tested in this repo)
- Reference for conventions: `Raconte/Library/UI/ImageFullScreenViewer.swift` (toolbar shape),
  `Raconte/App/TypeScale.swift` (`TypeRole`), `Raconte/Library/UI/InkSurface.swift` (`InkTone`).

**Interfaces:**
- Consumes: `ImageFraming` (Task 1), `CropRectGesture`/`CropHandle` (Task 2).
- Produces:
  ```swift
  struct ImageFramingView: View {
      let data: Data                         // the image to frame (preview decoded here, once)
      let onUse: (ImageFraming) -> Void      // called ONCE, then the presenter dismisses
      let onCancel: () -> Void
  }
  /// Pure layout helper the view and its test share.
  enum ImageFramingLayout {
      /// The rect the image occupies inside `container` when scaled to fit, centred.
      static func fittedImageRect(imageSize: CGSize, in container: CGSize) -> CGRect
      /// Unit-space delta for a drag `translation` over an image laid out in `imageRect`.
      static func unitDelta(_ translation: CGSize, in imageRect: CGRect) -> CGSize
  }
  ```

- [ ] **Step 1: Write the failing test for the pure layout helpers**

```swift
import XCTest
@testable import Raconte

/// #121: the two pure layout rules `ImageFramingView` leans on. The view itself is
/// exercised by `ImageCaptureUITests` (Task 8); nothing here instantiates SwiftUI.
final class ImageFramingViewTests: XCTestCase {

    func testFittedRectLetterboxesALandscapeImageInAPortraitContainer() {
        let r = ImageFramingLayout.fittedImageRect(imageSize: CGSize(width: 200, height: 100),
                                                   in: CGSize(width: 100, height: 300))
        XCTAssertEqual(r.width, 100, accuracy: 1e-9)
        XCTAssertEqual(r.height, 50, accuracy: 1e-9)
        XCTAssertEqual(r.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(r.midY, 150, accuracy: 1e-9, "centred vertically")
    }

    func testFittedRectPillarboxesAPortraitImageInALandscapeContainer() {
        let r = ImageFramingLayout.fittedImageRect(imageSize: CGSize(width: 100, height: 200),
                                                   in: CGSize(width: 300, height: 100))
        XCTAssertEqual(r.height, 100, accuracy: 1e-9)
        XCTAssertEqual(r.width, 50, accuracy: 1e-9)
        XCTAssertEqual(r.midX, 150, accuracy: 1e-9)
    }

    func testFittedRectOfAZeroSizeIsEmptyNotNaN() {
        let r = ImageFramingLayout.fittedImageRect(imageSize: .zero, in: CGSize(width: 100, height: 100))
        XCTAssertFalse(r.width.isNaN); XCTAssertFalse(r.height.isNaN)
        XCTAssertEqual(r.width, 0)
    }

    func testUnitDeltaDividesByTheLaidOutImageSize() {
        let d = ImageFramingLayout.unitDelta(CGSize(width: 50, height: -25),
                                             in: CGRect(x: 10, y: 10, width: 200, height: 100))
        XCTAssertEqual(d.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(d.height, -0.25, accuracy: 1e-9)
    }

    func testUnitDeltaOverAnEmptyRectIsZero() {
        let d = ImageFramingLayout.unitDelta(CGSize(width: 50, height: 50), in: .zero)
        XCTAssertEqual(d, .zero)
    }
}
```

- [ ] **Step 2: Add the file and run to verify it fails**

Run: `xcodegen generate`, then the macOS recipe with `-only-testing:RaconteTests/ImageFramingViewTests`.
Expected: build FAILS with `cannot find 'ImageFramingLayout' in scope`.

- [ ] **Step 3: Write the view and the layout helper**

```swift
import SwiftUI
import ImageIO

/// #121: the pure layout rules of `ImageFramingView` — where the fitted image sits inside
/// its container, and how a drag in points becomes a delta in the crop rect's unit space.
enum ImageFramingLayout {
    static func fittedImageRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: CGPoint(x: container.width / 2, y: container.height / 2), size: .zero)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func unitDelta(_ translation: CGSize, in imageRect: CGRect) -> CGSize {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        return CGSize(width: translation.width / imageRect.width, height: translation.height / imageRect.height)
    }
}

/// #121: the framing screen — freeform crop rectangle with corner and edge handles over the
/// fitted image, one Rotate button (a clockwise quarter turn per tap; the rect resets), Cancel
/// and Use. Owns nothing but `framing` and the decoded preview; hands an `ImageFraming` back
/// through `onUse` and never touches the bytes beyond decoding the preview. The presenter
/// (a picker sheet, the full-screen viewer) applies it and dismisses this view.
///
/// Pinned near-black like the capture screen, so every system control pins `.dark`
/// (CLAUDE.md UI rule). Presented from the presenter's OUTER view — `.fullScreenCover` on
/// iOS, `.sheet` on macOS — never from a `Section`.
struct ImageFramingView: View {
    let data: Data
    let onUse: (ImageFraming) -> Void
    let onCancel: () -> Void

    @State private var framing = ImageFraming.identity
    /// The rect at the start of the current drag — deltas are applied to this, not to the
    /// live rect, so a drag is one continuous transform rather than a sum of rounded steps.
    @State private var dragStartRect: CGRect?
    /// The source decoded ONCE (transform-applied, ≤2048 px) and the current turn of it —
    /// never recomputed per render: a drag re-renders every frame.
    @State private var upright: CGImage?
    @State private var rotatedPreview: CGImage?

    private static let handleSize: CGFloat = 28

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let imageRect = ImageFramingLayout.fittedImageRect(imageSize: previewSize, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let rotatedPreview {
                        Image(decorative: rotatedPreview, scale: 1)
                            .resizable()
                            .frame(width: imageRect.width, height: imageRect.height)
                            .offset(x: imageRect.minX, y: imageRect.minY)
                    }
                    cropOverlay(in: imageRect)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .task {
                // Decoding is this view's own concern, not load-bearing for anything else, so
                // `.task` is fine here (the CLAUDE.md lifecycle rule is about capture state).
                upright = Self.decodeUpright(data)
                rotatedPreview = upright.flatMap { ImageFraming.rotate($0, quarterTurns: framing.normalisedTurns) }
            }
            .onChange(of: framing.normalisedTurns) { _, turns in
                rotatedPreview = upright.flatMap { ImageFraming.rotate($0, quarterTurns: turns) }
            }
            .navigationTitle("Crop")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .accessibilityIdentifier("imageFraming.cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Rotate", systemImage: "rotate.right") { framing = framing.rotated() }
                        .accessibilityIdentifier("imageFraming.rotate")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { onUse(framing) }
                        .accessibilityIdentifier("imageFraming.use")
                }
            }
        }
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    // MARK: Preview

    /// Transform-applied decode, so an EXIF-rotated photo is shown as it DISPLAYS — the same
    /// decode `ImageFraming.apply` performs, so what the owner frames is what gets stored.
    private static func decodeUpright(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private var previewSize: CGSize {
        guard let rotatedPreview else { return .zero }
        return CGSize(width: rotatedPreview.width, height: rotatedPreview.height)
    }

    // MARK: Crop overlay

    @ViewBuilder
    private func cropOverlay(in imageRect: CGRect) -> some View {
        let rect = ImageFraming.clamped(framing.cropRect)
        let frame = CGRect(x: imageRect.minX + rect.minX * imageRect.width,
                           y: imageRect.minY + rect.minY * imageRect.height,
                           width: rect.width * imageRect.width,
                           height: rect.height * imageRect.height)
        // Dim everything outside the crop: four plain rectangles (above, below, left, right of
        // the frame, within the image), which needs no mask or blend mode.
        ForEach(Array(Self.dimRects(image: imageRect, frame: frame).enumerated()), id: \.offset) { _, r in
            Color.black.opacity(0.55)
                .frame(width: max(r.width, 0), height: max(r.height, 0))
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
        // The rect itself: border, move gesture, eight handles.
        Rectangle()
            .stroke(.white, lineWidth: 1.5)
            .background(Color.white.opacity(0.001)) // hit-testable interior for the move drag
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .gesture(moveGesture(in: imageRect))
            .accessibilityIdentifier("imageFraming.cropRect")
            .accessibilityLabel("Crop rectangle")
        ForEach(CropHandle.allCases, id: \.self) { handle in
            let center = Self.handleCenter(handle, in: frame)
            Circle()
                .fill(.white)
                .frame(width: 14, height: 14)
                .frame(width: Self.handleSize, height: Self.handleSize) // larger hit target
                .contentShape(Rectangle())
                .position(center)
                .gesture(resizeGesture(handle, in: imageRect))
        }
    }

    /// The four regions of `image` outside `frame`: top band, bottom band, left and right
    /// bands between them. Pure; add a pin to `ImageFramingViewTests` if it ever grows.
    static func dimRects(image: CGRect, frame: CGRect) -> [CGRect] {
        [
            CGRect(x: image.minX, y: image.minY, width: image.width, height: frame.minY - image.minY),
            CGRect(x: image.minX, y: frame.maxY, width: image.width, height: image.maxY - frame.maxY),
            CGRect(x: image.minX, y: frame.minY, width: frame.minX - image.minX, height: frame.height),
            CGRect(x: frame.maxX, y: frame.minY, width: image.maxX - frame.maxX, height: frame.height),
        ]
    }

    private static func handleCenter(_ handle: CropHandle, in frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: frame.minX, y: frame.minY)
        case .top: CGPoint(x: frame.midX, y: frame.minY)
        case .topRight: CGPoint(x: frame.maxX, y: frame.minY)
        case .right: CGPoint(x: frame.maxX, y: frame.midY)
        case .bottomRight: CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY)
        case .bottomLeft: CGPoint(x: frame.minX, y: frame.maxY)
        case .left: CGPoint(x: frame.minX, y: frame.midY)
        }
    }

    private func moveGesture(in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartRect ?? framing.cropRect
                dragStartRect = start
                framing.cropRect = CropRectGesture.moved(
                    start, by: ImageFramingLayout.unitDelta(value.translation, in: imageRect))
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func resizeGesture(_ handle: CropHandle, in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartRect ?? framing.cropRect
                dragStartRect = start
                framing.cropRect = CropRectGesture.resized(
                    start, handle: handle, by: ImageFramingLayout.unitDelta(value.translation, in: imageRect))
            }
            .onEnded { _ in dragStartRect = nil }
    }
}
```

Then in `RaconteTests/TypeScaleTests.swift`, add `"Raconte/Library/UI/ImageFramingView.swift",` to the
`paperScreenFiles` array (alphabetical position among the `Library/UI` entries). The view has no
`.font` at all — toolbar buttons take the system toolbar style, which the scan does not flag — so
it passes the scan; it is listed so a later label added to it is held to `TypeRole`.

- [ ] **Step 4: Build for both platforms and run the tests**

Run: `xcodegen generate`; the macOS recipe with `-only-testing:RaconteTests/ImageFramingViewTests
-only-testing:RaconteTests/TypeScaleTests`; then the iOS compile check from CLAUDE.md
(`-destination 'generic/platform=iOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`).
Expected: tests `Executed 5` + TypeScale green; both builds succeed. A `switch` expression
(`case .topLeft: CGPoint(...)`) needs Swift 5.9+ — this project is Swift 6, fine.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Library/UI/ImageFramingView.swift RaconteTests/ImageFramingViewTests.swift RaconteTests/TypeScaleTests.swift
git commit -m "feat(#121): ImageFramingView — crop rectangle with handles, Rotate, Cancel/Use

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Entry points (a) and (b) — the two picker sheets queue each item through framing

**Files:**
- Create: `Raconte/Library/PendingFramingQueue.swift`
- Modify: `Raconte/Library/UI/ImageCapturePickerSheet.swift`
- Modify: `Raconte/Library/UI/JournalCoverPickerSheet.swift`
- Test: `RaconteTests/PendingFramingQueueTests.swift`

**Interfaces:**
- Consumes: `ImageFraming` (Task 1), `ImageFramingView` (Task 3).
- Produces:
  ```swift
  struct PendingFramingItem: Identifiable, Equatable, Sendable {
      let id: UUID
      let data: Data
      let type: UTType
      /// Which flow this item came from — the sheet's AFTER-onPick bookkeeping differs.
      let origin: Origin
      enum Origin: Equatable, Sendable { case camera, library }
  }
  /// Pure queue: items waiting for the framing step, head first.
  struct PendingFramingQueue: Equatable, Sendable {
      private(set) var items: [PendingFramingItem]
      var head: PendingFramingItem?
      var isEmpty: Bool
      mutating func enqueue(_ item: PendingFramingItem)
      mutating func enqueue(contentsOf items: [PendingFramingItem])
      mutating func popHead() -> PendingFramingItem?
      /// The bytes and type to hand to `onPick` for `item` under `framing`: identity → the
      /// original bytes and type untouched (Review Focus 2); otherwise the framed JPEG, or
      /// the original if `apply` fails (the crop step is best-effort, the photo is not).
      static func resolve(_ item: PendingFramingItem, framing: ImageFraming) -> (Data, UTType)
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UniformTypeIdentifiers
@testable import Raconte

/// #121: the queue behind the two picker sheets' framing step, and the one rule that decides
/// what reaches `onPick`. Pure, so a multi-select of three with a cancel in the middle pins
/// without a `PhotosPicker`.
final class PendingFramingQueueTests: XCTestCase {

    private func item(_ tag: UInt8, type: UTType = .png, origin: PendingFramingItem.Origin = .library) -> PendingFramingItem {
        PendingFramingItem(id: UUID(), data: ImageThumbnailerTests.makePNG(width: 2, height: 1, color: (tag, 0, 0)),
                           type: type, origin: origin)
    }

    func testHeadIsFIFOAndPopAdvances() {
        var queue = PendingFramingQueue()
        let a = item(1), b = item(2), c = item(3)
        queue.enqueue(contentsOf: [a, b, c])
        XCTAssertEqual(queue.head, a)
        XCTAssertEqual(queue.popHead(), a)
        XCTAssertEqual(queue.head, b)
        XCTAssertEqual(queue.popHead(), b)
        XCTAssertEqual(queue.popHead(), c)
        XCTAssertNil(queue.popHead())
        XCTAssertTrue(queue.isEmpty)
    }

    /// Review Focus 5: cancelling the framing on the second item does not lose the third.
    func testQueueAdvancesPastACancelledItem() {
        var queue = PendingFramingQueue()
        let a = item(1), b = item(2), c = item(3)
        queue.enqueue(contentsOf: [a, b, c])
        _ = queue.popHead()                       // a used
        let cancelled = queue.popHead()           // b cancelled — the sheet still calls onPick(b, unframed)
        XCTAssertEqual(cancelled, b)
        XCTAssertEqual(queue.head, c, "the item after a cancelled one is still framed")
    }

    /// Review Focus 2: an uncropped PNG pick stays a PNG, byte for byte.
    func testIdentityFramingHandsTheOriginalBytesAndTypeToOnPick() {
        let png = item(9, type: .png)
        let (data, type) = PendingFramingQueue.resolve(png, framing: .identity)
        XCTAssertEqual(data, png.data)
        XCTAssertEqual(type, .png)
    }

    func testNonIdentityFramingHandsAJPEG() throws {
        let png = item(9, type: .png)
        let (data, type) = PendingFramingQueue.resolve(
            png, framing: ImageFraming(rotationQuarterTurns: 1, cropRect: .unit))
        XCTAssertEqual(type, .jpeg)
        XCTAssertEqual(ImageThumbnailerTests.imageType(of: data), UTType.jpeg.identifier)
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: data))
        XCTAssertEqual(size.width, 1); XCTAssertEqual(size.height, 2)
    }

    /// A framing that cannot be applied (bytes that are not an image) must not drop the item:
    /// the original goes through as it was.
    func testFailedApplyFallsBackToTheOriginal() {
        let junk = PendingFramingItem(id: UUID(), data: Data("not an image".utf8), type: .jpeg, origin: .camera)
        let (data, type) = PendingFramingQueue.resolve(
            junk, framing: ImageFraming(rotationQuarterTurns: 1, cropRect: .unit))
        XCTAssertEqual(data, junk.data)
        XCTAssertEqual(type, .jpeg)
    }
}
```

- [ ] **Step 2: Add the file and run to verify it fails**

Run: `xcodegen generate`, then the macOS recipe with `-only-testing:RaconteTests/PendingFramingQueueTests`.
Expected: build FAILS with `cannot find 'PendingFramingQueue' in scope`.

- [ ] **Step 3: Write the queue**

```swift
import Foundation
import UniformTypeIdentifiers

/// One picked or shot image waiting for the framing step (#121).
struct PendingFramingItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data
    let type: UTType
    let origin: Origin

    /// Which flow this item came from. The sheets' AFTER-`onPick` bookkeeping differs: a
    /// camera shot feeds the #134 tally and stays up; a library batch dismisses when the
    /// last item lands.
    enum Origin: Equatable, Sendable { case camera, library }
}

/// #121: the items a picker sheet still has to run through `ImageFramingView`, head first.
/// Pure so the multi-select sequencing (`PendingFramingQueueTests`) pins without a picker.
struct PendingFramingQueue: Equatable, Sendable {
    private(set) var items: [PendingFramingItem] = []

    var head: PendingFramingItem? { items.first }
    var isEmpty: Bool { items.isEmpty }

    mutating func enqueue(_ item: PendingFramingItem) { items.append(item) }
    mutating func enqueue(contentsOf newItems: [PendingFramingItem]) { items.append(contentsOf: newItems) }

    @discardableResult
    mutating func popHead() -> PendingFramingItem? {
        items.isEmpty ? nil : items.removeFirst()
    }

    /// What reaches `onPick` for `item` under `framing`. Identity hands the original bytes
    /// and declared type through untouched — an uncropped PNG/HEIC pick is never silently
    /// re-encoded. A non-identity framing hands the framed JPEG, or, if `apply` fails, the
    /// original: the crop step is best-effort; the owner's photo is not.
    static func resolve(_ item: PendingFramingItem, framing: ImageFraming) -> (Data, UTType) {
        guard !framing.isIdentity else { return (item.data, item.type) }
        guard let framed = framing.apply(to: item.data) else { return (item.data, item.type) }
        return (framed, .jpeg)
    }
}
```

- [ ] **Step 4: Run the queue tests to verify they pass**

Run: the macOS recipe with `-only-testing:RaconteTests/PendingFramingQueueTests`.
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Wire `ImageCapturePickerSheet`**

Replace the current body's callback sites. The full new file (the `#else` macOS file-importer
branch and the error/alert plumbing stay exactly as they are; only the parts shown change):

```swift
struct ImageCapturePickerSheet: View {
    let onPick: (Data, UTType) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var pickError = false
    @State private var batch = ImageCaptureBatch()
    /// #121: items waiting for the framing step. The head is what `ImageFramingView` shows;
    /// Use/Cancel pops it, resolves it through `onPick`, and the next head (if any) presents.
    @State private var framingQueue = PendingFramingQueue()
    /// Set once the LAST library item of a batch has resolved, so the sheet can dismiss (or
    /// alert) the way it did before the framing step existed.
    @State private var libraryBatchFailed = false
    #if os(iOS)
    @State private var showingCamera = false
    @State private var cameraError = CameraErrorRelay()
    #else
    @State private var showingFileImporter = false
    #endif

    var body: some View {
        NavigationStack {
            List { /* unchanged */ }
            .navigationTitle("Capture Image")
            .toolbar { /* unchanged */ }
            .alert("Couldn’t Use That Photo", isPresented: $pickError) { Button("OK", role: .cancel) {} }
        }
        .framingPresentation(item: $framingQueue.headBinding) { item, framing in
            Task { await resolveHead(item, framing: framing) }
        } onCancel: { item in
            Task { await resolveHead(item, framing: .identity) }
        }
        #if os(iOS)
        .onChange(of: photosPickerItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            let items = newValue
            photosPickerItems = []
            Task { await enqueuePhotosPickerItems(items) }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { data in
                showingCamera = false
                if let data {
                    framingQueue.enqueue(PendingFramingItem(id: UUID(), data: data, type: .jpeg, origin: .camera))
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: showingCamera) { /* unchanged */ }
        #else
        .fileImporter(/* unchanged */) { result in
            switch result {
            case .failure: pickError = true
            case .success(let urls): Task { await enqueueFileImporterURLs(urls) }
            }
        }
        #endif
    }

    /// Pops `item`, hands it to `onPick` under `framing`, then does the bookkeeping its origin
    /// needs: a camera shot feeds the #134 tally (stay up, "Take Another…"); the last library
    /// item of a batch dismisses on an all-clear or alerts once.
    private func resolveHead(_ item: PendingFramingItem, framing: ImageFraming) async {
        framingQueue.popHead()
        let (data, type) = PendingFramingQueue.resolve(item, framing: framing)
        let landed = await onPick(data, type)
        switch item.origin {
        case .camera:
            if landed {
                batch.recordLanded()
            } else if cameraErrorAddFailed() {
                pickError = true
            }
        case .library:
            if !landed { libraryBatchFailed = true }
            if framingQueue.items.allSatisfy({ $0.origin == .camera }) {
                // No library items left in the queue: this batch is over.
                if libraryBatchFailed { pickError = true; libraryBatchFailed = false } else { dismiss() }
            }
        }
    }

    private func cameraErrorAddFailed() -> Bool {
        #if os(iOS)
        return cameraError.addFailed()
        #else
        return true
        #endif
    }

    #if os(iOS)
    private func enqueuePhotosPickerItems(_ items: [PhotosPickerItem]) async {
        var loaded: [PendingFramingItem] = []
        var anyFailed = false
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { anyFailed = true; continue }
            let type = item.supportedContentTypes.first ?? .image
            loaded.append(PendingFramingItem(id: UUID(), data: data, type: type, origin: .library))
        }
        if anyFailed { libraryBatchFailed = true }
        if loaded.isEmpty { if anyFailed { pickError = true; libraryBatchFailed = false }; return }
        framingQueue.enqueue(contentsOf: loaded)
    }
    #else
    private func enqueueFileImporterURLs(_ urls: [URL]) async {
        var loaded: [PendingFramingItem] = []
        var anyFailed = false
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { anyFailed = true; continue }
            loaded.append(PendingFramingItem(id: UUID(), data: data, type: Self.contentType(of: url), origin: .library))
        }
        if anyFailed { libraryBatchFailed = true }
        if loaded.isEmpty { if anyFailed { pickError = true; libraryBatchFailed = false }; return }
        framingQueue.enqueue(contentsOf: loaded)
    }
    // contentType(of:) unchanged
    #endif
}
```

Add to `PendingFramingQueue.swift` (it is state plumbing for the queue, so it lives with it):

```swift
import SwiftUI

extension PendingFramingQueue {
    /// A binding to the head for `.fullScreenCover(item:)`/`.sheet(item:)`: setting it to nil
    /// (the system dismissing the cover) is a no-op — the sheets pop the head themselves in
    /// Use/Cancel so the dismissal never races the resolution.
    var headBinding: PendingFramingItem? {
        get { head }
        set { }
    }
}

extension View {
    /// #121: presents `ImageFramingView` for the queue head — `.fullScreenCover` on iOS,
    /// `.sheet` on macOS — attached to the OUTER view of the presenting sheet (never a
    /// `Section`; CLAUDE.md). `onUse`/`onCancel` receive the item so the presenter resolves
    /// exactly what was shown, never "whatever the head is now" (CLAUDE.md: capture the id
    /// when the intent is armed, never a `.last` later).
    func framingPresentation(item: Binding<PendingFramingItem?>,
                             onUse: @escaping (PendingFramingItem, ImageFraming) -> Void,
                             onCancel: @escaping (PendingFramingItem) -> Void) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { pending in
            ImageFramingView(data: pending.data, onUse: { onUse(pending, $0) }, onCancel: { onCancel(pending) })
        }
        #else
        sheet(item: item) { pending in
            ImageFramingView(data: pending.data, onUse: { onUse(pending, $0) }, onCancel: { onCancel(pending) })
        }
        #endif
    }
}
```

`$framingQueue.headBinding` works because `headBinding` is a settable computed property on the
struct and `framingQueue` is `@State`. The setter is deliberately empty — see its doc comment.

Doc-comment update at the top of `ImageCapturePickerSheet`: add one paragraph —
"#121: every landed shot or picked item runs through `ImageFramingView` first (`framingQueue`,
head-first); Use hands the framed JPEG to `onPick`, Cancel hands the original. A library batch
dismisses when its LAST item resolves, as before; a camera shot still feeds the #134 tally."

- [ ] **Step 6: Wire `JournalCoverPickerSheet`**

Same insertion, single-item. Replace the two `onPick` sites:

```swift
    /// #121: the one item (a shot or a pick) waiting for the framing step.
    @State private var framingQueue = PendingFramingQueue()

    // in body, after the NavigationStack:
        .framingPresentation(item: $framingQueue.headBinding) { item, framing in
            Task { await resolveHead(item, framing: framing) }
        } onCancel: { item in
            Task { await resolveHead(item, framing: .identity) }
        }
        .onChange(of: photosPickerItem) { _, newValue in
            guard let newValue else { return }
            Task {
                guard let data = try? await newValue.loadTransferable(type: Data.self) else {
                    pickError = true
                    photosPickerItem = nil
                    return
                }
                photosPickerItem = nil
                framingQueue.enqueue(PendingFramingItem(id: UUID(), data: data,
                                                        type: newValue.supportedContentTypes.first ?? .image,
                                                        origin: .library))
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { data in
                showingCamera = false
                if let data {
                    framingQueue.enqueue(PendingFramingItem(id: UUID(), data: data, type: .jpeg, origin: .camera))
                }
            }
            .ignoresSafeArea()
        }
        // .onChange(of: showingCamera) unchanged
        #endif

    private func resolveHead(_ item: PendingFramingItem, framing: ImageFraming) async {
        framingQueue.popHead()
        let (data, _) = PendingFramingQueue.resolve(item, framing: framing)
        if await onPick(data) {
            dismiss()
        } else {
            #if os(iOS)
            if item.origin == .library || cameraError.addFailed() { pickError = true }
            #else
            pickError = true
            #endif
        }
    }
```

`JournalCoverPickerSheet` needs `import UniformTypeIdentifiers` for `.image`.

- [ ] **Step 7: Build both platforms, run the sheet-adjacent unit tests**

Run: the macOS recipe with `-only-testing:RaconteTests/ImageCaptureBatchTests
-only-testing:RaconteTests/CameraErrorRelayTests -only-testing:RaconteTests/PendingFramingQueueTests
-only-testing:RaconteTests/TypeScaleTests`; the iOS compile check.
Expected: green, both builds succeed. (The sheets have no unit tests of their own — their
behaviour is pinned by the pure queue here and by Task 8's UI test.)

- [ ] **Step 8: Commit**

```bash
git add Raconte/Library/PendingFramingQueue.swift RaconteTests/PendingFramingQueueTests.swift Raconte/Library/UI/ImageCapturePickerSheet.swift Raconte/Library/UI/JournalCoverPickerSheet.swift
git commit -m "feat(#121): picker sheets run every shot and pick through the framing step

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `ImageStore.addImage(imageID:)` override + `LibraryScreenModel.replaceImage`

**Files:**
- Modify: `Raconte/Library/ImageStore.swift:79-101` (`addImage` gains `imageID: String? = nil`)
- Modify: `Raconte/Library/LibraryScreenModel.swift` (after `removeImage`, ~line 564)
- Test: `RaconteTests/ImageStoreTests.swift` (one new test), `RaconteTests/LibraryScreenModelBlankEntryTests.swift` (four new tests)

**Interfaces:**
- Consumes: `ImageStore.addImage`, `LibraryScreenModel.removeImage`, `DeletionRecordingSyncHooks`
  (`RaconteTests/JournalStoreTests.swift`), `ULID.make(now:)`, `ULID.timestamp(from:)`.
- Produces:
  ```swift
  // ImageStore
  func addImage(captureID: String, data: Data, sourceUTType: String?, imageID: String? = nil) async throws -> ImageSidecar
  // LibraryScreenModel
  static func replacementImageID(for oldImageID: String, now: Date = Date()) -> String
  func replaceImage(_ captureID: String, imageID: String, data: Data) async -> Bool
  ```

- [ ] **Step 1: Write the failing tests**

In `RaconteTests/ImageStoreTests.swift`, after `testAddImageOnMissingCaptureDirectoryThrowsCaptureMissing`:

```swift
    /// #121: `replaceImage` mints the replacement's id itself (at the old image's ULID
    /// timestamp) — the store must file under the id it is handed, not a fresh mint.
    func testAddImageWithAnExplicitIDFilesUnderThatID() async throws {
        let s = store()
        try mkCapture()
        let sidecar = try await s.addImage(captureID: captureID, data: png(), sourceUTType: nil,
                                           imageID: "01EXPLICIT0000000000000001")
        XCTAssertEqual(sidecar.id, "01EXPLICIT0000000000000001")
        let listed = await s.images(captureID: captureID).map(\.id)
        XCTAssertEqual(listed, ["01EXPLICIT0000000000000001"])
    }
```
(Use this file's existing fixture helpers for the store, the capture directory and PNG bytes —
read the top of the file for their exact names and adopt them; the names above are placeholders
for THOSE helpers, not new ones to write.)

In `RaconteTests/LibraryScreenModelBlankEntryTests.swift`, a new `// MARK: replaceImage (#121)` section:

```swift
    private func twoByOneRedPNG() -> Data { ImageThumbnailerTests.makePNG(width: 2, height: 1, color: (255, 0, 0)) }

    func testReplacementIDKeepsTheOldULIDTimestamp() throws {
        let old = ULID.make(now: Date(timeIntervalSince1970: 1_700_000_000.123))
        let replacement = LibraryScreenModel.replacementImageID(for: old)
        XCTAssertNotEqual(replacement, old)
        XCTAssertEqual(ULID.timestamp(from: replacement), ULID.timestamp(from: old))
        XCTAssertTrue(ULID.isWellFormed(replacement))
    }

    func testReplacementIDForAnUnparseableOldIDMintsNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let replacement = LibraryScreenModel.replacementImageID(for: "not-a-ulid", now: now)
        XCTAssertEqual(ULID.timestamp(from: replacement), now)
    }

    /// The strip is ULID-ordered; the replacement must sit where the old image sat.
    func testReplaceImageKeepsTheSlotAndChangesOnlyThatID() async throws {
        let model = model()
        let captureID = try XCTUnwrap(await model.createBlankEntry(journalID: nil))
        for _ in 0..<3 {
            _ = await model.addImage(captureID, data: twoByOneRedPNG(), sourceUTType: nil)
            try await Task.sleep(for: .milliseconds(3)) // distinct ULID millisecond per image
        }
        let before = await model.images(for: captureID).map(\.id)
        XCTAssertEqual(before.count, 3)
        let framed = try XCTUnwrap(ImageFraming(rotationQuarterTurns: 1, cropRect: .unit).apply(to: twoByOneRedPNG()))

        let ok = await model.replaceImage(captureID, imageID: before[1], data: framed)
        XCTAssertTrue(ok)

        let after = await model.images(for: captureID)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[0].id, before[0]); XCTAssertEqual(after[2].id, before[2])
        XCTAssertNotEqual(after[1].id, before[1])
        XCTAssertEqual(ULID.timestamp(from: after[1].id), ULID.timestamp(from: before[1]))
        XCTAssertEqual(after[1].width, 1); XCTAssertEqual(after[1].height, 2, "the stored bytes are the framed ones")
        XCTAssertNil(await model.originalData(captureID: captureID, imageID: before[1]), "the original is gone")
    }

    /// Review Focus 3: write-first. Bytes that do not decode must leave the old image exactly
    /// where it was and fire nothing.
    func testReplaceImageWriteFirstAFailedAddRemovesNothingAndFiresNoHook() async throws {
        let model = model()
        let hooks = DeletionRecordingSyncHooks()
        model.attach(syncHooks: hooks)
        let captureID = try XCTUnwrap(await model.createBlankEntry(journalID: nil))
        _ = await model.addImage(captureID, data: twoByOneRedPNG(), sourceUTType: nil)
        let old = try XCTUnwrap(await model.images(for: captureID).first?.id)
        await hooks.reset()

        let ok = await model.replaceImage(captureID, imageID: old, data: Data("junk".utf8))
        XCTAssertFalse(ok)

        XCTAssertEqual(await model.images(for: captureID).map(\.id), [old])
        XCTAssertTrue(await hooks.changedNames.isEmpty)
        XCTAssertTrue(await hooks.deletedNames.isEmpty)
    }

    func testReplaceImageFiresAddThenDeleteHooks() async throws {
        let model = model()
        let hooks = DeletionRecordingSyncHooks()
        model.attach(syncHooks: hooks)
        let captureID = try XCTUnwrap(await model.createBlankEntry(journalID: nil))
        _ = await model.addImage(captureID, data: twoByOneRedPNG(), sourceUTType: nil)
        let old = try XCTUnwrap(await model.images(for: captureID).first?.id)
        await hooks.reset()

        XCTAssertTrue(await model.replaceImage(captureID, imageID: old, data: twoByOneRedPNG()))

        let new = try XCTUnwrap(await model.images(for: captureID).first?.id)
        XCTAssertEqual(await hooks.changedNames, [.image(captureID: captureID, imageID: new)])
        XCTAssertEqual(await hooks.deletedNames, [.image(captureID: captureID, imageID: old)])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: the macOS recipe with `-only-testing:RaconteTests/ImageStoreTests -only-testing:RaconteTests/LibraryScreenModelBlankEntryTests`.
Expected: build FAILS — `extra argument 'imageID' in call` and `has no member 'replaceImage'`.

- [ ] **Step 3: Implement**

`ImageStore.addImage` — change the signature and the mint line; update the doc comment with one
sentence ("`imageID` lets `LibraryScreenModel.replaceImage` (#121) file a replacement at the old
image's ULID timestamp; default mints."):

```swift
    func addImage(captureID: String, data: Data, sourceUTType: String?, imageID: String? = nil) async throws -> ImageSidecar {
        // … existing guards …
        let imageID = imageID ?? mintImageID()
        // … unchanged …
    }
```

`LibraryScreenModel`, after `removeImage`:

```swift
    /// #121: the id a cropped replacement is filed under — the OLD image's ULID millisecond
    /// with fresh randomness, so once the old image is removed the replacement sorts into its
    /// slot in the ULID-ordered strip. No new sidecar field, no CloudKit schema change. An old
    /// id that does not parse mints at `now` (the image moves to the end; pinned, not expected).
    static func replacementImageID(for oldImageID: String, now: Date = Date()) -> String {
        ULID.make(now: ULID.timestamp(from: oldImageID) ?? now)
    }

    /// Replaces one image's bytes with `data` — a cropped/rotated version — by adding `data`
    /// as a NEW image at `replacementImageID(for:)` and then removing the old one through
    /// `removeImage` (which fires the real delete hooks). **Write-first:** a failed add returns
    /// false and removes nothing, so the owner's photo is never lost to a crop that could not
    /// be stored. Images are write-once in the store and immutable in sync, which is why this
    /// is add-then-remove rather than an overwrite under the same id.
    ///
    /// Hook order is add (`noteLocalChange(new)`) then delete (`noteLocalDelete(old)` +
    /// family), each fired by the method that did the write — same placement as `addImage`
    /// and `removeImage` above. One `rescan()` at the end (inside `removeImage`).
    func replaceImage(_ captureID: String, imageID oldImageID: String, data: Data) async -> Bool {
        let newImageID = Self.replacementImageID(for: oldImageID)
        do {
            _ = try await imageStore.addImage(captureID: captureID, data: data, sourceUTType: UTType.jpeg.identifier,
                                              imageID: newImageID)
        } catch {
            return false
        }
        await syncHooks?.noteLocalChange(.image(captureID: captureID, imageID: newImageID))
        await removeImage(captureID, imageID: oldImageID)
        return true
    }
```
`LibraryScreenModel.swift` needs `import UniformTypeIdentifiers` if it does not already have it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the macOS recipe with `-only-testing:RaconteTests/ImageStoreTests -only-testing:RaconteTests/LibraryScreenModelBlankEntryTests`.
Expected: all green; the executed counts are the file's previous count +1 and +5 respectively.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Library/ImageStore.swift Raconte/Library/LibraryScreenModel.swift RaconteTests/ImageStoreTests.swift RaconteTests/LibraryScreenModelBlankEntryTests.swift
git commit -m "feat(#121): LibraryScreenModel.replaceImage — add at the old ULID slot, then remove; write-first

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Entry point (c) — Crop in the full-screen viewer, with the confirmation

**Files:**
- Modify: `Raconte/Library/UI/ImageFullScreenViewer.swift`
- Modify: `Raconte/Library/UI/EntryDetailView.swift` (`imageViewer`, ~line 797)
- Test: `RaconteTests/ImageFullScreenViewerCropTests.swift` (pure decision helper)

**Interfaces:**
- Consumes: `ImageFramingView` (Task 3), `LibraryScreenModel.replaceImage` (Task 5),
  `LibraryScreenModel.originalData(captureID:imageID:)`.
- Produces:
  ```swift
  // ImageFullScreenViewer gains:
  let onReplace: (ImageSidecar, Data) async -> Bool
  /// Pure: what a Use from the framing view should do.
  enum ImageCropOutcome: Equatable { case nothing, confirmReplace(Data) }
  static func cropOutcome(framing: ImageFraming, original: Data) -> ImageCropOutcome
  ```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Raconte

/// #121 entry point (c): the one decision between the framing view's Use and the "Replace
/// the original?" confirmation, pinned pure. Identity → nothing (no dialog, no write);
/// a real framing → confirm with the framed bytes; a framing that cannot be applied → nothing
/// (the viewer shows the alert; never a confirmation for bytes that do not exist).
final class ImageFullScreenViewerCropTests: XCTestCase {

    private let original = ImageThumbnailerTests.makePNG(width: 2, height: 1, color: (255, 0, 0))

    func testIdentityFramingDoesNothing() {
        XCTAssertEqual(ImageFullScreenViewer.cropOutcome(framing: .identity, original: original), .nothing)
    }

    func testARealFramingAsksToReplaceWithTheFramedBytes() throws {
        let outcome = ImageFullScreenViewer.cropOutcome(
            framing: ImageFraming(rotationQuarterTurns: 1, cropRect: .unit), original: original)
        guard case .confirmReplace(let framed) = outcome else { return XCTFail("expected confirmReplace, got \(outcome)") }
        let size = try XCTUnwrap(ImageThumbnailerTests.pixelSize(of: framed))
        XCTAssertEqual(size.width, 1); XCTAssertEqual(size.height, 2)
    }

    func testAFramingThatCannotBeAppliedDoesNothing() {
        XCTAssertEqual(ImageFullScreenViewer.cropOutcome(
            framing: ImageFraming(rotationQuarterTurns: 1, cropRect: .unit), original: Data("junk".utf8)), .nothing)
    }
}
```

- [ ] **Step 2: Add the file and run to verify it fails**

Run: `xcodegen generate`, then the macOS recipe with `-only-testing:RaconteTests/ImageFullScreenViewerCropTests`.
Expected: build FAILS with `has no member 'cropOutcome'`.

- [ ] **Step 3: Implement the viewer changes**

In `ImageFullScreenViewer`:

```swift
    let onRemove: (ImageSidecar) async -> Void
    /// #121: replace `sidecar`'s bytes with the framed `Data` — the caller runs
    /// `LibraryScreenModel.replaceImage`. false → the viewer alerts and stays up.
    let onReplace: (ImageSidecar, Data) async -> Bool

    @State private var showingRemoveConfirmation = false
    @State private var removing = false
    /// #121: the original bytes of the image being cropped, while the framing view is up.
    @State private var cropping: CropSession?
    /// #121: set from the framing view's Use; drives the "Replace the original?" dialog.
    @State private var pendingReplacement: Data?
    @State private var showingReplaceConfirmation = false
    @State private var replaceFailed = false

    struct CropSession: Identifiable { let id = UUID(); let sidecar: ImageSidecar; let original: Data }

    /// What a Use from the framing view does — pure, pinned in `ImageFullScreenViewerCropTests`.
    enum ImageCropOutcome: Equatable { case nothing, confirmReplace(Data) }
    static func cropOutcome(framing: ImageFraming, original: Data) -> ImageCropOutcome {
        guard !framing.isIdentity, let framed = framing.apply(to: original) else { return .nothing }
        return .confirmReplace(framed)
    }
```

Toolbar: add before the Remove item —

```swift
                ToolbarItem(placement: .primaryAction) {
                    Button("Crop", systemImage: "crop") { beginCrop() }
                        .disabled(images.isEmpty || removing || cropping != nil)
                        .accessibilityIdentifier("entryDetail.images.crop")
                }
```

Modifiers on the `NavigationStack` (outer view), after the existing `.confirmationDialog`:

```swift
            .confirmationDialog("Replace the original?", isPresented: $showingReplaceConfirmation,
                                titleVisibility: .visible) {
                Button("Replace", role: .destructive) { replace() }
                Button("Cancel", role: .cancel) { pendingReplacement = nil }
            } message: {
                Text("The uncropped image is deleted.")
            }
            .alert("Couldn’t Use That Photo", isPresented: $replaceFailed) {
                Button("OK", role: .cancel) {}
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $cropping) { session in
            ImageFramingView(data: session.original, onUse: { framing in
                cropping = nil
                finishCrop(framing: framing, session: session)
            }, onCancel: { cropping = nil })
        }
        #else
        .sheet(item: $cropping) { session in
            ImageFramingView(data: session.original, onUse: { framing in
                cropping = nil
                finishCrop(framing: framing, session: session)
            }, onCancel: { cropping = nil })
        }
        #endif
```

Methods:

```swift
    private func beginCrop() {
        guard images.indices.contains(safeIndex) else { return }
        let sidecar = images[safeIndex]
        Task {
            guard let original = await model.originalData(captureID: captureID, imageID: sidecar.id) else {
                replaceFailed = true
                return
            }
            cropping = CropSession(sidecar: sidecar, original: original)
        }
    }

    /// The `session` is the one that was SHOWN — never `images[safeIndex]` re-read now (the
    /// owner may have swiped meanwhile; CLAUDE.md: capture the id when the intent is armed).
    private func finishCrop(framing: ImageFraming, session: CropSession) {
        switch Self.cropOutcome(framing: framing, original: session.original) {
        case .nothing:
            if !framing.isIdentity { replaceFailed = true }
        case .confirmReplace(let framed):
            pendingReplacement = framed
            replacementTarget = session.sidecar
            showingReplaceConfirmation = true
        }
    }

    @State private var replacementTarget: ImageSidecar?

    private func replace() {
        guard let data = pendingReplacement, let target = replacementTarget else { return }
        pendingReplacement = nil
        replacementTarget = nil
        removing = true
        Task {
            if await onReplace(target, data) {
                dismiss()
            } else {
                removing = false
                replaceFailed = true
            }
        }
    }
```
(Declare `replacementTarget` with the other `@State`s, not mid-file as shown.) Update the type's
doc comment: one paragraph, "#121: Crop presents `ImageFramingView` over the original; Use with a
real framing asks 'Replace the original?' and then `onReplace` adds the framed image at the old
slot and removes the original — the viewer dismisses as after Remove."

In `EntryDetailView.imageViewer`:

```swift
    private var imageViewer: some View {
        ImageFullScreenViewer(model: model, captureID: captureID, images: images,
                              selectedIndex: viewerIndex, onRemove: { sidecar in
            await model.removeImage(captureID, imageID: sidecar.id)
            await refresh()
        }, onReplace: { sidecar, data in
            let ok = await model.replaceImage(captureID, imageID: sidecar.id, data: data)
            if ok { await refresh() }
            return ok
        })
    }
```
Grep `ImageFullScreenViewer(` over all three targets — every call site must pass `onReplace`
(the UI-test harness in `Raconte/Capture/Debug/` may construct one; check).

- [ ] **Step 4: Build both platforms, run the tests**

Run: the macOS recipe with `-only-testing:RaconteTests/ImageFullScreenViewerCropTests
-only-testing:RaconteTests/EntryDetailViewImagesSectionTests -only-testing:RaconteTests/TypeScaleTests`;
the iOS compile check.
Expected: `Executed 3` + the others green; both builds succeed.

- [ ] **Step 5: Commit**

```bash
git add Raconte/Library/UI/ImageFullScreenViewer.swift Raconte/Library/UI/EntryDetailView.swift RaconteTests/ImageFullScreenViewerCropTests.swift
git commit -m "feat(#121): viewer Crop — frame the original, confirm, replace at the old slot

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Inbound single-image deletion — `acceptRemoteImageDeletion`

**Files:**
- Modify: `Raconte/Sync/CloudEngineControl.swift` (protocol `CloudRecordExchange` ~line 333; deletion switch ~line 598-630)
- Modify: `Raconte/Sync/SyncIngest.swift` (`SyncRecordExchange`, after `acceptRemoteEntryDeletion` ~line 3237)
- Modify: `RaconteTests/BatchRecordProviderTests.swift:31` (the protocol fake gains the new method)
- Test: `RaconteTests/SyncImageIngestTests.swift` (three new tests)

**Interfaces:**
- Consumes: `ImageStore.removeImage(captureID:imageID:)`, `SyncRecordName.image(captureID:imageID:)`,
  `SyncCloudIdentifiers.name(of:)`, this file's `exchange()` / `mkCaptureDirectory()` / `landedImages()`
  / `imageRecord(id:bytes:)` fixtures.
- Produces:
  ```swift
  // CloudRecordExchange
  func acceptRemoteImageDeletion(captureID: String, imageID: String) async
  ```

- [ ] **Step 1: Write the failing tests**

In `RaconteTests/SyncImageIngestTests.swift`, a new `// MARK: Inbound single-image deletion (#121)` section:

```swift
    /// #121: before this, an inbound Image deletion was ignored on cascade reasoning, so a
    /// device already showing the image kept it — after a remote crop (add new + delete old)
    /// that is a visible duplicate. The consumer removes the local trio, nothing more.
    func testAnInboundImageDeletionForALiveCaptureRemovesTheLocalImage() async throws {
        try mkCaptureDirectory()
        let ex = exchange()
        await ex.acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))
        await ex.acceptRemote(try imageRecord(id: secondImageID, bytes: pngBytes()))
        XCTAssertEqual(await landedImages().map(\.id).sorted(), [imageID, secondImageID].sorted(), "sanity")

        await ex.acceptRemoteImageDeletion(captureID: captureID, imageID: imageID)

        XCTAssertEqual(await landedImages().map(\.id), [secondImageID])
        let thumbnail = SegmentLayout.imageThumbnailURL(captureDirectory: captureDirectory, imageID: imageID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path), "the derived thumbnail goes too")
    }

    /// An inbound write must never echo back out as a local mutation: no save, no delete
    /// enqueued on the engine. Pinned through `localStoreDidChange` firing (the model
    /// rescans) while the attached `FakeCloudEngine` (`SyncCoordinatorTests.swift`) records
    /// no `enqueueSaves`/`enqueueDeletes` — only the `dropPendingSaves` bookkeeping retire.
    func testAnInboundImageDeletionNotifiesTheStoreButEnqueuesNothing() async throws {
        try mkCaptureDirectory()
        let notified = Notified()
        let ex = exchange(localStoreDidChange: { await notified.mark() })
        let engine = FakeCloudEngine()
        ex.attach(engine: engine)
        await ex.acceptRemote(try imageRecord(id: imageID, bytes: pngBytes()))
        await notified.reset()

        await ex.acceptRemoteImageDeletion(captureID: captureID, imageID: imageID)

        XCTAssertTrue(await notified.wasMarked, "the library must learn the image is gone")
        XCTAssertTrue(await engine.savedNames.isEmpty, "an inbound delete is not a local change to push")
        XCTAssertTrue(await engine.deletedNames.isEmpty, "an inbound delete is not a local delete to push")
        XCTAssertEqual(await engine.droppedNames, [[.image(captureID: captureID, imageID: imageID)]],
                       "a queued save for the vanished image is withdrawn")
    }

    /// Review Focus 4: the true cascade — the entry itself is already gone here.
    func testInboundImageDeletionForAMissingCaptureIsANoOp() async throws {
        let ex = exchange()
        await ex.acceptRemoteImageDeletion(captureID: captureID, imageID: imageID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path),
                       "a deletion must never recreate a capture directory")
    }

    private actor Notified {
        private(set) var wasMarked = false
        func mark() { wasMarked = true }
        func reset() { wasMarked = false }
    }
```

`SyncRecordExchange.attach(engine:)` exists (`SyncIngest.swift:1037`); `FakeCloudEngine` is the
actor at `RaconteTests/SyncCoordinatorTests.swift:697` with `savedNames`, `deletedNames`,
`droppedNames` arrays-of-batches. If `attach(engine:)` turns out to be `async` or actor-isolated,
`await` it.

- [ ] **Step 2: Run to verify it fails**

Run: the macOS recipe with `-only-testing:RaconteTests/SyncImageIngestTests`.
Expected: build FAILS with `has no member 'acceptRemoteImageDeletion'`.

- [ ] **Step 3: Implement**

Protocol, in `CloudEngineControl.swift` after `acceptRemoteEntryDeletion`:

```swift
    /// #121: an inbound deletion for ONE Image record whose Entry is still live — the one
    /// child deletion that is NOT a cascade. Produced by `LibraryScreenModel.removeImage`
    /// (and by `replaceImage`'s remove half) on another device; consumed here by removing
    /// the local `.orig`/sidecar/thumbnail trio and telling the library. Fires no outbound
    /// hook — an inbound write never echoes back out as a local mutation. A capture that is
    /// already gone (the true cascade) is a no-op.
    func acceptRemoteImageDeletion(captureID: String, imageID: String) async
```

Deletion switch, replace the `case .audio, .revision, .liveLog, .markerStream, .image:` arm with two:

```swift
                case .image(let captureID, let imageID):
                    // #121: the one child deletion that is NOT a cascade — a remote removal
                    // of ONE image from a still-live entry. When the Entry itself was
                    // deleted this arrives alongside `.entry`'s cascade and the handler's
                    // "capture gone → no-op" branch covers it in either order.
                    await exchange.acceptRemoteImageDeletion(captureID: captureID, imageID: imageID)
                case .audio, .revision, .liveLog, .markerStream:
                    // (existing comment, minus the `.image` paragraph — delete that paragraph;
                    //  its "no INBOUND consumer" claim is now false)
```

`SyncRecordExchange` in `SyncIngest.swift`, after `acceptRemoteEntryDeletion`:

```swift
    /// #121 — see `CloudRecordExchange.acceptRemoteImageDeletion`. Local write only, through
    /// `ImageStore.removeImage` (idempotent: an unknown id is a no-op), then
    /// `localStoreDidChange` so the library rescans. Never `noteLocalChange`/`noteLocalDelete`.
    /// Retires this device's bookkeeping for the name the same way an entry deletion does, so
    /// a reconciliation scan does not treat the vanished artifact as never-uploaded.
    func acceptRemoteImageDeletion(captureID: String, imageID: String) async {
        guard let containerRoot else {
            log.debug("sync: no container root wired — image deletion ingest skipped")
            return
        }
        let capturesRoot = AppContainer.capturesRoot(containerRoot: containerRoot)
        let directory = SegmentLayout.captureDirectory(capturesRoot: capturesRoot, captureID: captureID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            log.debug("sync: image deletion for \(captureID, privacy: .public) — capture already gone, no-op")
            return
        }
        guard let imageStore else {
            log.notice("sync: no image store wired — image deletion \(imageID, privacy: .public) skipped")
            return
        }
        await imageStore.removeImage(captureID: captureID, imageID: imageID)
        let name = SyncRecordName.image(captureID: captureID, imageID: imageID)
        await engine?.dropPendingSaves([name])
        await forgetServerState(for: name)
        await localStoreDidChange?()
    }
```

`BatchRecordProviderTests.swift:31` fake: add `func acceptRemoteImageDeletion(captureID: String, imageID: String) async {}`.
Grep `acceptRemoteEntryDeletion(captureID: String) async {}` across `RaconteTests` for any other
protocol fake and add the method there too.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the macOS recipe with `-only-testing:RaconteTests/SyncImageIngestTests -only-testing:RaconteTests/SyncDeleteTests
-only-testing:RaconteTests/BatchRecordProviderTests`.
Expected: green; `SyncImageIngestTests` executed count is its previous +3. `SyncDeleteTests` has
a source-scan pin over `acceptRemoteEntryDeletion`'s body — it must still pass (the new method is
a sibling, not an edit to that body).

- [ ] **Step 5: Commit**

```bash
git add Raconte/Sync/CloudEngineControl.swift Raconte/Sync/SyncIngest.swift RaconteTests/SyncImageIngestTests.swift RaconteTests/BatchRecordProviderTests.swift
git commit -m "feat(#121): inbound single-image deletion consumer — a remote remove/crop no longer leaves a duplicate

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: UI tests — framing on a pick, and viewer Crop → Replace

**Files:**
- Modify: `RaconteUITests/ImageCaptureUITests.swift` (two new tests)
- Reference: `RaconteUITests/UITestNavigation.swift` (`openPlace`, `openCapture`), the seed
  `RACONTE_UITEST_SEED_IMAGE_ENTRY` (`Raconte/Capture/Debug/UITestSupport.swift:79-110`).

**Interfaces:**
- Consumes: identifiers `entryDetail.images.crop`, `imageFraming.rotate`, `imageFraming.use`,
  `imageFraming.cancel`, `entryDetail.images.thumbnail.<id>`, `entryDetail.images.strip`.

The simulator cannot complete a `PhotosPicker` pick (documented at the top of this file), so the
(a) path's framing presentation cannot be driven end to end here; it is covered by Task 4's pure
queue tests plus the viewer path below, which drives the SAME `ImageFramingView`. Both tests
use the seeded image entry.

- [ ] **Step 1: Write the failing tests**

```swift
    // MARK: - #121 crop + rotate

    /// Viewer → Crop → Rotate → Use → "Replace the original?" → Replace: the strip still has
    /// exactly one image, under a DIFFERENT id (the replacement at the old slot), and the
    /// viewer dismissed as it does after Remove.
    func testCroppingAnImageReplacesItUnderANewID() {
        let app = launchApp(seedImageEntry: true)
        openCapture(app)
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30))
        openPlace(app, "sidebar.allEntries")
        let entryLink = app.descendants(matching: .any).matching(identifier: "library.entryLink").firstMatch
        XCTAssertTrue(entryLink.waitForExistence(timeout: 20))
        waitUntil(20, "seeded image never produced a row thumbnail") { entryLink.label.contains("Entry photo") }
        press(entryLink)

        let thumbnails = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'entryDetail.images.thumbnail.'"))
        XCTAssertTrue(thumbnails.firstMatch.waitForExistence(timeout: 15))
        let idBefore = thumbnails.firstMatch.identifier
        press(thumbnails.firstMatch)

        let crop = app.buttons["entryDetail.images.crop"].firstMatch
        XCTAssertTrue(crop.waitForExistence(timeout: 15), "the viewer must offer Crop")
        press(crop)

        let rotate = app.buttons["imageFraming.rotate"].firstMatch
        XCTAssertTrue(rotate.waitForExistence(timeout: 15), "the framing screen never appeared")
        press(rotate)
        press(app.buttons["imageFraming.use"].firstMatch)

        // Dialog action vs. nothing else labelled Replace: the toolbar has no Replace button,
        // so the label alone is unambiguous here (unlike Remove's case above).
        let confirm = app.buttons["Replace"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "a real framing must confirm before replacing")
        press(confirm)

        waitUntil(20, "the strip never showed the replacement") {
            thumbnails.count == 1 && thumbnails.firstMatch.identifier != idBefore
        }
        XCTAssertFalse(app.buttons["entryDetail.images.crop"].firstMatch.exists, "the viewer dismisses after Replace")
    }

    /// Use with NO change (no rotate, no drag) must do nothing: no dialog, same id.
    func testUsingAnUnchangedFramingDoesNotAskToReplace() {
        let app = launchApp(seedImageEntry: true)
        openCapture(app)
        XCTAssertTrue(app.buttons["capture.record"].firstMatch.waitForExistence(timeout: 30))
        openPlace(app, "sidebar.allEntries")
        let entryLink = app.descendants(matching: .any).matching(identifier: "library.entryLink").firstMatch
        XCTAssertTrue(entryLink.waitForExistence(timeout: 20))
        waitUntil(20, "seeded image never produced a row thumbnail") { entryLink.label.contains("Entry photo") }
        press(entryLink)
        let thumbnails = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'entryDetail.images.thumbnail.'"))
        XCTAssertTrue(thumbnails.firstMatch.waitForExistence(timeout: 15))
        let idBefore = thumbnails.firstMatch.identifier
        press(thumbnails.firstMatch)
        press(app.buttons["entryDetail.images.crop"].firstMatch)
        XCTAssertTrue(app.buttons["imageFraming.use"].firstMatch.waitForExistence(timeout: 15))
        press(app.buttons["imageFraming.use"].firstMatch)

        XCTAssertFalse(app.buttons["Replace"].firstMatch.waitForExistence(timeout: 3),
                       "an identity framing must not offer to replace anything")
        XCTAssertTrue(app.buttons["entryDetail.images.crop"].firstMatch.waitForExistence(timeout: 10),
                      "the viewer stays up")
        press(app.buttons["Done"].firstMatch)
        XCTAssertEqual(thumbnails.firstMatch.identifier, idBefore)
    }
```

- [ ] **Step 2: RED proof**

This laptop cannot run the UI suite (CoreSimulator out of date, #189). The RED proof is
structural: `git stash` is not available across a branch's worth of production files, so instead
grep the identifiers the tests use — `entryDetail.images.crop`, `imageFraming.rotate`,
`imageFraming.use` — against the branch's BASE (`git grep <id> fix/196-yank-exif-backdate -- Raconte`)
and record in the commit that each returns nothing there: on the base, `crop.waitForExistence`
fails at 15 s with "the viewer must offer Crop". CI judges the GREEN.

- [ ] **Step 3: Commit**

```bash
git add RaconteUITests/ImageCaptureUITests.swift
git commit -m "test(#121): UI — viewer Crop → Rotate → Use → Replace swaps the id; identity Use does nothing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: PR

**Files:**
- Modify: `docs/plans/2026-10-07-image-crop-rotate-plan.md` (tick the boxes as completed)

- [ ] **Step 1: Whole-branch checks**

Run, in order:
1. `xcodegen generate`.
2. The full macOS unit recipe (CLAUDE.md "Test (macOS)"), timeout 600000, FOREGROUND. Read
   `Executed N tests` from the LAST summary line. Expected: main's latest CI unit count (read it
   from the job log of main's most recent code-carrying run — not from a commit message) **minus 4**
   (#197 deleted a 4-test file) **plus 13 + 7 + 5 + 5 + 6 + 3 + 3 = 42**. State the arithmetic in the PR.
3. The iOS compile check.
4. Straggler grep over `Raconte RaconteTests RaconteUITests` for: `no INBOUND consumer`
   (the deleted comment claim), and confirm every `ImageFullScreenViewer(` call passes `onReplace`.
5. `git merge-tree $(git merge-base HEAD main) HEAD main` — report conflicts, if any, against
   a main that may have moved.

- [ ] **Step 2: Open the PR**

Base branch **`fix/196-yank-exif-backdate`** (stacked on #197; GitHub retargets to `main` when
#197 merges — say so in the body). Title: `feat(#121): image crop + rotate — at capture and on
existing images, plus inbound single-image deletion`. Body via `--body-file`, covering: what
shipped per task; the three owner rulings; the "add at the old ULID slot, then remove" mechanism
and why (write-once store, immutable sync, no schema change); the inbound-deletion consumer and
the gap it closes; test counts with arithmetic; what the owner should smoke on the Mac (`build 27`:
pick a file for an entry image → framing screen → Rotate → Use → the stored image is turned;
viewer Crop → Replace → one image, turned) and on the phone (TestFlight 27: camera shot → framing
→ Use; take-another still loops); and "Closes #121". End with
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do NOT merge — merges are Nico's.
