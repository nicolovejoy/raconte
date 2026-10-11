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
            .frame(width: frame.width, height: frame.height)
            .contentShape(Rectangle()) // hit-testable interior for the move drag
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
