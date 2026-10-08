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
///
/// A camera shot that lands does NOT dismiss (#134): the sheet comes back with a tally
/// ("2 photos added"), the camera row re-titled "Take Another…" and the toolbar button
/// turned into "Done", so a run of page photos is one trip. `ImageCaptureBatch` holds the
/// rules; `ImageCaptureBatchTests` pins them, since the simulator has no camera.
///
/// #121: every landed shot or picked item runs through `ImageFramingView` first
/// (`framingQueue`, head-first); Use hands the framed JPEG to `onPick`, Cancel hands the
/// original. A library batch dismisses when its LAST item resolves, as before; a camera shot
/// still feeds the #134 tally.
struct ImageCapturePickerSheet: View {
    /// Returns false when a given item's bytes didn't take (`ImageStoreError
    /// .invalidImage`, or the write failed) — every other item in a multi-select batch
    /// is still attempted.
    let onPick: (Data, UTType) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var pickError = false
    /// #134: how many camera shots have landed this presentation. The library picker and
    /// the file importer add whole batches in one trip and dismiss afterwards as before;
    /// only the camera loops through here.
    @State private var batch = ImageCaptureBatch()
    /// #121: items waiting for the framing step. The head is what `ImageFramingView` shows;
    /// Use/Cancel pops it, resolves it through `onPick`, and the next head (if any) presents.
    @State private var framingQueue = PendingFramingQueue()
    /// Set when any library item of the current batch failed, so the sheet alerts once when
    /// the LAST library item resolves instead of dismissing.
    @State private var libraryBatchFailed = false
    #if os(iOS)
    @State private var showingCamera = false
    /// Raises `pickError` for a failed shot once the cover is down, whichever of the
    /// two arrives first (#182) — same field, same reason as `JournalCoverPickerSheet`.
    @State private var cameraError = CameraErrorRelay()
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
                    Button(batch.cameraButtonTitle) { showingCamera = true }
                        .accessibilityIdentifier("imageCapture.takePhoto")
                }
                if batch.hasLanded {
                    Text(batch.summary)
                        .font(TypeRole.footnote.font)
                        .foregroundStyle(InkTone.inkSecondary.color)
                        .accessibilityIdentifier("imageCapture.summary")
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
                    Button(batch.dismissButtonTitle) { dismiss() }
                        .accessibilityIdentifier("imageCapture.dismiss")
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
        #if os(iOS)
        .onChange(of: photosPickerItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            let items = newValue
            // Reset immediately, not after the batch finishes: a re-presented picker
            // (a later pick after this one already started) must not inherit a stale
            // selection, same reasoning as `JournalCoverPickerSheet.photosPickerItem`.
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
        .onChange(of: showingCamera) { _, isShowing in
            if isShowing {
                cameraError.cameraPresented()
            } else if cameraError.coverDismissed() {
                pickError = true
            }
        }
        #else
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image],
                     allowsMultipleSelection: true) { result in
            switch result {
            case .failure:
                pickError = true
            case .success(let urls):
                Task { await enqueueFileImporterURLs(urls) }
            }
        }
        #endif
    }

    /// Pops `item`, hands it to `onPick` under `framing`, then does the bookkeeping its origin
    /// needs. Camera: landed stays up for the next shot (#134); failed alerts once the cover
    /// is down, the tally untouched. Library: the last item of a batch dismisses on an
    /// all-clear or alerts once.
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
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                anyFailed = true
                continue
            }
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
            // `fileImporter` results are security-scoped in a sandboxed app — access
            // must be bracketed around the read, same as any other out-of-container URL.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                anyFailed = true
                continue
            }
            loaded.append(PendingFramingItem(id: UUID(), data: data, type: Self.contentType(of: url), origin: .library))
        }
        if anyFailed { libraryBatchFailed = true }
        if loaded.isEmpty { if anyFailed { pickError = true; libraryBatchFailed = false }; return }
        framingQueue.enqueue(contentsOf: loaded)
    }

    private static func contentType(of url: URL) -> UTType {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]), let type = values.contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension) ?? .image
    }
    #endif
}
