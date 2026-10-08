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
/// Multi-select (`PhotosPicker`, macOS multi-file `fileImporter`) makes one `onPick` call per
/// item (each is framed in turn, so adds may overlap), with no batch-progress UI (design doc, decision — v1
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
/// still feeds the #134 tally. Library and file picks, like the camera shot, are enqueued only
/// once their picker reports dismissed (`loadedPicks`, flushed from `showingPhotosPicker` /
/// `showingFileImporter` going false): a framing cover requested while the picker is still
/// animating out can be dropped (#182), stranding the head with no cover up.
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
    /// Raises `pickError` for a failed verdict once the FRAMING cover is down (#182): every
    /// failure now surfaces after a framing cover, and an alert set while it dismisses drops.
    @State private var framingError = CameraErrorRelay()
    /// Loaded library/file picks held until the picker is down; see `flushLoadedPicks`.
    @State private var loadedPicks: [PendingFramingItem] = []
    #if os(iOS)
    @State private var showingPhotosPicker = false
    @State private var showingCamera = false
    /// #121: a landed shot waits here until the camera cover is fully down, then joins the
    /// framing queue from `onDismiss` — never two covers in one transaction.
    @State private var pendingShot: Data?
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
                Button("Choose from Library…") { showingPhotosPicker = true }
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
        } onDismiss: {
            // An A->B item swap may fire onDismiss on iOS; only the final dismissal counts.
            guard framingQueue.head == nil else { return }
            if framingError.coverDismissed() { pickError = true }
        }
        .onChange(of: framingQueue.head?.id) { old, new in
            if old == nil, new != nil { framingError.cameraPresented() }
        }
        .onChange(of: pickerIsShowing) { _, shown in
            if !shown { flushLoadedPicks() }
        }
        #if os(iOS)
        .photosPicker(isPresented: $showingPhotosPicker, selection: $photosPickerItems, matching: .images)
        .onChange(of: photosPickerItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            let items = newValue
            // Reset immediately, not after the batch finishes: a re-presented picker
            // (a later pick after this one already started) must not inherit a stale
            // selection, same reasoning as `JournalCoverPickerSheet.photosPickerItem`.
            photosPickerItems = []
            Task { await enqueuePhotosPickerItems(items) }
        }
        .fullScreenCover(isPresented: $showingCamera, onDismiss: {
            if let shot = pendingShot {
                pendingShot = nil
                framingQueue.enqueue(PendingFramingItem(id: UUID(), data: shot, type: .jpeg, origin: .camera))
            }
        }) {
            CameraCapture { data in
                pendingShot = data
                showingCamera = false
            }
            .ignoresSafeArea()
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

    private var pickerIsShowing: Bool {
        #if os(iOS)
        showingPhotosPicker
        #else
        showingFileImporter
        #endif
    }

    /// Moves loaded picks into the framing queue. Whichever of "picker down" and "loads
    /// finished" comes last calls this; it is a no-op while the picker is still up.
    private func flushLoadedPicks() {
        guard !pickerIsShowing, !loadedPicks.isEmpty else { return }
        let items = loadedPicks
        loadedPicks = []
        framingQueue.enqueue(contentsOf: items)
    }

    /// Takes `item` off the queue, hands it to `onPick` under `framing`, then does the
    /// bookkeeping. Camera: landed stays up for the next shot (#134); failed alerts once the
    /// framing cover is down. Library: the batch dismisses on an all-clear or alerts once,
    /// but only when nothing is queued or in flight (`libraryBatchIsOver`).
    private func resolveHead(_ item: PendingFramingItem, framing: ImageFraming) async {
        // A second tap on the same cover must not resolve (and pop) twice.
        guard framingQueue.head?.id == item.id, let item = framingQueue.beginResolving() else { return }
        let (data, type) = await Task.detached { PendingFramingQueue.resolve(item, framing: framing) }.value
        let landed = await onPick(data, type)
        framingQueue.finishResolving(item, landed: landed)
        if item.origin == .camera {
            if landed {
                batch.recordLanded()
            } else if framingError.addFailed() {
                pickError = true
            }
        }
        if framingQueue.libraryBatchIsOver {
            if framingQueue.closeLibraryBatch() {
                if framingError.addFailed() { pickError = true }
            } else {
                dismiss()
            }
        }
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
        if loaded.isEmpty {
            if anyFailed, framingError.addFailed() { pickError = true }
            return
        }
        if anyFailed { framingQueue.recordLibraryLoadFailure() }
        loadedPicks.append(contentsOf: loaded)
        flushLoadedPicks()
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
        if loaded.isEmpty {
            if anyFailed, framingError.addFailed() { pickError = true }
            return
        }
        if anyFailed { framingQueue.recordLibraryLoadFailure() }
        loadedPicks.append(contentsOf: loaded)
        flushLoadedPicks()
    }

    private static func contentType(of url: URL) -> UTType {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]), let type = values.contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension) ?? .image
    }
    #endif
}
