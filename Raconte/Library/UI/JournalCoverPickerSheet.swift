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
/// instead of the legacy `PHPhotoLibrary` API. A library pick is enqueued for framing only
/// once the picker reports dismissed (`loadedPick`, flushed from `showingPhotosPicker` going
/// false), same reason as the camera shot: a cover requested mid-dismissal can drop (#182).
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
    /// Raises `pickError` for a failed verdict once the FRAMING cover is down (#182) — every
    /// failure, shot or pick, now surfaces after it.
    @State private var framingError = CameraErrorRelay()
    @State private var showingPhotosPicker = false
    /// A loaded pick held until the picker is down; see `flushLoadedPick`.
    @State private var loadedPick: PendingFramingItem?
    #if os(iOS)
    @State private var showingCamera = false
    /// #121: a landed shot waits here until the camera cover is fully down, then joins the
    /// framing queue from `onDismiss` — never two covers in one transaction.
    @State private var pendingShot: Data?
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
                Button("Choose from Library…") { showingPhotosPicker = true }
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
        } onDismiss: {
            // An A->B item swap may fire onDismiss on iOS; only the final dismissal counts.
            guard framingQueue.head == nil else { return }
            if framingError.coverDismissed() { pickError = true }
        }
        .onChange(of: framingQueue.head?.id) { old, new in
            if old == nil, new != nil { framingError.cameraPresented() }
        }
        .photosPicker(isPresented: $showingPhotosPicker, selection: $photosPickerItem, matching: .images)
        .onChange(of: showingPhotosPicker) { _, shown in
            if !shown { flushLoadedPick() }
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
                loadedPick = PendingFramingItem(id: UUID(), data: data,
                                                type: newValue.supportedContentTypes.first ?? .image,
                                                origin: .library)
                flushLoadedPick()
            }
        }
        #if os(iOS)
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
        #endif
    }

    /// Whichever of "picker down" and "load finished" comes last enqueues the pick.
    private func flushLoadedPick() {
        guard !showingPhotosPicker, let item = loadedPick else { return }
        loadedPick = nil
        framingQueue.enqueue(item)
    }

    private func resolveHead(_ item: PendingFramingItem, framing: ImageFraming) async {
        // A second tap on the same cover must not resolve (and pop) twice.
        guard framingQueue.head?.id == item.id, let item = framingQueue.beginResolving() else { return }
        let (data, _) = await Task.detached { PendingFramingQueue.resolve(item, framing: framing) }.value
        let landed = await onPick(data)
        framingQueue.finishResolving(item, landed: landed)
        if landed {
            dismiss()
        } else if framingError.addFailed() {
            pickError = true
        }
    }
}
