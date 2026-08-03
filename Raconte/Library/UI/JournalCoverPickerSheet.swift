import SwiftUI
import PhotosUI
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
    #if os(iOS)
    @State private var showingCamera = false
    /// Set by the camera's completion closure, applied once `fullScreenCover` has
    /// actually dismissed — setting `pickError` in the same turn as `showingCamera =
    /// false` can race the cover's own dismissal and drop the alert.
    @State private var pendingCameraError = false
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
        .onChange(of: photosPickerItem) { _, newValue in
            guard let newValue else { return }
            Task {
                guard let data = try? await newValue.loadTransferable(type: Data.self) else {
                    pickError = true
                    photosPickerItem = nil
                    return
                }
                if await onPick(data) { dismiss() } else { pickError = true }
                // Reset even on success: a re-presented sheet (a later failed pick,
                // Cancel-then-reopen) must not inherit a stale item that no longer
                // fires `onChange` when the same photo is picked again.
                photosPickerItem = nil
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { data in
                showingCamera = false
                if let data {
                    Task {
                        if await onPick(data) { dismiss() } else { pendingCameraError = true }
                    }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: showingCamera) { _, isShowing in
            guard !isShowing, pendingCameraError else { return }
            pendingCameraError = false
            pickError = true
        }
        #endif
    }
}
