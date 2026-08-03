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
    let hasCover: Bool
    /// Returns false when the bytes didn't take (`JournalCoverError.invalidImage`) —
    /// the sheet stays up and shows the alert instead of dismissing over a silent no-op.
    let onPick: (Data) async -> Bool
    let onRemove: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var pickError = false
    #if os(iOS)
    @State private var showingCamera = false
    #endif

    var body: some View {
        NavigationStack {
            List {
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
                    return
                }
                if await onPick(data) { dismiss() } else { pickError = true }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { data in
                showingCamera = false
                if let data {
                    Task { if await onPick(data) { dismiss() } else { pickError = true } }
                }
            }
            .ignoresSafeArea()
        }
        #endif
    }
}
