import SwiftUI

/// Tap-through, full-screen view of one entry's images (image capture plan Task 6,
/// design doc "Entry detail" / decision 10). Presented over `EntryDetailView`'s images
/// strip; swipe/step between every image on the entry, with an immediate "Remove"
/// action.
///
/// **`onRemove` is a real, non-staged delete — deliberately not the same code path as
/// entry trash** (design doc's safety argument): an image cannot outlive its entry and
/// cannot be soft-deleted on its own, only removed outright while the entry itself
/// stays live and editable. There is no "recover this one image" affordance to build.
/// This view dismisses itself immediately after a successful remove rather than trying
/// to keep the viewer open on a shrunk, renumbered image list — the caller's strip
/// picks up the change on its own next refresh.
///
/// #121: Crop presents `ImageFramingView` over the original; Use with a real framing asks
/// "Replace the original?" and then `onReplace` adds the framed image at the old slot and
/// removes the original — the viewer dismisses as after Remove.
struct ImageFullScreenViewer: View {
    let model: LibraryScreenModel
    let captureID: String
    let images: [ImageSidecar]
    @State var selectedIndex: Int
    /// Awaited before dismissing — the caller (`EntryDetailView`) does the actual
    /// `LibraryScreenModel.removeImage` write and re-read; this view has no direct
    /// store access of its own, matching the picker sheet's `onPick` convention.
    let onRemove: (ImageSidecar) async -> Void
    /// #121: replace `sidecar`'s bytes with the framed `Data` — the caller runs
    /// `LibraryScreenModel.replaceImage`. false → the viewer alerts and stays up.
    let onReplace: (ImageSidecar, Data) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showingRemoveConfirmation = false
    @State private var removing = false
    /// #121: the original bytes of the image being cropped, while the framing view is up.
    @State private var cropping: CropSession?
    /// #121: set from the framing view's Use; drives the "Replace the original?" dialog.
    @State private var pendingReplacement: Data?
    /// #121: the sidecar the framed bytes belong to — captured when Use fires.
    @State private var replacementTarget: ImageSidecar?
    @State private var showingReplaceConfirmation = false
    @State private var replaceFailed = false
    /// #121: Crop tapped, original bytes still loading — blocks a double-tap and a swipe.
    @State private var loadingCrop = false
    /// #121: the framing view's Use, held until the cover has finished dismissing — a dialog
    /// requested in the same update as the dismissal is dropped on iOS.
    @State private var pendingUse: PendingUse?

    struct PendingUse { let framing: ImageFraming; let session: CropSession }

    struct CropSession: Identifiable { let id = UUID(); let sidecar: ImageSidecar; let original: Data }

    /// What a Use from the framing view does — pure, pinned in `ImageFullScreenViewerCropTests`.
    enum ImageCropOutcome: Equatable { case nothing, confirmReplace(Data) }
    nonisolated static func cropOutcome(framing: ImageFraming, original: Data) -> ImageCropOutcome {
        guard !framing.isIdentity, let framed = framing.apply(to: original) else { return .nothing }
        return .confirmReplace(framed)
    }

