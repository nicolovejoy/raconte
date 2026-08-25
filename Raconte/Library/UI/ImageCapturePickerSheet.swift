import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// The "Capture Image…" affordance on the entry detail screen (image capture plan
/// Task 6). Directly modeled on `JournalCoverPickerSheet` — same sheet shape, same
/// `PhotosPicker` + `CameraCapture` machinery — but unlike that single-cover sheet this
/// one only ever ADDS: an entry's images are managed individually afterward (tap a
/// thumbnail in the strip, remove from the full-screen viewer), so there is no "current
/// image"/"remove" affordance in here to mirror the cover sheet's.
///
/// `onPick` carries a `UTType` alongside the bytes (design doc, "Per-platform capture
/// sources") — one extra parameter versus `JournalCoverPickerSheet.onPick: (Data) async
/// -> Bool` — so `ImageStore.addImage`'s `sourceUTType` gets the real declared type
/// instead of relying on `ImageIO` to sniff it from the bytes alone.
///
/// Multi-select (`PhotosPicker`, macOS multi-file `fileImporter`) adds sequentially,
/// one `onPick` call per item, with no batch-progress UI (design doc, decision — v1
/// scope). A partial failure mid-batch still adds everything that succeeded; the sheet
/// surfaces one alert and stays up rather than losing track of which items landed.
struct ImageCapturePickerSheet: View {
    /// Returns false when a given item's bytes didn't take (`ImageStoreError
    /// .invalidImage`, or the write failed) — every other item in a multi-select batch
    /// is still attempted.
    let onPick: (Data, UTType) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var pickError = false
    #if os(iOS)
    @State private var showingCamera = false
    /// Set by the camera's completion closure, applied once `fullScreenCover` has
    /// actually dismissed — see `JournalCoverPickerSheet`'s identical field for why
    /// (setting `pickError` in the same turn as `showingCamera = false` can race the
    /// cover's own dismissal and drop the alert).
    @State private var pendingCameraError = false
    #else
    @State private var showingFileImporter = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                #if os(iOS)
                // Guarded: `.camera` on a device without one (any simulator) is an
                // exception at presentation time, not a graceful empty picker.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo…") { showingCamera = true }
                        .accessibilityIdentifier("imageCapture.takePhoto")
                }
                PhotosPicker("Choose from Library…", selection: $photosPickerItems, matching: .images)
                    .accessibilityIdentifier("imageCapture.choosePhoto")
                #else
                Button("Choose from Files…") { showingFileImporter = true }
                    .accessibilityIdentifier("imageCapture.chooseFile")
                #endif
            }
            .navigationTitle("Capture Image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn’t Use That Photo", isPresented: $pickError) {
                Button("OK", role: .cancel) {}
            }
        }
        #if os(iOS)
        .onChange(of: photosPickerItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            let items = newValue
            // Reset immediately, not after the batch finishes: a re-presented picker
            // (a later pick after this one already started) must not inherit a stale
            // selection, same reasoning as `JournalCoverPickerSheet.photosPickerItem`.
            photosPickerItems = []
            Task { await addPhotosPickerItems(items) }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { data in
                showingCamera = false
                if let data {
                    Task {
                        if await onPick(data, .jpeg) { dismiss() } else { pendingCameraError = true }
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
        #else
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image],
                     allowsMultipleSelection: true) { result in
            switch result {
            case .failure:
                pickError = true
            case .success(let urls):
                Task { await addFileImporterURLs(urls) }
            }
        }
        #endif
    }

    #if os(iOS)
    private func addPhotosPickerItems(_ items: [PhotosPickerItem]) async {
        var anyFailed = false
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                anyFailed = true
                continue
            }
            let type = item.supportedContentTypes.first ?? .image
            if !(await onPick(data, type)) { anyFailed = true }
        }
        if anyFailed { pickError = true } else { dismiss() }
    }
    #else
    private func addFileImporterURLs(_ urls: [URL]) async {
        var anyFailed = false
        for url in urls {
            // `fileImporter` results are security-scoped in a sandboxed app — access
            // must be bracketed around the read, same as any other out-of-container URL.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                anyFailed = true
                continue
            }
            let type = Self.contentType(of: url)
            if !(await onPick(data, type)) { anyFailed = true }
        }
        if anyFailed { pickError = true } else { dismiss() }
    }

    private static func contentType(of url: URL) -> UTType {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]), let type = values.contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension) ?? .image
    }
    #endif
}
