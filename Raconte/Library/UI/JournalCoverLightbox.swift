import SwiftUI

/// #106: a journal's cover at the largest size we have. Covers are stored once, downscaled to
/// 1024 px on the long side (`JournalCoverStore`), so this is that JPEG scaled to fit — there
/// is no larger original, unlike entry images. Presented full-screen on iOS and as a large
/// sheet on macOS (`fullScreenCover` does not exist there), always from the editor `Form`'s
/// own modifier chain. Dismiss: Done, Esc (macOS, via the cancel keyboard shortcut), or a
/// tap anywhere on the image's ground.
///
/// `data` is optional: if the cover is removed (a sync landing, a rescan) while the lightbox
/// is up, `nil` renders a small "no longer available" fallback with its own Done button
/// instead of an empty, un-dismissable screen — same container identifier, same toolbar.
struct JournalCoverLightbox: View {
    let data: Data?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let data, let image = JournalCoverThumbnail.decode(data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else if data != nil {
                    Text("This cover could not be decoded.")
                        .foregroundStyle(.white)
                } else {
                    Text("This cover is no longer available.")
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .accessibilityIdentifier("journalCover.lightbox")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("journalCover.lightbox.done")
                }
            }
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 420)
            .frame(idealWidth: 900, idealHeight: 700)
            #endif
        }
    }
}