    var body: some View {
        NavigationStack {
            Group {
                if images.isEmpty {
                    Color.clear
                } else {
                    #if os(iOS)
                    TabView(selection: $selectedIndex) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, sidecar in
                            ImageFullResolutionView(model: model, captureID: captureID, sidecar: sidecar)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page)
                    .background(Color.black)
                    #else
                    ImageFullResolutionView(model: model, captureID: captureID, sidecar: images[safeIndex])
                    #endif
                }
            }
            .navigationTitle(images.isEmpty ? "" : "Image \(safeIndex + 1) of \(images.count)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .navigation) {
                    Button("Previous") { step(-1) }
                        .disabled(images.count < 2 || safeIndex == 0)
                        .accessibilityIdentifier("entryDetail.images.viewer.previous")
                }
                ToolbarItem(placement: .navigation) {
                    Button("Next") { step(1) }
                        .disabled(images.count < 2 || safeIndex >= images.count - 1)
                        .accessibilityIdentifier("entryDetail.images.viewer.next")
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button("Crop", systemImage: "crop") { beginCrop() }
                        .disabled(images.isEmpty || removing || loadingCrop || cropping != nil)
                        .accessibilityIdentifier("entryDetail.images.crop")
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove", role: .destructive) { showingRemoveConfirmation = true }
                        .disabled(images.isEmpty || removing)
                        .accessibilityIdentifier("entryDetail.images.remove")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(removing)
                }
            }
            .confirmationDialog("Remove this image?", isPresented: $showingRemoveConfirmation,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can’t be undone.")
            }
            .confirmationDialog("Replace the original?", isPresented: $showingReplaceConfirmation,
                                titleVisibility: .visible) {
                Button("Replace", role: .destructive) { replace() }
                Button("Cancel", role: .cancel) { pendingReplacement = nil; replacementTarget = nil }
            } message: {
                Text("The uncropped image is deleted.")
            }
            .alert("Couldn’t Use That Photo", isPresented: $replaceFailed) {
                Button("OK", role: .cancel) {}
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $cropping, onDismiss: finishPendingCrop) { session in framingView(session) }
        #else
        .sheet(item: $cropping, onDismiss: finishPendingCrop) { session in framingView(session) }
        #endif
    }

    private func framingView(_ session: CropSession) -> some View {
        ImageFramingView(data: session.original, onUse: { framing in
            pendingUse = PendingUse(framing: framing, session: session)
            cropping = nil
        }, onCancel: { cropping = nil })
        .id(session.id)
    }

    private var safeIndex: Int { min(max(selectedIndex, 0), max(images.count - 1, 0)) }

    private func step(_ delta: Int) {
        let next = safeIndex + delta
        guard images.indices.contains(next) else { return }
        selectedIndex = next
    }

    private func remove() {
        guard images.indices.contains(safeIndex) else { return }
        let sidecar = images[safeIndex]
        removing = true
        Task {
            await onRemove(sidecar)
            dismiss()
        }
    }

    private func beginCrop() {
        guard images.indices.contains(safeIndex), !loadingCrop else { return }
        let sidecar = images[safeIndex]
        loadingCrop = true
        Task {
            defer { loadingCrop = false }
            guard let original = await model.originalData(captureID: captureID, imageID: sidecar.id) else {
                replaceFailed = true
                return
            }
            cropping = CropSession(sidecar: sidecar, original: original)
        }
    }

    /// Runs once the framing cover has finished dismissing. An item swap can fire onDismiss
    /// on iOS, hence the `cropping == nil` guard.
    private func finishPendingCrop() {
        guard cropping == nil, let use = pendingUse else { return }
        pendingUse = nil
        finishCrop(framing: use.framing, session: use.session)
    }

    /// The `session` is the one that was SHOWN — never `images[safeIndex]` re-read now (the
    /// owner may have swiped meanwhile; CLAUDE.md: capture the id when the intent is armed).
    /// The full-resolution encode runs off the main actor; `removing` is the busy flag.
    private func finishCrop(framing: ImageFraming, session: CropSession) {
        removing = true
        Task {
            let original = session.original
            let outcome = await Task.detached { Self.cropOutcome(framing: framing, original: original) }.value
            removing = false
            switch outcome {
            case .nothing:
                if !framing.isIdentity { replaceFailed = true }
            case .confirmReplace(let framed):
                selectedIndex = images.firstIndex { $0.id == session.sidecar.id } ?? selectedIndex
                pendingReplacement = framed
                replacementTarget = session.sidecar
                showingReplaceConfirmation = true
            }
        }
    }

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
}

/// One image's full-quality bytes, decoded and scaled to fit — the original file, not
/// the 512px thumbnail the strip uses (design doc, "Thumbnails": derived/regenerable,
/// never what the owner is actually looking at full-screen). Reads through
/// `LibraryScreenModel.originalData(captureID:imageID:)` (Task 6 fix round 1) rather
/// than touching disk itself — see `AsyncCaptureImage`'s doc comment.
private struct ImageFullResolutionView: View {
    let model: LibraryScreenModel
    let captureID: String
    let sidecar: ImageSidecar

    var body: some View {
        AsyncCaptureImage(id: sidecar.id, load: {
            await model.originalData(captureID: captureID, imageID: sidecar.id)
        }, loaded: { image in
            image
                .resizable()
                .scaledToFit()
        }, placeholder: {
            ProgressView()
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
