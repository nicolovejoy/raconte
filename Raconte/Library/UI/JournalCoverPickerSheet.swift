import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// The set/change/remove-cover affordance (issue #14 part 3). A thin sheet: it hands raw
/// image bytes up to `onPick` and does no downscaling or file I/O itself —
/// `JournalCoverStore` owns that. Camera is iOS-only; `PhotosPicker` (PhotosUI) needs no
/// photo-library permission on either platform, which is the whole reason it's used here
/// instead of the legacy `PHPhotoLibrary` API.
struct JournalCoverPickerSheet: View {
    let journalName: String
    /// The current cover's JPEG bytes, shown large at the top of the sheet — the tiny
    /// header/chip thumbnails aren't enough to confirm which image is actually set
    /// (owner feedback, smoke pass 2026-08-02).
    let currentCover: Data?
    var hasCover: Bool { currentCover != nil }
    /// Returns false when the bytes didn't take (`JournalCoverError.invalidImage`) —
    /// the sheet stays up and shows the alert instead of dismissing over a silent no-op.
    let onPick: (Data) async -> Bool
    let onRemove: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var pickError = false
    /// #121: the one item (a shot or a pick) waiting for the framing step.
    @State private var framingQueue = PendingFramingQueue()
    #if os(iOS)
    @State private var showingCamera = false
    /// Raises `pickError` for a failed shot once the cover is down, whichever of the
    /// cover's dismissal and the add's verdict arrives first (#182). Setting `pickError`
    /// in the same turn as `showingCamera = false` races the cover's own dismissal and
    /// drops the alert; a flag consumed only from `.onChange(of: showingCamera)` fired
    /// before the verdict existed and alerted on the NEXT round-trip instead.
    @State private var cameraError = CameraErrorRelay()
    #endif

    var body: some View {
        NavigationStack {
            List {
                if let currentCover {
                    Section {
                        JournalCoverPreview(data: currentCover)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                            .accessibilityIdentifier("journalCover.preview")
                    } header: {
                        Text("Current cover")
                    }
                }
                #if os(iOS)
                // Guarded: `.camera` on a device without one (any simulator) is an
                // exception at presentation time, not a graceful empty picker.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo…") { showingCamera = true }
                        .accessibilityIdentifier("journalCover.takePhoto")
                }
                #endif
                PhotosPicker("Choose from Library…", selection: $photosPickerItem, matching: .images)
                    .accessibilityIdentifier("journalCover.choosePhoto")
                if hasCover {
                    Button("Remove Cover", role: .destructive) {
                        Task { await onRemove(); dismiss() }
                    }
                    .accessibilityIdentifier("journalCover.remove")
                }
            }
            .navigationTitle("Cover for “\(journalName)”")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn’t Use That Photo", isPresented: $pickError) {
                Button("OK", role: .cancel) {}
            }
        }
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
                // Reset even on success: a re-presented sheet (a later failed pick,
                // Cancel-then-reopen) must not inherit a stale item that no longer
                // fires `onChange` when the same photo is picked again.
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
        .onChange(of: showingCamera) { _, isShowing in
            if isShowing {
                cameraError.cameraPresented()
            } else if cameraError.coverDismissed() {
                pickError = true
            }
        }
        #endif
    }

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
}
