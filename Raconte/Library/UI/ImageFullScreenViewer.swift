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
struct ImageFullScreenViewer: View {
    let model: LibraryScreenModel
    let captureID: String
    let images: [ImageSidecar]
    @State var selectedIndex: Int
    /// Awaited before dismissing — the caller (`EntryDetailView`) does the actual
    /// `LibraryScreenModel.removeImage` write and re-read; this view has no direct
    /// store access of its own, matching the picker sheet's `onPick` convention.
    let onRemove: (ImageSidecar) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingRemoveConfirmation = false
    @State private var removing = false

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
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove", role: .destructive) { showingRemoveConfirmation = true }
                        .disabled(images.isEmpty || removing)
                        .accessibilityIdentifier("entryDetail.images.remove")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Remove this image?", isPresented: $showingRemoveConfirmation,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can’t be undone.")
            }
        }
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
