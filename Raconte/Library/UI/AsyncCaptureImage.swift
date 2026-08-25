import SwiftUI

/// Shared async-image-load plumbing for `EntryDetailView`'s `ImageThumbnailView` and
/// `ImageFullScreenViewer`'s `ImageFullResolutionView` (Task 6 fix round 1). Both need
/// exactly the same shape — decode `Data` from a model-mediated async read, once per
/// identity change, with a placeholder while loading or on failure — and differ only in
/// which model accessor they call (`thumbnailData` vs `originalData`) and how the
/// decoded image is laid out; this factors out everything but that difference so
/// neither view duplicates the `@State`/`.task(id:)`/decode boilerplate.
///
/// **Never reads a file directly** — `load` is handed in by the caller and is always a
/// `LibraryScreenModel` pass-through (`thumbnailData(captureID:imageID:)`/
/// `originalData(captureID:imageID:)`), never a `SegmentLayout` URL built and read here.
/// That's the whole point: no view in this file touches `FileManager`, matching
/// `JournalCoverThumbnail`'s existing convention of only ever rendering `Data` it was
/// handed, never bytes it fetched itself.
struct AsyncCaptureImage<Loaded: View, Placeholder: View>: View {
    /// Re-triggers `load` when it changes (`.task(id:)`) — an image's own id, since
    /// that's what both call sites vary on.
    let id: String
    let load: () async -> Data?
    @ViewBuilder let loaded: (Image) -> Loaded
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let image = JournalCoverThumbnail.decode(data) {
                loaded(image)
            } else {
                placeholder()
            }
        }
        .task(id: id) { data = await load() }
    }
}
